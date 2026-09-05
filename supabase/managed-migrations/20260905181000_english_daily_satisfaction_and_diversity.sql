-- Daily is a fixed planned workload, not an endlessly refilling bucket.
-- Practising the same concept in another English route after it was scheduled
-- satisfies that Daily slot for the current batch. Keep the raw row/history,
-- remove it from actionable Daily, and do not top the slot back up.
--
-- Also keep the general Daily mix from being dominated by Phrasal Verb content.
-- Phrasal remains eligible for Weak/Due/etc. reasons, but at target 120 the
-- preferred hard ceiling is 15 unless non-phrasal supply is genuinely scarce.

create or replace function english.daily_satisfied_elsewhere(
  p_user_id uuid,
  p_question_id text,
  p_batch_date date
)
returns boolean
language sql
stable
security definer
set search_path to 'pg_catalog','english','auth'
as $function$
with target as (
  select coalesce(m.concept_id,q.question_id) concept_key
  from english.questions q
  left join english.question_concept_mappings m on m.question_id=q.question_id
  where q.question_id=p_question_id
)
select coalesce(exists(
  select 1
  from target t
  join english.attempts a on a.user_id=p_user_id
  left join english.question_concept_mappings am on am.question_id=a.question_id
  where lower(coalesce(a.module,''))<>'daily'
    and (a.attempted_at at time zone 'Asia/Kolkata')::date>=p_batch_date
    and (a.attempted_at at time zone 'Asia/Kolkata')::date<=((now() at time zone 'Asia/Kolkata')::date)
    and coalesce(am.concept_id,a.question_id)=t.concept_key
),false);
$function$;

revoke execute on function english.daily_satisfied_elsewhere(uuid,text,date) from public,anon;
grant execute on function english.daily_satisfied_elsewhere(uuid,text,date) to authenticated,service_role;

create or replace function english.daily_effective_counts(
  p_user_id uuid,
  p_batch_date date,
  p_target integer default 120
)
returns table(total integer,completed integer,satisfied_elsewhere integer,remaining integer,raw_planned integer)
language sql
stable
security definer
set search_path to 'pg_catalog','english','auth'
as $function$
with base as (
  select d.question_id,d.sequence,d.status,
         lower(coalesce(d.status,''))='completed' is_completed,
         english.daily_reason(p_user_id,d.question_id,d.quiz_date) reason_now,
         case when lower(coalesce(d.status,''))='completed' then false
              else english.daily_satisfied_elsewhere(p_user_id,d.question_id,d.quiz_date) end satisfied
  from english.daily_current d
  where d.user_id=p_user_id and d.quiz_date=p_batch_date
), planned as (
  select b.*,
         row_number() over(order by case when b.is_completed then 0 else 1 end,b.sequence,b.question_id) slot_rank
  from base b
  where b.is_completed or b.reason_now<>'' or b.satisfied
), effective as (
  select * from planned where slot_rank<=greatest(1,least(120,coalesce(p_target,120)))
)
select
  count(*)::int,
  count(*) filter(where is_completed)::int,
  count(*) filter(where not is_completed and satisfied)::int,
  count(*) filter(where not is_completed and not satisfied and reason_now<>'')::int,
  (select count(*)::int from planned)
from effective;
$function$;

revoke execute on function english.daily_effective_counts(uuid,date,integer) from public,anon;
grant execute on function english.daily_effective_counts(uuid,date,integer) to authenticated,service_role;

create or replace function english.daily_phrasal_cap(p_target integer default 120)
returns integer
language sql
immutable
set search_path to 'pg_catalog','english'
as $function$
select greatest(1,least(15,ceil(greatest(1,least(120,coalesce(p_target,120)))*0.125)::int));
$function$;

create or replace function english.current_daily_items(p_user_id uuid)
returns table(
  sequence integer,priority integer,reason text,quiz_date date,status text,
  question_id text,topic text,word text,question text,option_a text,option_b text,option_c text,option_d text,
  correct_key text,explanation text,subtopic text,question_type text,source_file text,source_page text,
  concept_id text,difficulty text,tip text,usage_note text,example_sentence text,memory_aid text,related_words text,
  source_url text,starred boolean,difficult boolean
)
language sql
stable
security definer
set search_path to 'pg_catalog','english','auth'
as $function$
with base as (
  select d.sequence,d.priority,d.reason,d.quiz_date,d.status,
         q.question_id,q.topic,q.word,q.question,q.option_a,q.option_b,q.option_c,q.option_d,upper(q.correct) correct_key,
         q.explanation,q.subtopic,q.question_type,q.source_file,q.source_page,q.concept_id,q.difficulty,
         q.tip,q.usage_note,q.example_sentence,q.memory_aid,q.related_words,q.source_url,
         coalesce(s.last_marked,false) starred,coalesce(ds.difficult,false) difficult,
         lower(coalesce(d.status,''))='completed' is_completed,
         english.daily_reason(p_user_id,q.question_id,d.quiz_date) reason_now,
         case when lower(coalesce(d.status,''))='completed' then false
              else english.daily_satisfied_elsewhere(p_user_id,q.question_id,d.quiz_date) end satisfied
  from english.daily_current d
  join english.questions q on q.question_id=d.question_id
  left join english.question_state s on s.user_id=p_user_id and s.question_id=q.question_id
  left join english.difficult_state ds on ds.user_id=p_user_id and ds.question_id=q.question_id
  where d.user_id=p_user_id
    and q.active
    and not coalesce(s.mastered,false)
), planned as (
  select b.*,
         row_number() over(order by case when b.is_completed then 0 else 1 end,b.sequence,b.question_id) slot_rank
  from base b
  where b.is_completed or b.reason_now<>'' or b.satisfied
)
select sequence,priority,reason,quiz_date,status,
       question_id,topic,word,question,option_a,option_b,option_c,option_d,correct_key,
       explanation,subtopic,question_type,source_file,source_page,concept_id,difficulty,
       tip,usage_note,example_sentence,memory_aid,related_words,source_url,starred,difficult
from planned
where slot_rank<=120
  and (is_completed or (reason_now<>'' and not satisfied))
order by sequence;
$function$;

create or replace function english.rebalance_daily_category_diversity(
  p_user_id uuid,
  p_batch_date date,
  p_target integer default 120
)
returns integer
language plpgsql
security definer
set search_path to 'pg_catalog','english','auth'
as $function$
declare
  v_target integer:=greatest(1,least(120,coalesce(p_target,120)));
  v_cap integer:=english.daily_phrasal_cap(p_target);
  v_phrasal integer:=0;
  v_excess integer:=0;
  v_replaced integer:=0;
begin
  -- Count Phrasal slots only inside the effective planned workload. Completed and
  -- externally-satisfied slots remain immutable history and consume the ceiling.
  with base as (
    select d.question_id,d.sequence,d.status,q.topic,
           lower(coalesce(d.status,''))='completed' is_completed,
           english.daily_reason(p_user_id,d.question_id,d.quiz_date) reason_now,
           case when lower(coalesce(d.status,''))='completed' then false
                else english.daily_satisfied_elsewhere(p_user_id,d.question_id,d.quiz_date) end satisfied
    from english.daily_current d
    join english.questions q on q.question_id=d.question_id
    where d.user_id=p_user_id and d.quiz_date=p_batch_date
  ), planned as (
    select b.*,row_number() over(order by case when b.is_completed then 0 else 1 end,b.sequence,b.question_id) slot_rank
    from base b where b.is_completed or b.reason_now<>'' or b.satisfied
  )
  select count(*)::int into v_phrasal
  from planned
  where slot_rank<=v_target and english.learning_category(topic)='PHRASAL';

  v_excess:=greatest(0,v_phrasal-v_cap);
  if v_excess=0 then return 0; end if;

  with effective as (
    select d.question_id,d.sequence,d.priority,d.reason,d.status,q.topic,
           english.daily_reason(p_user_id,d.question_id,d.quiz_date) reason_now,
           english.daily_satisfied_elsewhere(p_user_id,d.question_id,d.quiz_date) satisfied,
           row_number() over(order by
             case when lower(coalesce(d.status,''))='completed' then 0 else 1 end,
             d.sequence,d.question_id) slot_rank
    from english.daily_current d
    join english.questions q on q.question_id=d.question_id
    where d.user_id=p_user_id and d.quiz_date=p_batch_date
      and (lower(coalesce(d.status,''))='completed'
           or english.daily_reason(p_user_id,d.question_id,d.quiz_date)<>''
           or english.daily_satisfied_elsewhere(p_user_id,d.question_id,d.quiz_date))
  ), removable as (
    select e.question_id,e.sequence,
           row_number() over(order by english.daily_reason_base_score(e.reason_now) asc,e.priority asc,e.sequence desc,e.question_id) rn
    from effective e
    left join english.question_concept_mappings em on em.question_id=e.question_id
    where e.slot_rank<=v_target
      and english.learning_category(e.topic)='PHRASAL'
      and lower(coalesce(e.status,''))<>'completed'
      and e.reason_now<>''
      and not e.satisfied
      and not exists(
        select 1
        from english.attempts a
        left join english.question_concept_mappings am on am.question_id=a.question_id
        where a.user_id=p_user_id
          and (a.attempted_at at time zone 'Asia/Kolkata')::date>=p_batch_date
          and coalesce(am.concept_id,a.question_id)=coalesce(em.concept_id,e.question_id)
      )
    order by english.daily_reason_base_score(e.reason_now) asc,e.priority asc,e.sequence desc,e.question_id
    limit v_excess
  ), candidate_base as (
    select q.question_id,q.topic,coalesce(m.concept_id,q.question_id) concept_key,m.concept_id,
           r.reason,
           english.daily_reason_base_score(r.reason)
             + case coalesce(ce.coverage_state,'unseen')
                 when 'weak' then 220 when 'retention_risk' then 180 when 'seen' then 35
                 when 'unseen' then 25 when 'secure' then -25 when 'exam_ready' then -110 else 0 end
             + case when ce.next_review is not null and ce.next_review<=now() then 80 else 0 end score,
           english.daily_signal_codes(
             r.reason,coalesce(s.status,'New'),
             s.next_review is not null and s.next_review<=((p_batch_date::timestamp+interval '1 day - 1 millisecond') at time zone 'Asia/Kolkata'),
             coalesce(s.last_marked,false),coalesce(ds.difficult,false),
             coalesce(s.attempts,0)=0 and english.is_genuine_bank_question(q)
           ) || case when lr.route='targeted' then array['TARGET']::text[] else '{}'::text[] end signals,
           coalesce(ce.coverage_state,'unseen') concept_state,
           coalesce(ce.confidence_score,0) concept_confidence,
           lr.route,
           row_number() over(partition by coalesce(m.concept_id,q.question_id)
                             order by english.daily_reason_base_score(r.reason) desc,q.question_id) concept_pick
    from english.questions q
    left join english.question_state s on s.user_id=p_user_id and s.question_id=q.question_id
    left join english.difficult_state ds on ds.user_id=p_user_id and ds.question_id=q.question_id
    left join english.question_concept_mappings m on m.question_id=q.question_id
    left join english.concept_evidence ce on ce.user_id=p_user_id and ce.concept_id=m.concept_id
    left join english.learning_route_state lr on lr.user_id=p_user_id and lr.question_id=q.question_id
    cross join lateral (select english.daily_reason(p_user_id,q.question_id,p_batch_date) reason) r
    where q.active
      and english.question_visible_to_user(p_user_id,q.question_id)
      and not coalesce(s.mastered,false)
      and r.reason<>''
      and english.learning_category(q.topic)<>'PHRASAL'
      and english.hindu_daily_eligible(p_user_id,q.question_id)
      and not exists(
        select 1 from english.daily_current d
        left join english.question_concept_mappings dm on dm.question_id=d.question_id
        where d.user_id=p_user_id and d.quiz_date=p_batch_date
          and coalesce(dm.concept_id,d.question_id)=coalesce(m.concept_id,q.question_id)
      )
      and not exists(
        select 1 from english.attempts a
        left join english.question_concept_mappings am on am.question_id=a.question_id
        where a.user_id=p_user_id
          and (a.attempted_at at time zone 'Asia/Kolkata')::date>=p_batch_date
          and coalesce(am.concept_id,a.question_id)=coalesce(m.concept_id,q.question_id)
      )
  ), candidates as (
    select c.*,row_number() over(order by c.score desc,c.question_id) rn
    from candidate_base c
    where c.concept_pick=1
    order by c.score desc,c.question_id
    limit v_excess
  ), pairs as (
    select r.question_id old_id,r.sequence,c.*
    from removable r join candidates c using(rn)
  )
  update english.daily_current d
  set question_id=p.question_id,
      priority=round(p.score)::int,
      reason=p.reason,
      status='New',
      topic=p.topic,
      concept_id=p.concept_id,
      selection_signals=p.signals,
      selection_snapshot=jsonb_build_object(
        'selectedAt',now(),'batchDate',p_batch_date,'reason',p.reason,
        'category',english.learning_category(p.topic),
        'categoryDiversityReplacement',true,
        'replacedQuestionId',p.old_id,
        'conceptId',p.concept_id,
        'conceptCoverage',p.concept_state,
        'conceptConfidence',p.concept_confidence,
        'targeted',(p.route='targeted')
      )
  from pairs p
  where d.user_id=p_user_id and d.sequence=p.sequence and d.question_id=p.old_id;

  get diagnostics v_replaced=row_count;
  return v_replaced;
end;
$function$;

revoke execute on function english.rebalance_daily_category_diversity(uuid,date,integer) from public,anon,authenticated;
grant execute on function english.rebalance_daily_category_diversity(uuid,date,integer) to service_role;

-- Keep the existing selector/scoring model. The only lifecycle change here is that
-- externally-satisfied slots count toward the fixed planned workload, so a repair
-- cannot keep adding replacement questions after work was completed elsewhere.
create or replace function english.create_daily_core_20260905(p_user_id uuid,p_batch_date date,p_target integer)
returns integer
language plpgsql
security definer
set search_path to 'pg_catalog','english','auth'
as $function$
declare
  v_target integer:=greatest(1,least(120,coalesce(p_target,120)));
  v_reason text;
  v_take integer;
  v_inserted integer;
  v_count integer:=0;
  v_sequence_base integer:=0;
begin
  select c.total,coalesce(max(d.sequence),0)
  into v_count,v_sequence_base
  from english.daily_effective_counts(p_user_id,p_batch_date,v_target) c
  left join english.daily_current d on d.user_id=p_user_id and d.quiz_date=p_batch_date
  group by c.total;

  v_count:=coalesce(v_count,0);
  v_sequence_base:=coalesce(v_sequence_base,0);
  if v_count>=v_target then return v_count; end if;

  create temporary table if not exists pg_temp.ep_daily_candidates(
    question_id text primary key,concept_key text,concept_id text,concept_state text,
    concept_confidence numeric,concept_next_review timestamptz,reason text,score numeric,
    priority integer,signals text[],snapshot jsonb
  ) on commit drop;
  truncate pg_temp.ep_daily_candidates;

  insert into pg_temp.ep_daily_candidates(
    question_id,concept_key,concept_id,concept_state,concept_confidence,concept_next_review,
    reason,score,priority,signals,snapshot
  )
  select q.question_id,coalesce(cm.concept_id,q.question_id),cm.concept_id,
    coalesce(ce.coverage_state,'unseen'),coalesce(ce.confidence_score,0),ce.next_review,r.reason,
    english.daily_reason_base_score(r.reason)
    +coalesce(cp.penalty,0)*70
    +least(120,greatest(0,coalesce(floor(extract(epoch from (((p_batch_date::timestamp+interval '1 day - 1 millisecond') at time zone 'Asia/Kolkata')-s.next_review))/86400),0)))*12
    +case when coalesce(s.last_marked,false) then 12 else 0 end
    +case when coalesce(ds.difficult,false) then 10 else 0 end
    +case coalesce(ce.coverage_state,'unseen') when 'weak' then 220 when 'retention_risk' then 180 when 'seen' then 35 when 'unseen' then 25 when 'secure' then -25 when 'exam_ready' then -110 else 0 end
    +case when ce.next_review is not null and ce.next_review<=now() then 80 else 0 end
    +case coalesce(c.exam_relevance,'medium') when 'high' then 20 when 'low' then -15 else 0 end
    +random()*20,
    english.daily_reason_base_score(r.reason),
    english.daily_signal_codes(r.reason,coalesce(s.status,'New'),s.next_review is not null and s.next_review<=((p_batch_date::timestamp+interval '1 day - 1 millisecond') at time zone 'Asia/Kolkata'),coalesce(s.last_marked,false),coalesce(ds.difficult,false),coalesce(s.attempts,0)=0 and english.is_genuine_bank_question(q)),
    jsonb_build_object('selectedAt',now(),'batchDate',p_batch_date,'state',coalesce(s.status,'New'),'attempts',coalesce(s.attempts,0),'correct',coalesce(s.correct,0),'wrong',coalesce(s.wrong,0),'accuracy',coalesce(s.accuracy,0),'nextReview',s.next_review,'starred',coalesce(s.last_marked,false),'difficult',coalesce(ds.difficult,false),'category',english.learning_category(q.topic),'categoryPenalty',coalesce(cp.penalty,0),'conceptId',cm.concept_id,'conceptCoverage',coalesce(ce.coverage_state,'unseen'),'conceptConfidence',coalesce(ce.confidence_score,0),'conceptNextReview',ce.next_review,'daysOverdue',greatest(0,coalesce(floor(extract(epoch from (((p_batch_date::timestamp+interval '1 day - 1 millisecond') at time zone 'Asia/Kolkata')-s.next_review))/86400),0)))
  from english.questions q
  left join english.question_state s on s.user_id=p_user_id and s.question_id=q.question_id
  left join english.difficult_state ds on ds.user_id=p_user_id and ds.question_id=q.question_id
  left join english.question_concept_mappings cm on cm.question_id=q.question_id
  left join english.concepts c on c.concept_id=cm.concept_id
  left join english.concept_evidence ce on ce.user_id=p_user_id and ce.concept_id=cm.concept_id
  left join english.daily_category_penalties(p_user_id) cp on cp.category=english.learning_category(q.topic)
  cross join lateral (select english.daily_reason(p_user_id,q.question_id,p_batch_date) reason) r
  where q.active
    and english.question_visible_to_user(p_user_id,q.question_id)
    and not coalesce(s.mastered,false)
    and r.reason<>''
    and english.hindu_daily_eligible(p_user_id,q.question_id)
    and not exists(
      select 1 from english.daily_current d
      left join english.question_concept_mappings dm on dm.question_id=d.question_id
      where d.user_id=p_user_id and d.quiz_date=p_batch_date
        and coalesce(dm.concept_id,d.question_id)=coalesce(cm.concept_id,q.question_id)
    )
    and not exists(
      select 1 from english.attempts a
      left join english.question_concept_mappings am on am.question_id=a.question_id
      where a.user_id=p_user_id
        and (a.attempted_at at time zone 'Asia/Kolkata')::date>=p_batch_date
        and coalesce(am.concept_id,a.question_id)=coalesce(cm.concept_id,q.question_id)
    );

  foreach v_reason in array array['Controlled New','Persistent Weak','Weak','Fragile','Due Spaced Revision','Learning','Marked Review','Difficult Review','Mixed Revision'] loop
    exit when v_count>=v_target;
    v_take:=least(english.daily_quota(v_reason,v_target),v_target-v_count);
    with base as (
      select c.*,row_number() over(partition by c.concept_key order by c.score desc,c.question_id) concept_pick
      from pg_temp.ep_daily_candidates c
      where c.reason=v_reason
        and not exists(
          select 1 from english.daily_current d
          left join english.question_concept_mappings dm on dm.question_id=d.question_id
          where d.user_id=p_user_id and d.quiz_date=p_batch_date
            and coalesce(dm.concept_id,d.question_id)=c.concept_key
        )
    ), pick as (
      select * from base where concept_pick=1 order by score desc limit v_take
    )
    insert into english.daily_current(user_id,question_id,sequence,priority,reason,quiz_date,status,topic,concept_id,selection_signals,selection_snapshot)
    select p_user_id,p.question_id,v_sequence_base+row_number() over(order by p.score desc)::int,round(p.score)::int,p.reason,p_batch_date,'New',q.topic,coalesce(p.concept_id,q.concept_id),p.signals,p.snapshot
    from pick p join english.questions q on q.question_id=p.question_id order by p.score desc;
    get diagnostics v_inserted=row_count;
    v_count:=v_count+v_inserted;
    v_sequence_base:=v_sequence_base+v_inserted;
  end loop;

  if v_count<v_target then
    with existing as (
      select reason,count(*) n from english.daily_current where user_id=p_user_id and quiz_date=p_batch_date group by reason
    ), ranked as (
      select c.*,row_number() over(partition by c.reason order by c.score desc) reason_rn,row_number() over(partition by c.concept_key order by c.score desc,c.question_id) concept_rn
      from pg_temp.ep_daily_candidates c
      where not exists(
        select 1 from english.daily_current d
        left join english.question_concept_mappings dm on dm.question_id=d.question_id
        where d.user_id=p_user_id and d.quiz_date=p_batch_date and coalesce(dm.concept_id,d.question_id)=c.concept_key
      )
    ), eligible as (
      select r.* from ranked r left join existing e on e.reason=r.reason
      where r.concept_rn=1 and r.reason_rn<=greatest(0,english.daily_cap(r.reason,v_target)-coalesce(e.n,0))
      order by r.score desc limit (v_target-v_count)
    )
    insert into english.daily_current(user_id,question_id,sequence,priority,reason,quiz_date,status,topic,concept_id,selection_signals,selection_snapshot)
    select p_user_id,e.question_id,v_sequence_base+row_number() over(order by e.score desc)::int,round(e.score)::int,e.reason,p_batch_date,'New',q.topic,coalesce(e.concept_id,q.concept_id),e.signals,e.snapshot
    from eligible e join english.questions q on q.question_id=e.question_id order by e.score desc;
    get diagnostics v_inserted=row_count;
    v_count:=v_count+v_inserted;
    v_sequence_base:=v_sequence_base+v_inserted;
  end if;

  -- Capacity guarantee remains intact. Category diversity is applied afterward and
  -- only swaps untouched rows, so scarcity is still the only under-target case.
  if v_count<v_target then
    with ranked as (
      select c.*,row_number() over(partition by c.concept_key order by c.score desc,c.question_id) concept_rn
      from pg_temp.ep_daily_candidates c
      where not exists(
        select 1 from english.daily_current d
        left join english.question_concept_mappings dm on dm.question_id=d.question_id
        where d.user_id=p_user_id and d.quiz_date=p_batch_date and coalesce(dm.concept_id,d.question_id)=c.concept_key
      )
    ), eligible as (
      select * from ranked where concept_rn=1 order by score desc limit (v_target-v_count)
    )
    insert into english.daily_current(user_id,question_id,sequence,priority,reason,quiz_date,status,topic,concept_id,selection_signals,selection_snapshot)
    select p_user_id,e.question_id,v_sequence_base+row_number() over(order by e.score desc)::int,round(e.score)::int,e.reason,p_batch_date,'New',q.topic,coalesce(e.concept_id,q.concept_id),e.signals,e.snapshot
    from eligible e join english.questions q on q.question_id=e.question_id order by e.score desc;
    get diagnostics v_inserted=row_count;
    v_count:=v_count+v_inserted;
  end if;
  return v_count;
end;
$function$;

create or replace function english.create_daily(p_user_id uuid,p_batch_date date,p_target integer)
returns integer
language plpgsql
security definer
set search_path to 'pg_catalog','english','auth'
as $function$
declare n integer;
begin
  n:=english.create_daily_core_20260905(p_user_id,p_batch_date,p_target);
  perform english.rebalance_daily_targeted(p_user_id,p_batch_date,p_target);
  perform english.rebalance_daily_category_diversity(p_user_id,p_batch_date,p_target);
  select total into n from english.daily_effective_counts(p_user_id,p_batch_date,p_target);
  return coalesce(n,0);
end;
$function$;

create or replace function english.repair_daily_shortfall(p_user_id uuid,p_batch_date date,p_target integer default 120)
returns integer
language plpgsql
security definer
set search_path to 'pg_catalog','english','auth'
as $function$
declare
  v_target integer:=greatest(1,least(120,coalesce(p_target,120)));
  v_before integer:=0;
  v_after integer:=0;
begin
  perform pg_advisory_xact_lock(hashtextextended('english.daily.'||p_user_id::text,0));
  select total into v_before from english.daily_effective_counts(p_user_id,p_batch_date,v_target);
  v_before:=coalesce(v_before,0);

  delete from english.daily_current d
  where d.user_id=p_user_id and d.quiz_date=p_batch_date
    and lower(coalesce(d.status,''))<>'completed'
    and english.daily_reason(p_user_id,d.question_id,p_batch_date)=''
    and not english.daily_satisfied_elsewhere(p_user_id,d.question_id,p_batch_date)
    and not exists(
      select 1 from english.attempts a
      where a.user_id=p_user_id and a.question_id=d.question_id
        and (a.attempted_at at time zone 'Asia/Kolkata')::date>=p_batch_date
    );

  perform english.create_daily_core_20260905(p_user_id,p_batch_date,v_target);
  perform english.rebalance_daily_targeted(p_user_id,p_batch_date,v_target);
  perform english.rebalance_daily_category_diversity(p_user_id,p_batch_date,v_target);

  select total into v_after from english.daily_effective_counts(p_user_id,p_batch_date,v_target);
  return greatest(0,coalesce(v_after,0)-v_before);
end;
$function$;

create or replace function english.ensure_daily(p_user_id uuid,p_target integer default 120)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','english','auth'
as $function$
declare
  v_today date:=(now() at time zone 'Asia/Kolkata')::date;
  v_batch date;
  v_pending integer:=0;
  v_created integer:=0;
  v_archived integer:=0;
  v_next date;
  c record;
begin
  select min(quiz_date) into v_batch from english.daily_current where user_id=p_user_id;
  if v_batch is null then
    v_batch:=v_today;
    v_created:=english.create_daily(p_user_id,v_batch,p_target);
  else
    select remaining into v_pending from english.daily_effective_counts(p_user_id,v_batch,p_target);
    v_pending:=coalesce(v_pending,0);
    if v_batch<v_today and v_pending=0 then
      v_archived:=english.archive_daily(p_user_id,v_batch);
      v_next:=v_batch+1;
      v_batch:=v_next;
      v_created:=english.create_daily(p_user_id,v_batch,p_target);
    elsif v_batch=v_today then
      v_created:=english.repair_daily_shortfall(p_user_id,v_batch,p_target);
    end if;
  end if;

  select * into c from english.daily_effective_counts(p_user_id,v_batch,p_target);
  return jsonb_build_object(
    'ok',true,'batch_date',v_batch,'today',v_today,'pending_previous_day',(v_batch<v_today),
    'created',v_created,'archived',v_archived,'target_is_maximum',true,'target_guaranteed_when_eligible',true,
    'total',coalesce(c.total,0),'completed',coalesce(c.completed,0),
    'satisfied_elsewhere',coalesce(c.satisfied_elsewhere,0),
    'done',coalesce(c.completed,0)+coalesce(c.satisfied_elsewhere,0),
    'remaining',coalesce(c.remaining,0),'raw_planned',coalesce(c.raw_planned,0)
  );
end;
$function$;

create or replace function public.english_resume_daily()
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','public','english','auth'
as $function$
declare uid uuid:=auth.uid(); info jsonb;
begin
  if uid is null then raise exception 'Authentication required'; end if;
  info:=english.ensure_daily(uid,120);
  return info || jsonb_build_object('items',coalesce((
    select jsonb_agg(to_jsonb(x)||jsonb_build_object(
      'selectionSignals',coalesce(d.selection_signals,'{}'::text[]),
      'selectionSnapshot',coalesce(d.selection_snapshot,'{}'::jsonb)
    ) order by x.sequence)
    from english.current_daily_items(uid) x
    join english.daily_current d on d.user_id=uid and d.question_id=x.question_id
    where lower(coalesce(x.status,''))<>'completed'
  ),'[]'::jsonb));
end;
$function$;

create or replace function public.english_get_daily_current()
returns jsonb
language plpgsql
stable
security definer
set search_path to 'pg_catalog','public','english','auth'
as $function$
declare
  uid uuid:=auth.uid();
  v_batch date;
  c record;
  v_items jsonb:='[]'::jsonb;
begin
  if uid is null then return jsonb_build_object('ok',false,'error','Authentication required'); end if;
  select min(quiz_date) into v_batch from english.daily_current where user_id=uid;
  if v_batch is null then
    return jsonb_build_object('ok',true,'batch_date',null,'today',(now() at time zone 'Asia/Kolkata')::date,
      'pending_previous_day',false,'created',0,'archived',0,'target_is_maximum',true,
      'total',0,'completed',0,'satisfied_elsewhere',0,'done',0,'remaining',0,'raw_planned',0,'items','[]'::jsonb);
  end if;

  select * into c from english.daily_effective_counts(uid,v_batch,120);
  select coalesce(jsonb_agg(to_jsonb(x)||jsonb_build_object(
      'selectionSignals',coalesce(d.selection_signals,'{}'::text[]),
      'selectionSnapshot',coalesce(d.selection_snapshot,'{}'::jsonb)
    ) order by x.sequence),'[]'::jsonb)
  into v_items
  from english.current_daily_items(uid) x
  join english.daily_current d on d.user_id=uid and d.question_id=x.question_id
  where lower(coalesce(x.status,''))<>'completed';

  return jsonb_build_object('ok',true,'batch_date',v_batch,'today',(now() at time zone 'Asia/Kolkata')::date,
    'pending_previous_day',(v_batch<(now() at time zone 'Asia/Kolkata')::date),'created',0,'archived',0,
    'target_is_maximum',true,'total',coalesce(c.total,0),'completed',coalesce(c.completed,0),
    'satisfied_elsewhere',coalesce(c.satisfied_elsewhere,0),
    'done',coalesce(c.completed,0)+coalesce(c.satisfied_elsewhere,0),
    'remaining',coalesce(c.remaining,0),'raw_planned',coalesce(c.raw_planned,0),'items',v_items);
end;
$function$;

create or replace function public.english_dashboard_summary()
returns jsonb
language plpgsql
stable
security definer
set search_path to 'pg_catalog','public','english','auth'
as $function$
declare
  uid uuid:=auth.uid();
  v_batch date;
  c record;
  v_stored integer:=0;
begin
  if uid is null then return jsonb_build_object('ok',false,'error','Authentication required'); end if;
  select min(quiz_date),count(*)::int into v_batch,v_stored from english.daily_current where user_id=uid;
  if v_batch is null then
    c.total:=0;c.completed:=0;c.satisfied_elsewhere:=0;c.remaining:=0;c.raw_planned:=0;
  else
    select * into c from english.daily_effective_counts(uid,v_batch,120);
  end if;
  return jsonb_build_object(
    'ok',true,
    'total_active',(select count(*) from english.questions q where q.active and english.question_visible_to_user(uid,q.question_id) and not exists(select 1 from english.question_state s where s.user_id=uid and s.question_id=q.question_id and s.mastered)),
    'attempted',(select count(*) from english.question_state s where s.user_id=uid and s.attempts>0),
    'mastered',(select count(*) from english.question_state s where s.user_id=uid and s.mastered),
    'starred',(select count(*) from english.question_state s where s.user_id=uid and s.last_marked),
    'difficult',(select count(*) from english.difficult_state x where x.user_id=uid and x.difficult),
    'daily_total',coalesce(c.total,0),
    'daily_stored_total',v_stored,
    'daily_completed',coalesce(c.completed,0),
    'daily_satisfied_elsewhere',coalesce(c.satisfied_elsewhere,0),
    'daily_done',coalesce(c.completed,0)+coalesce(c.satisfied_elsewhere,0),
    'daily_remaining',coalesce(c.remaining,0),
    'daily_actionable_total',coalesce(c.total,0),
    'daily_suppressed',coalesce(c.satisfied_elsewhere,0),
    'daily_raw_extra',greatest(0,v_stored-coalesce(c.total,0)),
    'daily_target_is_maximum',true
  );
end;
$function$;

-- Apply only safe same-day swaps now. Completed rows and any concept with an
-- attempt since the batch began are immutable and are never rewritten.
do $repair_today$
declare r record;
begin
  for r in
    select distinct d.user_id,d.quiz_date
    from english.daily_current d
    where d.quiz_date=(now() at time zone 'Asia/Kolkata')::date
  loop
    perform english.rebalance_daily_category_diversity(r.user_id,r.quiz_date,120);
  end loop;
end
$repair_today$;
