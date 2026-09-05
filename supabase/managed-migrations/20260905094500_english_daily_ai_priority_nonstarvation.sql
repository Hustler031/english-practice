-- Stage 1: AI Targeted is a priority/overlay signal, never a base Daily reason.
-- If enough distinct Daily-eligible concepts exist, the selector must fill to the requested target.

create or replace function english.daily_reason(p_user_id uuid,p_question_id text,p_batch_date date)
returns text
language sql
stable security definer
set search_path to 'pg_catalog','english','auth'
as $function$
with x as (
  select q,
         coalesce(s.attempts,0) attempts,
         coalesce(s.status,'New') state,
         s.next_review,
         coalesce(s.mastered,false) mastered,
         coalesce(s.last_marked,false) starred,
         coalesce(d.difficult,false) difficult,
         coalesce(r.route,'') route
  from english.questions q
  left join english.question_state s on s.user_id=p_user_id and s.question_id=q.question_id
  left join english.difficult_state d on d.user_id=p_user_id and d.question_id=q.question_id
  left join english.learning_route_state r on r.user_id=p_user_id and r.question_id=q.question_id
  where q.question_id=p_question_id
)
select case
  when not (q).active or mastered or route='fast_track' then ''
  when attempts=0 and english.is_genuine_bank_question(q) then 'Controlled New'
  when next_review is null
    or next_review>((p_batch_date::timestamp+interval '1 day - 1 millisecond') at time zone 'Asia/Kolkata') then ''
  when state='Persistent Weak' then 'Persistent Weak'
  when state='Weak' then 'Weak'
  when state='Fragile' then 'Fragile'
  when difficult then 'Difficult Review'
  when starred then 'Marked Review'
  when state='Learning' then 'Learning'
  else 'Due Spaced Revision'
end
from x;
$function$;

-- Top-up-safe successor to create_daily_core_20260902. It preserves the existing
-- quota/cap balancing first, then performs one final uncapped-by-reason fill so
-- category caps can never leave capacity unused while distinct eligible concepts remain.
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
  select count(*),coalesce(max(d.sequence),0)
  into v_count,v_sequence_base
  from english.daily_current d
  where d.user_id=p_user_id and d.quiz_date=p_batch_date
    and (
      lower(coalesce(d.status,''))='completed'
      or english.daily_reason(p_user_id,d.question_id,p_batch_date)<>''
    );

  if v_count>=v_target then return v_count; end if;

  create temporary table if not exists pg_temp.ep_daily_candidates(
    question_id text primary key,
    concept_key text,
    concept_id text,
    concept_state text,
    concept_confidence numeric,
    concept_next_review timestamptz,
    reason text,
    score numeric,
    priority integer,
    signals text[],
    snapshot jsonb
  ) on commit drop;
  truncate pg_temp.ep_daily_candidates;

  insert into pg_temp.ep_daily_candidates(
    question_id,concept_key,concept_id,concept_state,concept_confidence,concept_next_review,
    reason,score,priority,signals,snapshot
  )
  select
    q.question_id,
    coalesce(cm.concept_id,q.question_id),
    cm.concept_id,
    coalesce(ce.coverage_state,'unseen'),
    coalesce(ce.confidence_score,0),
    ce.next_review,
    r.reason,
    english.daily_reason_base_score(r.reason)
    + coalesce(cp.penalty,0)*70
    + least(120,greatest(0,coalesce(floor(extract(epoch from (((p_batch_date::timestamp + interval '1 day - 1 millisecond') at time zone 'Asia/Kolkata')-s.next_review))/86400),0))) * 12
    + case when coalesce(s.last_marked,false) then 12 else 0 end
    + case when coalesce(ds.difficult,false) then 10 else 0 end
    + case coalesce(ce.coverage_state,'unseen')
        when 'weak' then 220
        when 'retention_risk' then 180
        when 'seen' then 35
        when 'unseen' then 25
        when 'secure' then -25
        when 'exam_ready' then -110
        else 0
      end
    + case when ce.next_review is not null and ce.next_review<=now() then 80 else 0 end
    + case coalesce(c.exam_relevance,'medium') when 'high' then 20 when 'low' then -15 else 0 end
    + random()*20,
    english.daily_reason_base_score(r.reason),
    english.daily_signal_codes(
      r.reason,coalesce(s.status,'New'),
      s.next_review is not null and s.next_review <= ((p_batch_date::timestamp + interval '1 day - 1 millisecond') at time zone 'Asia/Kolkata'),
      coalesce(s.last_marked,false),coalesce(ds.difficult,false),
      coalesce(s.attempts,0)=0 and english.is_genuine_bank_question(q)
    ),
    jsonb_build_object(
      'selectedAt',now(),'batchDate',p_batch_date,
      'state',coalesce(s.status,'New'),'attempts',coalesce(s.attempts,0),
      'correct',coalesce(s.correct,0),'wrong',coalesce(s.wrong,0),
      'accuracy',coalesce(s.accuracy,0),'nextReview',s.next_review,
      'starred',coalesce(s.last_marked,false),'difficult',coalesce(ds.difficult,false),
      'category',english.learning_category(q.topic),
      'categoryPenalty',coalesce(cp.penalty,0),
      'conceptId',cm.concept_id,
      'conceptCoverage',coalesce(ce.coverage_state,'unseen'),
      'conceptConfidence',coalesce(ce.confidence_score,0),
      'conceptNextReview',ce.next_review,
      'daysOverdue',greatest(0,coalesce(floor(extract(epoch from (((p_batch_date::timestamp + interval '1 day - 1 millisecond') at time zone 'Asia/Kolkata')-s.next_review))/86400),0))
    )
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
    and not exists(
      select 1
      from english.daily_current d
      left join english.question_concept_mappings dm on dm.question_id=d.question_id
      where d.user_id=p_user_id and d.quiz_date=p_batch_date
        and coalesce(dm.concept_id,d.question_id)=coalesce(cm.concept_id,q.question_id)
    )
    and not (
      p_batch_date=((now() at time zone 'Asia/Kolkata')::date)
      and exists(
        select 1
        from english.attempts a
        left join english.question_concept_mappings am on am.question_id=a.question_id
        where a.user_id=p_user_id
          and lower(coalesce(a.module,''))='daily'
          and (a.attempted_at at time zone 'Asia/Kolkata')::date=p_batch_date
          and coalesce(am.concept_id,a.question_id)=coalesce(cm.concept_id,q.question_id)
      )
    );

  foreach v_reason in array array[
    'Controlled New','Persistent Weak','Weak','Fragile','Due Spaced Revision',
    'Learning','Marked Review','Difficult Review','Mixed Revision'
  ] loop
    exit when v_count>=v_target;
    v_take:=least(english.daily_quota(v_reason,v_target),v_target-v_count);

    with base as (
      select c.*,
        row_number() over(partition by c.concept_key order by c.score desc,c.question_id) concept_pick
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
    insert into english.daily_current(
      user_id,question_id,sequence,priority,reason,quiz_date,status,topic,concept_id,
      selection_signals,selection_snapshot
    )
    select
      p_user_id,p.question_id,
      v_sequence_base+row_number() over(order by p.score desc)::int,
      round(p.score)::int,p.reason,p_batch_date,'New',q.topic,
      coalesce(p.concept_id,q.concept_id),p.signals,p.snapshot
    from pick p join english.questions q on q.question_id=p.question_id
    order by p.score desc;

    get diagnostics v_inserted=row_count;
    v_count:=v_count+v_inserted;
    v_sequence_base:=v_sequence_base+v_inserted;
  end loop;

  if v_count<v_target then
    with existing as (
      select reason,count(*) n from english.daily_current
      where user_id=p_user_id and quiz_date=p_batch_date group by reason
    ), ranked as (
      select c.*,
        row_number() over(partition by c.reason order by c.score desc) reason_rn,
        row_number() over(partition by c.concept_key order by c.score desc,c.question_id) concept_rn
      from pg_temp.ep_daily_candidates c
      where not exists(
        select 1 from english.daily_current d
        left join english.question_concept_mappings dm on dm.question_id=d.question_id
        where d.user_id=p_user_id and d.quiz_date=p_batch_date
          and coalesce(dm.concept_id,d.question_id)=c.concept_key
      )
    ), eligible as (
      select r.*
      from ranked r
      left join existing e on e.reason=r.reason
      where r.concept_rn=1
        and r.reason_rn<=greatest(0,english.daily_cap(r.reason,v_target)-coalesce(e.n,0))
      order by r.score desc
      limit (v_target-v_count)
    )
    insert into english.daily_current(
      user_id,question_id,sequence,priority,reason,quiz_date,status,topic,concept_id,
      selection_signals,selection_snapshot
    )
    select
      p_user_id,e.question_id,
      v_sequence_base+row_number() over(order by e.score desc)::int,
      round(e.score)::int,e.reason,p_batch_date,'New',q.topic,
      coalesce(e.concept_id,q.concept_id),e.signals,e.snapshot
    from eligible e join english.questions q on q.question_id=e.question_id
    order by e.score desc;

    get diagnostics v_inserted=row_count;
    v_count:=v_count+v_inserted;
    v_sequence_base:=v_sequence_base+v_inserted;
  end if;

  -- Capacity guarantee: balancing caps are preferences, not permission to underfill.
  if v_count<v_target then
    with ranked as (
      select c.*,
        row_number() over(partition by c.concept_key order by c.score desc,c.question_id) concept_rn
      from pg_temp.ep_daily_candidates c
      where not exists(
        select 1 from english.daily_current d
        left join english.question_concept_mappings dm on dm.question_id=d.question_id
        where d.user_id=p_user_id and d.quiz_date=p_batch_date
          and coalesce(dm.concept_id,d.question_id)=c.concept_key
      )
    ), eligible as (
      select * from ranked
      where concept_rn=1
      order by score desc
      limit (v_target-v_count)
    )
    insert into english.daily_current(
      user_id,question_id,sequence,priority,reason,quiz_date,status,topic,concept_id,
      selection_signals,selection_snapshot
    )
    select
      p_user_id,e.question_id,
      v_sequence_base+row_number() over(order by e.score desc)::int,
      round(e.score)::int,e.reason,p_batch_date,'New',q.topic,
      coalesce(e.concept_id,q.concept_id),e.signals,e.snapshot
    from eligible e join english.questions q on q.question_id=e.question_id
    order by e.score desc;

    get diagnostics v_inserted=row_count;
    v_count:=v_count+v_inserted;
  end if;

  return v_count;
end;
$function$;

-- Targeted is injected only from questions that are already Daily-eligible under their
-- base learning reason. The base reason is preserved; TARGET is a secondary signal.
create or replace function english.rebalance_daily_targeted(p_user_id uuid,p_batch_date date,p_target integer)
returns integer
language plpgsql
security definer
set search_path to 'pg_catalog','english','auth'
as $function$
declare
  wanted integer:=greatest(1,least(18,ceil(greatest(1,p_target)*.10)::int));
  existing_n integer;
  replace_n integer;
begin
  select count(*) into existing_n
  from english.daily_current d
  where d.user_id=p_user_id and d.quiz_date=p_batch_date
    and coalesce(d.selection_signals,'{}'::text[]) @> array['TARGET']::text[];

  replace_n:=greatest(0,wanted-existing_n);
  if replace_n=0 then return existing_n; end if;

  with targets as (
    select q.question_id,q.topic,m.concept_id,
           english.daily_reason(p_user_id,q.question_id,p_batch_date) base_reason,
           coalesce(ce.confidence_score,0) confidence,
           english.daily_signal_codes(
             english.daily_reason(p_user_id,q.question_id,p_batch_date),coalesce(s.status,'New'),
             s.next_review is not null and s.next_review<=((p_batch_date::timestamp+interval '1 day - 1 millisecond') at time zone 'Asia/Kolkata'),
             coalesce(s.last_marked,false),coalesce(ds.difficult,false),
             coalesce(s.attempts,0)=0 and english.is_genuine_bank_question(q)
           ) || array['TARGET']::text[] signals,
           row_number() over(
             partition by coalesce(m.concept_id,q.question_id)
             order by case coalesce(r.metadata->>'targeted_kind','need_learning')
               when 'confusion' then 1 when 'need_learning' then 2 when 'transfer_check' then 3 else 4 end,
               coalesce(ce.next_review,'epoch'::timestamptz),r.updated_at desc,q.question_id
           ) concept_pick
    from english.learning_route_state r
    join english.questions q on q.question_id=r.question_id and q.active
    left join english.question_concept_mappings m on m.question_id=q.question_id
    left join english.concept_evidence ce on ce.user_id=p_user_id and ce.concept_id=m.concept_id
    left join english.question_state s on s.user_id=p_user_id and s.question_id=q.question_id
    left join english.difficult_state ds on ds.user_id=p_user_id and ds.question_id=q.question_id
    where r.user_id=p_user_id and r.route='targeted'
      and english.question_visible_to_user(p_user_id,q.question_id)
      and not coalesce(s.mastered,false)
      and english.daily_reason(p_user_id,q.question_id,p_batch_date)<>''
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
          and (a.attempted_at at time zone 'Asia/Kolkata')::date=p_batch_date
          and coalesce(am.concept_id,a.question_id)=coalesce(m.concept_id,q.question_id)
      )
  ), pick as (
    select *,row_number() over(order by confidence asc,question_id) rn
    from targets where concept_pick=1 limit replace_n
  ), removable as (
    select d.question_id,d.sequence,
           row_number() over(order by
             case d.reason when 'Controlled New' then 1 when 'Learning' then 2
               when 'Marked Review' then 3 when 'Difficult Review' then 4
               when 'Due Spaced Revision' then 5 when 'Fragile' then 6
               when 'Weak' then 7 when 'Persistent Weak' then 8 else 9 end,
             d.priority asc,d.sequence desc) rn
    from english.daily_current d
    where d.user_id=p_user_id and d.quiz_date=p_batch_date
      and not (coalesce(d.selection_signals,'{}'::text[]) @> array['TARGET']::text[])
      and lower(coalesce(d.status,''))<>'completed'
      and not exists(
        select 1 from english.attempts a
        where a.user_id=p_user_id and a.question_id=d.question_id
          and (a.attempted_at at time zone 'Asia/Kolkata')::date=p_batch_date
      )
    limit replace_n
  ), pairs as (
    select r.question_id old_id,r.sequence,p.* from removable r join pick p using(rn)
  )
  update english.daily_current d
  set question_id=p.question_id,
      priority=greatest(d.priority,950),
      reason=p.base_reason,
      status='New',topic=p.topic,concept_id=p.concept_id,
      selection_signals=p.signals,
      selection_snapshot=jsonb_build_object(
        'selectedAt',now(),'batchDate',p_batch_date,'reason',p.base_reason,
        'conceptId',p.concept_id,'conceptConfidence',p.confidence,'targeted',true
      )
  from pairs p
  where d.user_id=p_user_id and d.question_id=p.old_id and d.sequence=p.sequence;

  select count(*) into existing_n
  from english.daily_current d
  where d.user_id=p_user_id and d.quiz_date=p_batch_date
    and coalesce(d.selection_signals,'{}'::text[]) @> array['TARGET']::text[];
  return existing_n;
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
  select count(*) into n
  from english.daily_current d
  where d.user_id=p_user_id and d.quiz_date=p_batch_date
    and (lower(coalesce(d.status,''))='completed' or english.daily_reason(p_user_id,d.question_id,p_batch_date)<>'');
  return n;
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
  v_before integer;
  v_after integer;
begin
  perform pg_advisory_xact_lock(hashtextextended('english.daily.'||p_user_id::text,0));

  select count(*) into v_before
  from english.daily_current d
  where d.user_id=p_user_id and d.quiz_date=p_batch_date
    and (lower(coalesce(d.status,''))='completed' or english.daily_reason(p_user_id,d.question_id,p_batch_date)<>'');

  -- Only untouched, now-ineligible rows may be pruned. Learner attempts/completions/history survive.
  delete from english.daily_current d
  where d.user_id=p_user_id and d.quiz_date=p_batch_date
    and lower(coalesce(d.status,''))<>'completed'
    and english.daily_reason(p_user_id,d.question_id,p_batch_date)=''
    and not exists(
      select 1 from english.attempts a
      where a.user_id=p_user_id and a.question_id=d.question_id
        and (a.attempted_at at time zone 'Asia/Kolkata')::date=p_batch_date
    );

  perform english.create_daily_core_20260905(p_user_id,p_batch_date,v_target);
  perform english.rebalance_daily_targeted(p_user_id,p_batch_date,v_target);

  select count(*) into v_after
  from english.daily_current d
  where d.user_id=p_user_id and d.quiz_date=p_batch_date
    and (lower(coalesce(d.status,''))='completed' or english.daily_reason(p_user_id,d.question_id,p_batch_date)<>'');

  return greatest(0,v_after-v_before);
end;
$function$;

revoke all on function english.repair_daily_shortfall(uuid,date,integer) from public,anon,authenticated;
grant execute on function english.repair_daily_shortfall(uuid,date,integer) to service_role;

create or replace function english.ensure_daily(p_user_id uuid,p_target integer default 120)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','english','auth'
as $function$
declare
  v_today date:=(now() at time zone 'Asia/Kolkata')::date;
  v_batch date;
  v_pending integer;
  v_created integer:=0;
  v_archived integer:=0;
  v_next date;
  v_total integer;
begin
  select min(quiz_date) into v_batch from english.daily_current where user_id=p_user_id;
  if v_batch is null then
    v_batch:=v_today;
    v_created:=english.create_daily(p_user_id,v_batch,p_target);
  else
    select count(*) into v_pending
    from english.daily_current d
    where d.user_id=p_user_id and d.quiz_date=v_batch
      and lower(coalesce(d.status,''))<>'completed'
      and english.daily_reason(p_user_id,d.question_id,v_batch)<>'';

    if v_batch<v_today and v_pending=0 then
      v_archived:=english.archive_daily(p_user_id,v_batch);
      v_next:=v_batch+1;
      v_batch:=v_next;
      v_created:=english.create_daily(p_user_id,v_batch,p_target);
    elsif v_batch=v_today then
      v_created:=english.repair_daily_shortfall(p_user_id,v_batch,p_target);
    end if;
  end if;

  select count(*) into v_total
  from english.daily_current d
  where d.user_id=p_user_id and d.quiz_date=v_batch
    and (lower(coalesce(d.status,''))='completed' or english.daily_reason(p_user_id,d.question_id,v_batch)<>'');

  return jsonb_build_object(
    'ok',true,'batch_date',v_batch,'today',v_today,
    'pending_previous_day',(v_batch<v_today),
    'created',v_created,'archived',v_archived,
    'target_is_maximum',false,'target_guaranteed_when_eligible',true,
    'total',v_total,
    'completed',(select count(*) from english.current_daily_items(p_user_id) where lower(coalesce(status,''))='completed'),
    'remaining',(select count(*) from english.current_daily_items(p_user_id) where lower(coalesce(status,''))<>'completed')
  );
end;
$function$;
