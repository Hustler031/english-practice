create table if not exists english.review_due_phase2_daily_mix_selections (
  user_id uuid not null,
  batch_date date not null,
  question_id text not null,
  concept_key text not null,
  reason text not null default '',
  selection_signals text[] not null default '{}'::text[],
  signals_known boolean not null default true,
  captured_at timestamptz not null default now(),
  primary key(user_id,batch_date,question_id)
);

create index if not exists review_due_phase2_mix_user_date_idx
  on english.review_due_phase2_daily_mix_selections(user_id,batch_date,concept_key);

revoke all on english.review_due_phase2_daily_mix_selections from public,anon,authenticated;

create or replace function english.capture_review_due_phase2_daily_mix(p_user_id uuid,p_batch_date date)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','english','auth'
as $function$
declare v_live integer:=0; v_hist integer:=0;
begin
  if p_user_id is null or p_batch_date is null then raise exception 'user and batch date are required'; end if;

  insert into english.review_due_phase2_daily_mix_selections(
    user_id,batch_date,question_id,concept_key,reason,selection_signals,signals_known,captured_at
  )
  select d.user_id,d.quiz_date,d.question_id,
         coalesce(nullif(d.concept_id,''),english.review_due_concept_key(d.question_id)),
         coalesce(d.reason,''),coalesce(d.selection_signals,'{}'::text[]),true,now()
  from english.daily_current d
  where d.user_id=p_user_id and d.quiz_date=p_batch_date
  on conflict(user_id,batch_date,question_id) do update
    set concept_key=excluded.concept_key,
        reason=excluded.reason,
        selection_signals=excluded.selection_signals,
        signals_known=true;
  get diagnostics v_live=row_count;

  insert into english.review_due_phase2_daily_mix_selections(
    user_id,batch_date,question_id,concept_key,reason,selection_signals,signals_known,captured_at
  )
  select h.user_id,h.quiz_date,h.question_id,
         coalesce(nullif(h.concept_id,''),english.review_due_concept_key(h.question_id)),
         coalesce(h.reason,''),'{}'::text[],false,coalesce(h.archived_at,now())
  from english.daily_history h
  where h.user_id=p_user_id and h.quiz_date=p_batch_date
  on conflict(user_id,batch_date,question_id) do nothing;
  get diagnostics v_hist=row_count;

  return jsonb_build_object('ok',true,'date',p_batch_date,'liveRows',v_live,'historyFallbackRows',v_hist);
end;
$function$;

create or replace function english.capture_review_due_phase2_daily_mix_all_users()
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','english','auth'
as $function$
declare v_day date:=(now() at time zone 'Asia/Kolkata')::date; r record; n integer:=0;
begin
  for r in
    select distinct x.user_id
    from english.review_due_day_runs x
    where x.due_date=v_day
  loop
    perform english.capture_review_due_phase2_daily_mix(r.user_id,v_day);
    n:=n+1;
  end loop;
  return jsonb_build_object('ok',true,'date',v_day,'users',n);
end;
$function$;

revoke all on function english.capture_review_due_phase2_daily_mix(uuid,date) from public,anon,authenticated;
revoke all on function english.capture_review_due_phase2_daily_mix_all_users() from public,anon,authenticated;

do $do$
declare r record;
begin
  for r in select user_id,due_date from english.review_due_day_runs loop
    perform english.capture_review_due_phase2_daily_mix(r.user_id,r.due_date);
  end loop;
end
$do$;

do $do$
begin
  if not exists(select 1 from cron.job where jobname='english-review-due-phase2-mix-ledger') then
    perform cron.schedule(
      'english-review-due-phase2-mix-ledger',
      '*/5 * * * *',
      'select english.capture_review_due_phase2_daily_mix_all_users();'
    );
  end if;
end
$do$;

create or replace function english.review_due_phase2_shadow(p_user_id uuid,p_due_date date)
returns jsonb
language sql
stable security definer
set search_path to 'pg_catalog','english','auth'
as $function$
with bounds as (
  select p_due_date due_date,
         (p_due_date::timestamp at time zone 'Asia/Kolkata') start_at,
         (((p_due_date+1)::timestamp) at time zone 'Asia/Kolkata') end_at,
         least(now(),(((p_due_date+1)::timestamp) at time zone 'Asia/Kolkata')) observation_end
), obligations as materialized (
  select o.concept_key
  from english.review_due_obligations o
  where o.user_id=p_user_id and o.due_date=p_due_date
), daily_items as materialized (
  select s.question_id,s.concept_key,s.reason,s.selection_signals signals,s.signals_known,
         (
           select min(a.attempted_at)
           from english.attempts a,bounds b
           where a.user_id=p_user_id
             and lower(btrim(coalesce(a.module,'')))='daily'
             and a.attempted_at>=b.start_at and a.attempted_at<b.end_at
             and coalesce(nullif(a.concept_id,''),english.review_due_concept_key(a.question_id))=s.concept_key
         ) first_daily_attempt_at
  from english.review_due_phase2_daily_mix_selections s
  join obligations o on o.concept_key=s.concept_key
  where s.user_id=p_user_id and s.batch_date=p_due_date
), external_flags as materialized (
  select d.question_id,d.concept_key,d.reason,d.signals,d.signals_known,d.first_daily_attempt_at,
         bool_or(not coalesce(a.correct,false)) filter(where a.attempt_id is not null) has_wrong_before,
         bool_or(coalesce(a.correct,false) and not coalesce(g.guessed,false) and not coalesce(qm.too_easy,false)) filter(where a.attempt_id is not null) has_strict_correct_before,
         bool_or(coalesce(a.correct,false) and (coalesce(g.guessed,false) or coalesce(qm.too_easy,false))) filter(where a.attempt_id is not null) has_low_confidence_correct_before
  from daily_items d
  cross join bounds b
  left join english.attempts a
    on a.user_id=p_user_id
   and a.attempted_at>=b.start_at
   and a.attempted_at<coalesce(d.first_daily_attempt_at,b.observation_end)
   and lower(btrim(coalesce(a.module,'')))<>'daily'
   and english.review_due_module_qualifies(a.module)
   and coalesce(nullif(a.concept_id,''),english.review_due_concept_key(a.question_id))=d.concept_key
  left join lateral (
    select exists(
      select 1 from english.learner_confidence_signals x
      where x.user_id=p_user_id and x.attempt_id=a.attempt_id and x.signal='guessed'
    ) guessed
  ) g on true
  left join english.question_quality_metrics qm on qm.user_id=p_user_id and qm.question_id=a.question_id
  group by d.question_id,d.concept_key,d.reason,d.signals,d.signals_known,d.first_daily_attempt_at
), daily_classified as (
  select e.*,
         case
           when coalesce(e.has_wrong_before,false) then 'repair_required'
           when coalesce(e.has_strict_correct_before,false) then 'strictly_satisfied_before_daily'
           when coalesce(e.has_low_confidence_correct_before,false) then 'low_confidence_before_daily'
           else 'no_prior_credit'
         end prior_status,
         (e.reason in ('Due Spaced Revision','Learning') and not (e.signals @> array['TARGET']::text[])) generic_review_only
  from external_flags e
), focus as materialized (
  select f.lane,f.status,f.question_id,f.concept_key,f.selected_at,
         exists(select 1 from english.attempts a where a.user_id=f.user_id and a.question_id=f.question_id and a.attempted_at>=f.selected_at) has_attempt,
         exists(select 1 from english.attempts a where a.user_id=f.user_id and a.question_id=f.question_id and a.attempted_at>=f.selected_at and a.correct is true) has_correct
  from english.daily_focus_items f
  join obligations o on o.concept_key=f.concept_key
  where f.user_id=p_user_id and f.batch_date=p_due_date
), sample as (
  select count(*)::int shadow_days from english.review_due_day_runs r where r.user_id=p_user_id and r.due_date<=p_due_date
), ledger as (
  select count(*)::int total,count(*) filter(where signals_known)::int known,count(*) filter(where not signals_known)::int unknown
  from english.review_due_phase2_daily_mix_selections s where s.user_id=p_user_id and s.batch_date=p_due_date
)
select jsonb_build_object(
  'ok',true,'date',p_due_date,'phase','phase2_shadow','routingChanged',false,'manualActivationRequired',true,
  'shadowDays',(select shadow_days from sample),
  'selectionLedger',jsonb_build_object(
    'rows',coalesce((select total from ledger),0),
    'signalsKnown',coalesce((select known from ledger),0),
    'signalsUnknown',coalesce((select unknown from ledger),0),
    'completeForActivation',coalesce((select unknown=0 and total>0 from ledger),false)
  ),
  'dailyMix',jsonb_build_object(
    'reviewDueOverlap',count(*)::int,
    'genericSuppressCandidatesKnown',count(*) filter(where prior_status='strictly_satisfied_before_daily' and generic_review_only and signals_known)::int,
    'genericSuppressCandidatesProvisional',count(*) filter(where prior_status='strictly_satisfied_before_daily' and generic_review_only and not signals_known)::int,
    'genericDuplicatesActuallyAttemptedKnown',count(*) filter(where prior_status='strictly_satisfied_before_daily' and generic_review_only and signals_known and first_daily_attempt_at is not null)::int,
    'genericPendingPreventableKnown',count(*) filter(where prior_status='strictly_satisfied_before_daily' and generic_review_only and signals_known and first_daily_attempt_at is null)::int,
    'preservedIndependentLearning',count(*) filter(where prior_status='strictly_satisfied_before_daily' and (not generic_review_only or not signals_known))::int,
    'repairRequiredBeforeDaily',count(*) filter(where prior_status='repair_required')::int,
    'lowConfidenceBeforeDaily',count(*) filter(where prior_status='low_confidence_before_daily')::int
  ),
  'dailyFocus',jsonb_build_object(
    'policy','observe_only_no_suppression',
    'reviewDueOverlap',(select count(*)::int from focus),
    'repairOverlap',(select count(*)::int from focus where lane='repair'),
    'coverageOverlap',(select count(*)::int from focus where lane='coverage'),
    'fastTrackOverlap',(select count(*)::int from focus where lane='fast_track'),
    'completedWithoutCorrectEvidence',(select count(*)::int from focus where lower(coalesce(status,''))='completed' and has_attempt and not has_correct)
  ),
  'activationGate',jsonb_build_object(
    'eligible',false,
    'reason',case when not coalesce((select unknown=0 and total>0 from ledger),false)
                  then 'selection ledger incomplete; archived fallback cannot prove TARGET signal history'
                  else 'manual gate; collect multiple full shadow days before any routing change' end,
    'scopeWhenApproved','Daily Mix generic scheduled-review suppression only; Daily Focus lanes remain independent'
  )
)
from daily_classified;
$function$;

comment on table english.review_due_phase2_daily_mix_selections is
  'Shadow-only Daily Mix selection ledger for Phase 2 evaluation. Archived fallback rows are marked signals_known=false and cannot authorize routing changes.';