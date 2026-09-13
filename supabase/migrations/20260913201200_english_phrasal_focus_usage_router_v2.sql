-- Daily Focus Phrasal 15 becomes CI-owned remediation with a soft
-- 2 recognition / 7 usage-recall / 6 confusion surface balance.
-- Existing materialized Focus batches remain frozen.

create or replace function english.fill_daily_focus_phrasal_v2(p_user_id uuid,p_batch_date date)
returns integer
language plpgsql security definer
set search_path to 'pg_catalog','english','auth','public'
as $function$
declare v_existing integer:=0; v_inserted integer:=0; v_next_ord integer:=0; v_rows integer:=0;
begin
  if p_user_id is null or p_batch_date is null then raise exception 'user and batch date are required'; end if;
  select count(*) into v_existing from english.daily_focus_items
  where user_id=p_user_id and batch_date=p_batch_date and lane='phrasal';
  if v_existing>0 then return v_existing; end if;

  create temporary table if not exists pg_temp.phrasal_focus_candidates(
    concept_id text,word text,desired_family text,bucket text,ci_reason text,priority_bucket integer,tier integer,
    state text,due boolean,next_review timestamptz,never_revised boolean,days_since_revision integer,
    recognition_weak boolean,usage_weak boolean,recall_weak boolean,confusion_weak boolean,starred boolean,difficult boolean
  ) on commit drop;
  truncate pg_temp.phrasal_focus_candidates;

  insert into pg_temp.phrasal_focus_candidates
  select c.concept_id,c.word,
    case when c.state='Persistent Weak' or c.recognition_weak then 'recognition'
         when c.usage_weak then 'context_fill' when c.confusion_weak then 'confusion' when c.recall_weak then 'recall'
         when c.recognition_strong and c.usage_attempts=0 then 'context_fill'
         when c.recognition_strong and c.recall_attempts=0 then 'recall'
         when c.recognition_strong and c.usage_strong and c.confusion_attempts=0 then 'confusion'
         when c.due then 'context_fill' else 'context_fill' end desired_family,
    case when c.state='Persistent Weak' or c.recognition_weak then 'recognition'
         when c.confusion_weak or (c.recognition_strong and c.usage_strong and c.confusion_attempts=0) then 'confusion'
         else 'usage_recall' end bucket,
    case when c.state='Persistent Weak' then 'Persistent Weak · rebuild recognition'
         when c.recognition_weak then 'Recognition Weak' when c.usage_weak then 'Contextual Usage Weak'
         when c.confusion_weak then 'Confusion Weak' when c.recall_weak then 'Active Recall Weak'
         when c.recognition_strong and c.usage_attempts=0 then 'Meaning Known · Usage Unproven'
         when c.recognition_strong and c.recall_attempts=0 then 'Meaning Known · Recall Unproven'
         when c.recognition_strong and c.usage_strong and c.confusion_attempts=0 then 'Usage Known · Contrast Unproven'
         when c.due then 'Due Transfer Practice' when c.state='New' or c.never_revised then 'New / Never Revised'
         else 'Adaptive Usage Rotation' end ci_reason,
    case when c.state='Persistent Weak' then 1
         when c.recognition_weak or c.usage_weak or c.confusion_weak or c.recall_weak or c.state='Weak' then 2
         when c.state='Fragile' then 3 when c.due then 4 when c.never_revised or c.state='New' then 5
         when c.difficult then 6 when c.starred then 7 else 8 end priority_bucket,
    c.tier,c.state,c.due,c.next_review,c.never_revised,c.days_since_revision,
    c.recognition_weak,c.usage_weak,c.recall_weak,c.confusion_weak,c.starred,c.difficult
  from english.phrasal_concepts_v2(p_user_id) c
  where not c.proven_mastery and c.active_variant_count>0
    and not exists(select 1 from english.daily_focus_items f
      where f.user_id=p_user_id and f.batch_date=p_batch_date and f.concept_key=c.concept_id);

  create temporary table if not exists pg_temp.phrasal_focus_plan(
    ord integer primary key,concept_id text unique not null,desired_family text not null,bucket text not null,
    ci_reason text not null,priority_bucket integer not null
  ) on commit drop;
  truncate pg_temp.phrasal_focus_plan;

  insert into pg_temp.phrasal_focus_plan
  select row_number() over(order by c.priority_bucket,c.tier desc,c.due desc,c.days_since_revision desc nulls last,c.concept_id)::int,
         c.concept_id,c.desired_family,c.bucket,c.ci_reason,c.priority_bucket
  from pg_temp.phrasal_focus_candidates c
  where c.bucket='recognition' and exists(
    select 1 from english.questions q left join english.question_state s on s.user_id=p_user_id and s.question_id=q.question_id
    where q.active and english.question_visible_to_user(p_user_id,q.question_id)
      and coalesce(nullif(btrim(q.concept_id),''),'PVQ_'||q.question_id)=c.concept_id and not coalesce(s.mastered,false)
      and english.phrasal_effective_family(q)=c.desired_family
      and not english.focus_conflicts_with_required_daily(p_user_id,q.question_id,p_batch_date))
  order by c.priority_bucket,c.tier desc,c.due desc,c.days_since_revision desc nulls last,c.concept_id limit 2;

  select coalesce(max(ord),0) into v_next_ord from pg_temp.phrasal_focus_plan;
  insert into pg_temp.phrasal_focus_plan
  select v_next_ord+row_number() over(order by c.priority_bucket,c.tier desc,c.due desc,c.days_since_revision desc nulls last,c.concept_id)::int,
         c.concept_id,c.desired_family,'usage_recall',c.ci_reason,c.priority_bucket
  from pg_temp.phrasal_focus_candidates c
  where c.bucket='usage_recall' and not exists(select 1 from pg_temp.phrasal_focus_plan p where p.concept_id=c.concept_id)
    and exists(
      select 1 from english.questions q left join english.question_state s on s.user_id=p_user_id and s.question_id=q.question_id
      where q.active and english.question_visible_to_user(p_user_id,q.question_id)
        and coalesce(nullif(btrim(q.concept_id),''),'PVQ_'||q.question_id)=c.concept_id and not coalesce(s.mastered,false)
        and english.phrasal_effective_family(q)=c.desired_family
        and not english.focus_conflicts_with_required_daily(p_user_id,q.question_id,p_batch_date))
  order by c.priority_bucket,c.tier desc,c.due desc,c.days_since_revision desc nulls last,c.concept_id limit 7;

  select coalesce(max(ord),0) into v_next_ord from pg_temp.phrasal_focus_plan;
  insert into pg_temp.phrasal_focus_plan
  select v_next_ord+row_number() over(order by c.priority_bucket,c.tier desc,c.due desc,c.days_since_revision desc nulls last,c.concept_id)::int,
         c.concept_id,'confusion','confusion',c.ci_reason,c.priority_bucket
  from pg_temp.phrasal_focus_candidates c
  where c.bucket='confusion' and not exists(select 1 from pg_temp.phrasal_focus_plan p where p.concept_id=c.concept_id)
    and exists(
      select 1 from english.questions q left join english.question_state s on s.user_id=p_user_id and s.question_id=q.question_id
      where q.active and english.question_visible_to_user(p_user_id,q.question_id)
        and coalesce(nullif(btrim(q.concept_id),''),'PVQ_'||q.question_id)=c.concept_id and not coalesce(s.mastered,false)
        and english.phrasal_effective_family(q)='confusion'
        and not english.focus_conflicts_with_required_daily(p_user_id,q.question_id,p_batch_date))
  order by c.priority_bucket,c.tier desc,c.due desc,c.days_since_revision desc nulls last,c.concept_id limit 6;

  loop
    exit when (select count(*) from pg_temp.phrasal_focus_plan)>=15;
    select coalesce(max(ord),0)+1 into v_next_ord from pg_temp.phrasal_focus_plan;
    insert into pg_temp.phrasal_focus_plan(ord,concept_id,desired_family,bucket,ci_reason,priority_bucket)
    select v_next_ord,c.concept_id,ev.family,
           case when ev.family='confusion' then 'confusion' when ev.family='recognition' then 'recognition' else 'usage_recall' end,
           c.ci_reason||' · adaptive spillover',c.priority_bucket
    from pg_temp.phrasal_focus_candidates c
    cross join lateral (
      select english.phrasal_effective_family(q) family
      from english.questions q left join english.question_state s on s.user_id=p_user_id and s.question_id=q.question_id
      where q.active and english.question_visible_to_user(p_user_id,q.question_id)
        and coalesce(nullif(btrim(q.concept_id),''),'PVQ_'||q.question_id)=c.concept_id and not coalesce(s.mastered,false)
        and not english.focus_conflicts_with_required_daily(p_user_id,q.question_id,p_batch_date)
      order by case english.phrasal_effective_family(q) when c.desired_family then 0 when 'context_fill' then 1
                   when 'confusion' then 2 when 'recall' then 3 else 4 end,
               coalesce(s.attempts,0),q.question_id limit 1
    ) ev
    where not exists(select 1 from pg_temp.phrasal_focus_plan p where p.concept_id=c.concept_id)
    order by c.priority_bucket,c.tier desc,c.due desc,c.days_since_revision desc nulls last,c.concept_id limit 1
    on conflict do nothing;
    get diagnostics v_rows=row_count;
    exit when v_rows=0;
  end loop;

  with picked as (
    select p.*,q.question_id,english.phrasal_effective_family(q) served_family,coalesce(s.attempts,0)::int question_attempts,
      row_number() over(partition by p.concept_id order by
        case when english.phrasal_effective_family(q)=p.desired_family then 0 else 1 end,
        case english.phrasal_effective_family(q) when 'context_fill' then 1 when 'confusion' then 2 when 'recall' then 3 else 4 end,
        coalesce(s.attempts,0),q.question_id) variant_pick
    from pg_temp.phrasal_focus_plan p
    join english.questions q on coalesce(nullif(btrim(q.concept_id),''),'PVQ_'||q.question_id)=p.concept_id and q.active
    left join english.question_state s on s.user_id=p_user_id and s.question_id=q.question_id
    where english.question_visible_to_user(p_user_id,q.question_id) and not coalesce(s.mastered,false)
      and not english.focus_conflicts_with_required_daily(p_user_id,q.question_id,p_batch_date)
  ), numbered as (
    select p.*,coalesce((select max(sequence) from english.daily_focus_items
      where user_id=p_user_id and batch_date=p_batch_date and lane='phrasal'),0)+row_number() over(order by p.ord)::int seq
    from picked p where variant_pick=1
  )
  insert into english.daily_focus_items(user_id,batch_date,lane,sequence,question_id,concept_key,reasons,selection_snapshot)
  select p_user_id,p_batch_date,'phrasal',seq,question_id,concept_id,array['Phrasal CI',ci_reason]::text[],
    jsonb_strip_nulls(jsonb_build_object(
      'source','phrasal_intelligence','buildVersion','language_v2_usage_first','domain','phrasal',
      'conceptId',concept_id,'desiredFamily',desired_family,'questionFamily',served_family,
      'surfaceBucket',bucket,'ciReason',ci_reason,'priorityBucket',priority_bucket,'questionAttempts',question_attempts))
  from numbered order by seq limit 15 on conflict do nothing;

  get diagnostics v_inserted=row_count;
  return v_inserted;
end;
$function$;

-- Idempotent compatibility wrapper. The old implementation becomes V1 only once.
do $do$
begin
  if to_regprocedure('english.ensure_daily_focus_language_lanes_v1(uuid,date)') is null
     and to_regprocedure('english.ensure_daily_focus_language_lanes(uuid,date)') is not null then
    alter function english.ensure_daily_focus_language_lanes(uuid,date) rename to ensure_daily_focus_language_lanes_v1;
  end if;
end
$do$;

create or replace function english.ensure_daily_focus_language_lanes(p_user_id uuid,p_batch_date date)
returns jsonb
language plpgsql security definer
set search_path to 'pg_catalog','english','auth','public'
as $function$
declare v_before integer:=0; v_grammar integer:=0; v_phrasal integer:=0; v_old jsonb;
begin
  select count(*) into v_before from english.daily_focus_items
  where user_id=p_user_id and batch_date=p_batch_date and lane='phrasal';

  v_old:=english.ensure_daily_focus_language_lanes_v1(p_user_id,p_batch_date);

  if v_before=0 then
    delete from english.daily_focus_items
    where user_id=p_user_id and batch_date=p_batch_date and lane='phrasal' and status='New';
    perform english.fill_daily_focus_phrasal_v2(p_user_id,p_batch_date);
    perform english.reconcile_daily_focus(p_user_id,p_batch_date);
  end if;

  select count(*) into v_grammar from english.daily_focus_items
  where user_id=p_user_id and batch_date=p_batch_date and lane='grammar';
  select count(*) into v_phrasal from english.daily_focus_items
  where user_id=p_user_id and batch_date=p_batch_date and lane='phrasal';

  return jsonb_build_object('ok',true,'batchDate',p_batch_date,'grammar',v_grammar,'phrasal',v_phrasal,
    'languageTotal',v_grammar+v_phrasal,'exactTarget',(v_grammar=15 and v_phrasal=15),
    'phrasalVersion',case when v_before=0 then 'usage_first_v2' else 'frozen_existing' end);
end;
$function$;