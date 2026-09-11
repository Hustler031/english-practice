-- Daily Mix performance-v2: review date is not an admission or scoring signal.
-- New batches use performance sampling; legacy in-progress batches keep legacy behavior.

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
    coalesce(qm.too_easy,false) too_easy,
    coalesce(qm.observed_difficulty,0.5) observed_difficulty,
    (rd.concept_key is not null) recent_daily
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
    case
      when b.attempts=0 and english.is_genuine_bank_question((select q from english.questions q where q.question_id=b.question_id)) then 'Controlled New'
      when b.targeted_kind in ('confusion','transfer_check','need_learning') then 'Targeted Performance'
      when b.primary_need is not null then 'Learning Risk'
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
      + case when c.too_easy then -50 else round(c.observed_difficulty*20)::int end
    )::int score
  from classified c
  where c.perf_reason is not null
), deduped as materialized (
  select s.*,
    row_number() over(partition by s.concept_key order by
      case s.perf_reason when 'Targeted Performance' then 1 when 'Learning Risk' then 2 when 'Controlled New' then 3 else 4 end,
      s.score desc,s.last_attempt nulls first,s.question_id) concept_pick
  from scored s
)
select
  d.question_id,d.concept_key,d.concept_id,d.perf_reason,d.score,d.category,
  array_remove(
    case d.perf_reason
      when 'Targeted Performance' then array['PERFORMANCE','TARGET','TRANSFER']::text[]||coalesce(d.learning_reasons,'{}'::text[])
      when 'Learning Risk' then array['PERFORMANCE','LEARNING_RISK']::text[]||coalesce(d.learning_reasons,'{}'::text[])
      when 'Controlled New' then array['PERFORMANCE','CONTROLLED_NEW']::text[]
      else array['PERFORMANCE','MIXED']::text[]
    end,
    null
  ) signals,
  jsonb_strip_nulls(jsonb_build_object(
    'selectedAt',now(),'batchDate',p_batch_date,'buildVersion','performance-v2',
    'selectionObjective','performance','reason',d.perf_reason,'state',d.state,
    'category',d.category,'conceptId',d.concept_id,'conceptCoverage',d.concept_state,
    'conceptConfidence',d.concept_confidence,'primaryLearningNeed',d.primary_need,
    'learningNeedTier',d.need_tier,'targetedKind',d.targeted_kind,
    'recentFailures',d.recent_failures,'confusionCount',d.confusion_count,
    'lastAttempt',d.last_attempt,'reviewClockAtSelection',d.next_review,
    'reviewClockUsedForAdmission',false,'reviewClockUsedForScore',false
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
  v_before integer:=0;
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

  foreach v_reason in array array['Controlled New','Targeted Performance','Learning Risk','Mixed Performance'] loop
    exit when v_count>=v_target;
    v_quota:=case v_reason
      when 'Controlled New' then greatest(1,round(v_target*.125)::int)
      when 'Targeted Performance' then greatest(1,round(v_target*.167)::int)
      when 'Learning Risk' then greatest(1,round(v_target*.292)::int)
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
               case reason when 'Targeted Performance' then 1 when 'Learning Risk' then 2 when 'Mixed Performance' then 3 else 4 end,
               category,score desc,question_id
      limit (v_target-v_count)
    )
    insert into english.daily_current(
      user_id,question_id,sequence,priority,reason,quiz_date,status,topic,concept_id,selection_signals,selection_snapshot
    )
    select p_user_id,p.question_id,
           v_sequence+row_number() over(order by p.category_rank,
             case p.reason when 'Targeted Performance' then 1 when 'Learning Risk' then 2 when 'Mixed Performance' then 3 else 4 end,
             p.category,p.score desc,p.question_id)::int,
           p.score,p.reason,p_batch_date,'New',q.topic,p.concept_id,p.signals,p.snapshot
    from pick p join english.questions q on q.question_id=p.question_id
    order by p.category_rank,
             case p.reason when 'Targeted Performance' then 1 when 'Learning Risk' then 2 when 'Mixed Performance' then 3 else 4 end,
             p.category,p.score desc,p.question_id;

    get diagnostics v_inserted=row_count;
    v_count:=v_count+v_inserted;
  end if;

  return v_count;
end;
$function$;

revoke all on function english.create_daily_performance_v2(uuid,date,integer) from public,anon,authenticated;

create or replace function english.daily_effective_counts(p_user_id uuid,p_batch_date date,p_target integer default 120)
returns table(total integer,completed integer,satisfied_elsewhere integer,remaining integer,raw_planned integer)
language sql
stable
security definer
set search_path='pg_catalog','english','auth'
as $function$
with sat as materialized (
  select concept_key from english.daily_satisfied_concepts(p_user_id,p_batch_date)
), base as (
  select d.question_id,d.sequence,d.status,
         lower(coalesce(d.status,''))='completed' is_completed,
         case
           when d.selection_snapshot->>'buildVersion'='performance-v2' then
             case when coalesce(s.mastered,false) then '' else coalesce(nullif(d.reason,''),'Mixed Performance') end
           else english.daily_reason(p_user_id,d.question_id,d.quiz_date)
         end reason_now,
         case when lower(coalesce(d.status,''))='completed' then false else sc.concept_key is not null end satisfied
  from english.daily_current d
  left join english.question_state s on s.user_id=p_user_id and s.question_id=d.question_id
  left join english.question_concept_mappings m on m.question_id=d.question_id
  left join sat sc on sc.concept_key=coalesce(m.concept_id,d.question_id)
  where d.user_id=p_user_id and d.quiz_date=p_batch_date
), planned as (
  select b.*,row_number() over(order by case when b.is_completed then 0 else 1 end,b.sequence,b.question_id) slot_rank
  from base b
  where b.is_completed or b.reason_now<>'' or b.satisfied
), effective as (
  select * from planned where slot_rank<=greatest(1,least(120,coalesce(p_target,120)))
)
select count(*)::int,
       count(*) filter(where is_completed)::int,
       count(*) filter(where not is_completed and satisfied)::int,
       count(*) filter(where not is_completed and not satisfied and reason_now<>'')::int,
       (select count(*)::int from planned)
from effective;
$function$;

create or replace function english.create_daily(p_user_id uuid,p_batch_date date,p_target integer)
returns integer
language plpgsql
security definer
set search_path='pg_catalog','english','auth'
as $function$
declare
  n integer;
  v_has_rows boolean:=false;
  v_is_v2 boolean:=false;
begin
  select exists(
    select 1 from english.daily_current where user_id=p_user_id and quiz_date=p_batch_date
  ),exists(
    select 1 from english.daily_current
    where user_id=p_user_id and quiz_date=p_batch_date
      and selection_snapshot->>'buildVersion'='performance-v2'
  ) into v_has_rows,v_is_v2;

  if v_has_rows and not v_is_v2 then
    n:=english.create_daily_core_20260905(p_user_id,p_batch_date,p_target);
    perform english.rebalance_daily_targeted(p_user_id,p_batch_date,p_target);
    perform english.rebalance_daily_category_diversity(p_user_id,p_batch_date,p_target);
  else
    n:=english.create_daily_performance_v2(p_user_id,p_batch_date,p_target);
  end if;

  select total into n from english.daily_effective_counts(p_user_id,p_batch_date,p_target);
  return coalesce(n,0);
end;
$function$;

create or replace function english.repair_daily_shortfall(p_user_id uuid,p_batch_date date,p_target integer default 120)
returns integer
language plpgsql
security definer
set search_path='pg_catalog','english','auth'
as $function$
declare
  v_target integer:=greatest(1,least(120,coalesce(p_target,120)));
  v_before integer:=0;
  v_after integer:=0;
  v_is_v2 boolean:=false;
begin
  perform pg_advisory_xact_lock(hashtextextended('english.daily.'||p_user_id::text,0));

  select total into v_before from english.daily_effective_counts(p_user_id,p_batch_date,v_target);
  v_before:=coalesce(v_before,0);

  select exists(
    select 1 from english.daily_current
    where user_id=p_user_id and quiz_date=p_batch_date
      and selection_snapshot->>'buildVersion'='performance-v2'
  ) into v_is_v2;

  if v_is_v2 then
    delete from english.daily_current d
    where d.user_id=p_user_id and d.quiz_date=p_batch_date
      and lower(coalesce(d.status,''))<>'completed'
      and coalesce((select s.mastered from english.question_state s where s.user_id=p_user_id and s.question_id=d.question_id),false)
      and not english.daily_satisfied_elsewhere(p_user_id,d.question_id,p_batch_date)
      and not exists(
        select 1 from english.attempts a
        where a.user_id=p_user_id and a.question_id=d.question_id
          and (a.attempted_at at time zone 'Asia/Kolkata')::date>=p_batch_date
      );
    perform english.create_daily_performance_v2(p_user_id,p_batch_date,v_target);
  else
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
  end if;

  update english.daily_current set sequence=sequence+1000
  where user_id=p_user_id and quiz_date=p_batch_date;

  with ranked as (
    select question_id,row_number() over(order by sequence,question_id)::int seq
    from english.daily_current
    where user_id=p_user_id and quiz_date=p_batch_date
  )
  update english.daily_current d set sequence=r.seq
  from ranked r
  where d.user_id=p_user_id and d.quiz_date=p_batch_date and d.question_id=r.question_id;

  select total into v_after from english.daily_effective_counts(p_user_id,p_batch_date,v_target);
  return greatest(0,coalesce(v_after,0)-v_before);
end;
$function$;
