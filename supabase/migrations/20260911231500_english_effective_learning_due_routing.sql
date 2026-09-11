-- Effective learning-due routing v1.
-- Reconciles question-level SRS and concept-level CI without collapsing them into one clock.
-- Safety invariant: an earlier concept clock may request a fresh/alternate concept validation,
-- but it must never pull the latest exact question forward before its own question-level due date.

create or replace function english.effective_learning_due(
  p_user_id uuid,
  p_question_id text,
  p_batch_date date default ((now() at time zone 'Asia/Kolkata')::date)
)
returns table(
  concept_key text,
  question_id text,
  source_question_id text,
  question_due timestamptz,
  source_question_due timestamptz,
  concept_due timestamptz,
  effective_due timestamptz,
  due_source text,
  routing_mode text,
  question_due_by_date boolean,
  concept_due_by_date boolean,
  concept_clock_leads boolean,
  alternate_available boolean,
  fresh_alternate_available boolean,
  question_state text,
  concept_state text,
  concept_confidence numeric
)
language sql
stable
security definer
set search_path='pg_catalog','english','auth'
as $function$
with target as (
  select
    q.question_id,
    english.focus_concept_key(q.question_id) concept_key,
    s.next_review question_due,
    coalesce(s.status,'New') question_state,
    ce.next_review concept_due,
    coalesce(ce.coverage_state,'unseen') concept_state,
    coalesce(ce.confidence_score,0) concept_confidence
  from english.questions q
  left join english.question_state s
    on s.user_id=p_user_id and s.question_id=q.question_id
  left join english.concept_evidence ce
    on ce.user_id=p_user_id and ce.concept_id=english.focus_concept_key(q.question_id)
  where q.question_id=p_question_id
    and q.active
    and english.question_visible_to_user(p_user_id,q.question_id)
), source_q as (
  select
    s.question_id,
    s.next_review
  from target t
  join english.question_state s
    on s.user_id=p_user_id
   and english.focus_concept_key(s.question_id)=t.concept_key
   and coalesce(s.attempts,0)>0
  order by s.last_attempt desc nulls last,s.question_id
  limit 1
), variants as (
  select
    count(*) filter(
      where q2.question_id is distinct from sq.question_id
        and not coalesce(s2.mastered,false)
    )::int alternate_count,
    count(*) filter(
      where q2.question_id is distinct from sq.question_id
        and not coalesce(s2.mastered,false)
        and coalesce(s2.attempts,0)=0
    )::int fresh_alternate_count
  from target t
  left join source_q sq on true
  join english.questions q2
    on q2.active
   and english.question_visible_to_user(p_user_id,q2.question_id)
   and english.focus_concept_key(q2.question_id)=t.concept_key
  left join english.question_state s2
    on s2.user_id=p_user_id and s2.question_id=q2.question_id
), calc as (
  select
    t.*,
    sq.question_id source_question_id,
    sq.next_review source_question_due,
    coalesce(v.alternate_count,0)>0 alternate_available,
    coalesce(v.fresh_alternate_count,0)>0 fresh_alternate_available,
    ((p_batch_date::timestamp+interval '1 day - 1 millisecond') at time zone 'Asia/Kolkata') day_end
  from target t
  left join source_q sq on true
  cross join variants v
), flags as (
  select c.*,
    (c.question_due is not null and c.question_due<=c.day_end) question_due_by_date,
    (c.concept_due is not null and c.concept_due<=c.day_end) concept_due_by_date,
    (
      c.concept_due is not null
      and (c.source_question_due is null or c.concept_due<c.source_question_due)
    ) concept_clock_leads
  from calc c
)
select
  f.concept_key,
  f.question_id,
  f.source_question_id,
  f.question_due,
  f.source_question_due,
  f.concept_due,
  case
    when f.concept_due_by_date and f.concept_clock_leads and f.alternate_available then f.concept_due
    else f.source_question_due
  end effective_due,
  case
    when f.concept_due_by_date and f.concept_clock_leads and f.alternate_available then 'concept'
    when f.source_question_due is not null then 'question'
    else 'none'
  end due_source,
  case
    when f.concept_due_by_date and f.concept_clock_leads and f.alternate_available then 'concept_validation'
    when f.source_question_due is not null and f.source_question_due<=f.day_end then 'question_review'
    when f.concept_due_by_date and f.concept_clock_leads and not f.alternate_available then 'wait_for_question_due'
    else 'none'
  end routing_mode,
  f.question_due_by_date,
  f.concept_due_by_date,
  f.concept_clock_leads,
  f.alternate_available,
  f.fresh_alternate_available,
  f.question_state,
  f.concept_state,
  f.concept_confidence
from flags f;
$function$;

revoke all on function english.effective_learning_due(uuid,text,date) from public,anon,authenticated;

-- Daily Mix performance-v2 keeps its existing buildVersion for downstream compatibility,
-- but now admits a bounded Concept Validation lane when the concept clock leads the exact-question clock.
create or replace function english.daily_performance_candidates(p_user_id uuid,p_batch_date date)
returns table(
  question_id text,concept_key text,concept_id text,reason text,score integer,category text,
  signals text[],snapshot jsonb
)
language sql
stable
security definer
set search_path='pg_catalog','english','auth'
as $function$
with learning as materialized (
  select * from english.learning_need_candidates(p_user_id,p_batch_date)
), recent_daily as materialized (
  select distinct coalesce(nullif(a.concept_id,''),english.focus_concept_key(a.question_id)) concept_key
  from english.attempts a
  where a.user_id=p_user_id
    and lower(btrim(coalesce(a.module,'')))='daily'
    and a.attempted_at >= ((p_batch_date-3)::timestamp at time zone 'Asia/Kolkata')
    and a.attempted_at < (p_batch_date::timestamp at time zone 'Asia/Kolkata')
), concept_last as materialized (
  select distinct on (x.concept_key)
    x.concept_key,
    x.question_id source_question_id,
    x.last_attempt source_last_attempt,
    x.next_review source_question_due
  from (
    select
      english.focus_concept_key(s.question_id) concept_key,
      s.question_id,
      s.last_attempt,
      s.next_review
    from english.question_state s
    where s.user_id=p_user_id
      and coalesce(s.attempts,0)>0
  ) x
  where nullif(x.concept_key,'') is not null
  order by x.concept_key,x.last_attempt desc nulls last,x.question_id
), base as materialized (
  select
    q.question_id,
    english.focus_concept_key(q.question_id) concept_key,
    coalesce(cm.concept_id,nullif(q.concept_id,'')) concept_id,
    q.topic,
    english.learning_category(q.topic) category,
    coalesce(s.status,'New') state,
    coalesce(s.attempts,0) attempts,
    coalesce(s.wrong,0) wrong,
    coalesce(s.accuracy,0) accuracy,
    s.last_attempt,
    s.next_review,
    coalesce(s.mastered,false) mastered,
    coalesce(ds.difficult,false) difficult,
    coalesce(lr.route,'') route,
    ln.primary_need,ln.need_tier,ln.priority_score learning_score,ln.reasons learning_reasons,
    ln.targeted_kind,ln.recent_failures,ln.confusion_count,
    coalesce(ce.coverage_state,'unseen') concept_state,
    coalesce(ce.confidence_score,0) concept_confidence,
    coalesce(ce.attempts,0) concept_attempts,
    ce.next_review concept_next_review,
    cl.source_question_id,
    cl.source_question_due,
    cl.source_last_attempt,
    coalesce(qm.too_easy,false) too_easy,
    coalesce(qm.observed_difficulty,0.5) observed_difficulty,
    (rd.concept_key is not null) recent_daily,
    ((p_batch_date::timestamp+interval '1 day - 1 millisecond') at time zone 'Asia/Kolkata') day_end
  from english.questions q
  left join english.question_state s on s.user_id=p_user_id and s.question_id=q.question_id
  left join english.difficult_state ds on ds.user_id=p_user_id and ds.question_id=q.question_id
  left join english.learning_route_state lr on lr.user_id=p_user_id and lr.question_id=q.question_id
  left join lateral (
    select m.concept_id
    from english.question_concept_mappings m
    where m.question_id=q.question_id
    order by coalesce(m.mapping_confidence,0) desc,m.updated_at desc nulls last
    limit 1
  ) cm on true
  left join learning ln on ln.concept_key=english.focus_concept_key(q.question_id)
  left join english.concept_evidence ce on ce.user_id=p_user_id and ce.concept_id=english.focus_concept_key(q.question_id)
  left join concept_last cl on cl.concept_key=english.focus_concept_key(q.question_id)
  left join english.question_quality_metrics qm on qm.user_id=p_user_id and qm.question_id=q.question_id
  left join recent_daily rd on rd.concept_key=english.focus_concept_key(q.question_id)
  where q.active
    and english.question_visible_to_user(p_user_id,q.question_id)
    and not coalesce(s.mastered,false)
    and coalesce(lr.route,'')<>'fast_track'
    and english.hindu_daily_eligible(p_user_id,q.question_id)
    and not exists(
      select 1 from english.daily_focus_items f
      where f.user_id=p_user_id and f.batch_date=p_batch_date
        and f.concept_key=english.focus_concept_key(q.question_id)
    )
    and not exists(
      select 1 from english.attempts a
      where a.user_id=p_user_id
        and (a.attempted_at at time zone 'Asia/Kolkata')::date>=p_batch_date
        and coalesce(nullif(a.concept_id,''),english.focus_concept_key(a.question_id))=english.focus_concept_key(q.question_id)
    )
), classified as materialized (
  select b.*,
    (
      b.concept_attempts>0
      and b.source_question_id is not null
      and b.question_id<>b.source_question_id
      and b.concept_next_review is not null
      and b.concept_next_review<=b.day_end
      and (b.source_question_due is null or b.concept_next_review<b.source_question_due)
    ) concept_validation_due,
    case
      when b.targeted_kind in ('confusion','transfer_check','need_learning') then 'Targeted Performance'
      when b.primary_need is not null then 'Learning Risk'
      when b.concept_attempts>0
        and b.source_question_id is not null
        and b.question_id<>b.source_question_id
        and b.concept_next_review is not null
        and b.concept_next_review<=b.day_end
        and (b.source_question_due is null or b.concept_next_review<b.source_question_due)
        then 'Concept Validation'
      when b.attempts=0 and english.is_genuine_bank_question((select q from english.questions q where q.question_id=b.question_id)) then 'Controlled New'
      when b.attempts>0 and b.state in ('Fragile','Learning','Strong') and not b.recent_daily then 'Mixed Performance'
      else null
    end perf_reason
  from base b
), scored as materialized (
  select c.*,
    (
      case c.perf_reason
        when 'Targeted Performance' then 1100
        when 'Learning Risk' then 1000
        when 'Concept Validation' then 900
        when 'Controlled New' then 820
        when 'Mixed Performance' then 700
        else 0
      end
      + case when c.perf_reason in ('Targeted Performance','Learning Risk') then least(140,coalesce(c.learning_score,0)/8) else 0 end
      + case c.state when 'Fragile' then 80 when 'Learning' then 50 when 'Strong' then 20 else 0 end
      + case when c.difficult then 20 else 0 end
      + least(90,greatest(0,coalesce(floor(extract(epoch from (now()-c.last_attempt))/86400),0)))
      + least(40,greatest(0,c.recent_failures)*10)
      + least(30,greatest(0,c.confusion_count)*10)
      + case when c.perf_reason='Concept Validation' and c.attempts=0 then 35 else 0 end
      + case when c.perf_reason='Concept Validation' then
          least(60,greatest(0,coalesce(floor(extract(epoch from (c.day_end-c.concept_next_review))/86400),0))*10)
        else 0 end
      + case when c.too_easy then -50 else round(c.observed_difficulty*20)::int end
    )::int score
  from classified c
  where c.perf_reason is not null
), deduped as materialized (
  select s.*,
    row_number() over(partition by s.concept_key order by
      case s.perf_reason
        when 'Targeted Performance' then 1
        when 'Learning Risk' then 2
        when 'Concept Validation' then 3
        when 'Controlled New' then 4
        else 5
      end,
      case when s.perf_reason='Concept Validation' then s.attempts else 0 end,
      s.score desc,s.last_attempt nulls first,s.question_id
    ) concept_pick
  from scored s
)
select
  d.question_id,d.concept_key,d.concept_id,d.perf_reason,d.score,d.category,
  array_remove(
    case d.perf_reason
      when 'Targeted Performance' then array['PERFORMANCE','TARGET','TRANSFER']::text[]||coalesce(d.learning_reasons,'{}'::text[])
      when 'Learning Risk' then array['PERFORMANCE','LEARNING_RISK']::text[]||coalesce(d.learning_reasons,'{}'::text[])
      when 'Concept Validation' then array['PERFORMANCE','CONCEPT_DUE',case when d.attempts=0 then 'FRESH_VARIANT' else 'ALTERNATE_VARIANT' end]::text[]
      when 'Controlled New' then array['PERFORMANCE','CONTROLLED_NEW']::text[]
      else array['PERFORMANCE','MIXED']::text[]
    end,
    null
  ) signals,
  jsonb_strip_nulls(jsonb_build_object(
    'selectedAt',now(),'batchDate',p_batch_date,'buildVersion','performance-v2',
    'dueRoutingVersion','effective-learning-due-v1',
    'selectionObjective','performance','reason',d.perf_reason,'state',d.state,
    'category',d.category,'conceptId',d.concept_id,'conceptCoverage',d.concept_state,
    'conceptConfidence',d.concept_confidence,'primaryLearningNeed',d.primary_need,
    'learningNeedTier',d.need_tier,'targetedKind',d.targeted_kind,
    'recentFailures',d.recent_failures,'confusionCount',d.confusion_count,
    'lastAttempt',d.last_attempt,
    'reviewClockAtSelection',d.next_review,
    'questionReviewAt',d.next_review,
    'sourceQuestionId',d.source_question_id,
    'sourceQuestionReviewAt',d.source_question_due,
    'conceptReviewAt',d.concept_next_review,
    'effectiveLearningDueAt',case when d.perf_reason='Concept Validation' then d.concept_next_review else d.next_review end,
    'effectiveDueSource',case when d.perf_reason='Concept Validation' then 'concept' when d.next_review is not null then 'question' else null end,
    'freshVariantPreferred',(d.perf_reason='Concept Validation'),
    'reviewClockUsedForAdmission',(d.perf_reason='Concept Validation'),
    'reviewClockUsedForScore',(d.perf_reason='Concept Validation')
  )) snapshot
from deduped d
where d.concept_pick=1;
$function$;

revoke all on function english.daily_performance_candidates(uuid,date) from public,anon,authenticated;

create or replace function english.create_daily_performance_v2(p_user_id uuid,p_batch_date date,p_target integer default 120)
returns integer
language plpgsql
security definer
set search_path='pg_catalog','english','auth'
as $function$
declare
  v_target integer:=greatest(1,least(120,coalesce(p_target,120)));
  v_reason text;
  v_quota integer;
  v_sequence integer:=0;
  v_inserted integer:=0;
  v_count integer:=0;
begin
  select count(*),coalesce(max(sequence),0)
    into v_count,v_sequence
  from english.daily_current
  where user_id=p_user_id and quiz_date=p_batch_date;

  if v_count>=v_target then return v_count; end if;

  create temporary table if not exists pg_temp.daily_perf_candidates(
    question_id text primary key,concept_key text,concept_id text,reason text,score integer,
    category text,signals text[],snapshot jsonb
  ) on commit drop;
  truncate pg_temp.daily_perf_candidates;

  insert into pg_temp.daily_perf_candidates
  select * from english.daily_performance_candidates(p_user_id,p_batch_date);

  foreach v_reason in array array['Controlled New','Targeted Performance','Learning Risk','Concept Validation','Mixed Performance'] loop
    exit when v_count>=v_target;
    v_quota:=case v_reason
      when 'Controlled New' then greatest(1,round(v_target*.125)::int)
      when 'Targeted Performance' then greatest(1,round(v_target*.167)::int)
      when 'Learning Risk' then greatest(1,round(v_target*.292)::int)
      when 'Concept Validation' then greatest(1,round(v_target*.125)::int)
      else greatest(1,v_target)
    end;
    v_quota:=least(v_quota,v_target-v_count);

    with ranked as (
      select c.*,
             row_number() over(partition by c.category order by c.score desc,c.question_id) category_rank
      from pg_temp.daily_perf_candidates c
      where c.reason=v_reason
        and not exists(
          select 1 from english.daily_current d
          where d.user_id=p_user_id and d.quiz_date=p_batch_date and d.question_id=c.question_id
        )
        and not exists(
          select 1 from english.daily_current d
          where d.user_id=p_user_id and d.quiz_date=p_batch_date
            and coalesce(nullif(d.concept_id,''),english.focus_concept_key(d.question_id))=c.concept_key
        )
    ), pick as (
      select * from ranked
      order by category_rank,category,score desc,question_id
      limit v_quota
    )
    insert into english.daily_current(
      user_id,question_id,sequence,priority,reason,quiz_date,status,topic,concept_id,selection_signals,selection_snapshot
    )
    select p_user_id,p.question_id,
           v_sequence+row_number() over(order by p.category_rank,p.category,p.score desc,p.question_id)::int,
           p.score,p.reason,p_batch_date,'New',q.topic,p.concept_id,p.signals,p.snapshot
    from pick p join english.questions q on q.question_id=p.question_id
    order by p.category_rank,p.category,p.score desc,p.question_id;

    get diagnostics v_inserted=row_count;
    v_count:=v_count+v_inserted;
    v_sequence:=v_sequence+v_inserted;
  end loop;

  if v_count<v_target then
    with ranked as (
      select c.*,
             row_number() over(partition by c.category order by c.score desc,c.question_id) category_rank
      from pg_temp.daily_perf_candidates c
      where not exists(
        select 1 from english.daily_current d
        where d.user_id=p_user_id and d.quiz_date=p_batch_date
          and coalesce(nullif(d.concept_id,''),english.focus_concept_key(d.question_id))=c.concept_key
      )
    ), pick as (
      select * from ranked
      order by category_rank,
               case reason
                 when 'Targeted Performance' then 1
                 when 'Learning Risk' then 2
                 when 'Concept Validation' then 3
                 when 'Mixed Performance' then 4
                 else 5
               end,
               category,score desc,question_id
      limit (v_target-v_count)
    )
    insert into english.daily_current(
      user_id,question_id,sequence,priority,reason,quiz_date,status,topic,concept_id,selection_signals,selection_snapshot
    )
    select p_user_id,p.question_id,
           v_sequence+row_number() over(order by p.category_rank,
             case p.reason
               when 'Targeted Performance' then 1
               when 'Learning Risk' then 2
               when 'Concept Validation' then 3
               when 'Mixed Performance' then 4
               else 5
             end,
             p.category,p.score desc,p.question_id)::int,
           p.score,p.reason,p_batch_date,'New',q.topic,p.concept_id,p.signals,p.snapshot
    from pick p join english.questions q on q.question_id=p.question_id
    order by p.category_rank,
             case p.reason
               when 'Targeted Performance' then 1
               when 'Learning Risk' then 2
               when 'Concept Validation' then 3
               when 'Mixed Performance' then 4
               else 5
             end,
             p.category,p.score desc,p.question_id;

    get diagnostics v_inserted=row_count;
    v_count:=v_count+v_inserted;
  end if;

  return v_count;
end;
$function$;

revoke all on function english.create_daily_performance_v2(uuid,date,integer) from public,anon,authenticated;
