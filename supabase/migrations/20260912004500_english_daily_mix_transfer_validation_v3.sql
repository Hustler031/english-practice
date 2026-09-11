-- Daily Mix performance-v3: preserve transfer testing without using the review clock.
-- Review Due owns calendar scheduling. Daily Mix may inspect review timestamps as metadata,
-- but they must not admit or score a question.

create or replace function english.daily_performance_candidates_v3(
  p_user_id uuid,
  p_batch_date date
)
returns table(
  question_id text,
  concept_key text,
  concept_id text,
  reason text,
  score integer,
  category text,
  signals text[],
  snapshot jsonb
)
language sql
stable
security definer
set search_path='pg_catalog','english','auth'
as $function$
with base as materialized (
  select
    c.question_id,
    c.concept_key,
    c.concept_id,
    c.reason,
    c.score,
    c.category,
    c.signals,
    (c.snapshot
      - 'dueRoutingVersion'
      - 'effectiveLearningDueAt'
      - 'effectiveDueSource')
      || jsonb_build_object(
        'buildVersion','performance-v3',
        'reviewClockUsedForAdmission',false,
        'reviewClockUsedForScore',false,
        'reviewClockRole','metadata_only'
      ) snapshot
  from english.daily_performance_candidates(p_user_id,p_batch_date) c
  where c.reason<>'Concept Validation'
), recent_daily as materialized (
  select distinct coalesce(nullif(a.concept_id,''),english.focus_concept_key(a.question_id)) concept_key
  from english.attempts a
  where a.user_id=p_user_id
    and lower(btrim(coalesce(a.module,'')))='daily'
    and a.attempted_at >= ((p_batch_date-3)::timestamp at time zone 'Asia/Kolkata')
    and a.attempted_at < (p_batch_date::timestamp at time zone 'Asia/Kolkata')
), source_by_concept as materialized (
  select distinct on (x.concept_key)
    x.concept_key,
    x.question_id source_question_id,
    x.last_attempt source_last_attempt
  from (
    select
      english.focus_concept_key(s.question_id) concept_key,
      s.question_id,
      s.last_attempt
    from english.question_state s
    where s.user_id=p_user_id
      and coalesce(s.attempts,0)>0
  ) x
  where nullif(x.concept_key,'') is not null
  order by x.concept_key,x.last_attempt desc nulls last,x.question_id
), transfer_raw as materialized (
  select
    q.question_id,
    english.focus_concept_key(q.question_id) concept_key,
    english.focus_concept_key(q.question_id) concept_id,
    english.learning_category(q.topic) category,
    coalesce(ce.coverage_state,'seen') concept_state,
    coalesce(ce.confidence_score,0) concept_confidence,
    coalesce(ce.attempts,0)::int concept_attempts,
    src.source_question_id,
    src.source_last_attempt,
    coalesce(qm.too_easy,false) too_easy,
    coalesce(qm.observed_difficulty,0.5) observed_difficulty
  from english.questions q
  left join english.question_state s
    on s.user_id=p_user_id and s.question_id=q.question_id
  left join english.learning_route_state lr
    on lr.user_id=p_user_id and lr.question_id=q.question_id
  join english.concept_evidence ce
    on ce.user_id=p_user_id
   and ce.concept_id=english.focus_concept_key(q.question_id)
   and coalesce(ce.attempts,0)>0
  join source_by_concept src
    on src.concept_key=english.focus_concept_key(q.question_id)
   and src.source_question_id<>q.question_id
  left join english.question_quality_metrics qm
    on qm.user_id=p_user_id and qm.question_id=q.question_id
  left join recent_daily rd
    on rd.concept_key=english.focus_concept_key(q.question_id)
  where q.active
    and english.question_visible_to_user(p_user_id,q.question_id)
    and coalesce(s.attempts,0)=0
    and not coalesce(s.mastered,false)
    and coalesce(lr.route,'')<>'fast_track'
    and english.hindu_daily_eligible(p_user_id,q.question_id)
    and rd.concept_key is null
    and (
      coalesce(ce.attempts,0)<=4
      or coalesce(ce.confidence_score,0)<80
      or coalesce(ce.coverage_state,'seen') in ('weak','retention_risk')
    )
    and not exists(
      select 1
      from english.daily_focus_items f
      where f.user_id=p_user_id
        and f.batch_date=p_batch_date
        and f.concept_key=english.focus_concept_key(q.question_id)
    )
    and not exists(
      select 1
      from english.attempts a
      where a.user_id=p_user_id
        and (a.attempted_at at time zone 'Asia/Kolkata')::date>=p_batch_date
        and coalesce(nullif(a.concept_id,''),english.focus_concept_key(a.question_id))=english.focus_concept_key(q.question_id)
    )
), transfer_scored as materialized (
  select
    t.*,
    (
      900
      + case t.concept_state
          when 'retention_risk' then 80
          when 'weak' then 70
          when 'seen' then 50
          when 'secure' then 20
          else 30
        end
      + case
          when t.concept_attempts=1 then 80
          when t.concept_attempts=2 then 60
          when t.concept_attempts between 3 and 4 then 35
          else 10
        end
      + least(80,greatest(0,80-round(t.concept_confidence)::int))
      + least(40,greatest(0,
          coalesce(floor(extract(epoch from (((p_batch_date::timestamp at time zone 'Asia/Kolkata')-t.source_last_attempt)))/86400),0)::int*5
        ))
      + case when t.too_easy then -50 else round(t.observed_difficulty*20)::int end
    )::int score
  from transfer_raw t
), transfer_dedup as materialized (
  select
    t.*,
    row_number() over(
      partition by t.concept_key
      order by t.score desc,t.source_last_attempt nulls first,t.question_id
    ) concept_pick
  from transfer_scored t
), transfer as materialized (
  select
    t.question_id,
    t.concept_key,
    t.concept_id,
    'Transfer Validation'::text reason,
    t.score,
    t.category,
    array['PERFORMANCE','TRANSFER_VALIDATION','FRESH_VARIANT']::text[] signals,
    jsonb_strip_nulls(jsonb_build_object(
      'selectedAt',now(),
      'batchDate',p_batch_date,
      'buildVersion','performance-v3',
      'selectionObjective','performance',
      'reason','Transfer Validation',
      'validationBasis','fresh_sibling_after_prior_concept_exposure',
      'category',t.category,
      'conceptId',t.concept_id,
      'conceptCoverage',t.concept_state,
      'conceptConfidence',t.concept_confidence,
      'conceptAttempts',t.concept_attempts,
      'sourceQuestionId',t.source_question_id,
      'sourceLastAttempt',t.source_last_attempt,
      'freshVariantPreferred',true,
      'reviewClockUsedForAdmission',false,
      'reviewClockUsedForScore',false,
      'reviewClockRole','metadata_only'
    )) snapshot
  from transfer_dedup t
  where t.concept_pick=1
    and not exists(select 1 from base b where b.concept_key=t.concept_key)
)
select * from base
union all
select * from transfer;
$function$;

revoke all on function english.daily_performance_candidates_v3(uuid,date) from public,anon,authenticated;

-- Keep the compatibility function name used by ensure_daily(), but source candidates from v3.
create or replace function english.create_daily_performance_v2(
  p_user_id uuid,
  p_batch_date date,
  p_target integer default 120
)
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
  select * from english.daily_performance_candidates_v3(p_user_id,p_batch_date);

  foreach v_reason in array array['Controlled New','Targeted Performance','Learning Risk','Transfer Validation','Mixed Performance'] loop
    exit when v_count>=v_target;
    v_quota:=case v_reason
      when 'Controlled New' then greatest(1,round(v_target*.125)::int)
      when 'Targeted Performance' then greatest(1,round(v_target*.167)::int)
      when 'Learning Risk' then greatest(1,round(v_target*.292)::int)
      when 'Transfer Validation' then greatest(1,round(v_target*.125)::int)
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
                 when 'Transfer Validation' then 3
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
               when 'Transfer Validation' then 3
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
               when 'Transfer Validation' then 3
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
