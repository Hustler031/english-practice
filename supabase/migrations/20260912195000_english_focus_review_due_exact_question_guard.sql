-- Refine the Review Due / Daily Focus boundary.
-- Review Due may cover many concepts on the same day, so concept-level exclusion can starve
-- the exact 15 Grammar / 15 Phrasal Focus contract. The real duplicate to forbid is the
-- same question being served again after it was already attempted in Review Due Today.
-- A different canonical variant of the same concept remains eligible for CI transfer testing.

create or replace function english.focus_conflicts_with_required_daily(
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
with candidate as (
  select english.focus_concept_key(p_question_id) as concept_key
)
select
  exists(
    select 1
    from english.daily_current d
    cross join candidate c
    where d.user_id=p_user_id
      and d.quiz_date=p_batch_date
      and (
        d.question_id=p_question_id
        or english.focus_concept_key(d.question_id)=c.concept_key
      )
  )
  or exists(
    select 1
    from english.grammar_daily_items g
    where g.batch_date=p_batch_date
      and g.question_id=p_question_id
  )
  or exists(
    select 1
    from english.phrasal_daily_items p
    where p.batch_date=p_batch_date
      and p.question_id=p_question_id
  )
  or exists(
    select 1
    from english.daily_confusion_items dc
    cross join candidate c
    where dc.batch_date=p_batch_date
      and dc.active
      and (
        dc.question_id=p_question_id
        or english.focus_concept_key(dc.question_id)=c.concept_key
      )
  )
  or exists(
    select 1
    from english.attempts a
    where a.user_id=p_user_id
      and lower(coalesce(a.module,''))='reviewduetoday'
      and (a.attempted_at at time zone 'Asia/Kolkata')::date=p_batch_date
      and a.question_id=p_question_id
  );
$function$;

revoke all on function english.focus_conflicts_with_required_daily(uuid,text,date) from public,anon,authenticated;

-- Never rewrite completed evidence. Remove only still-pending exact-question collisions,
-- then let the existing CI selector refill any missing Grammar/Phrasal slots.
do $repair$
declare r record;
begin
  delete from english.daily_focus_items f
  where f.lane in ('grammar','phrasal')
    and f.status='New'
    and exists(
      select 1
      from english.daily_focus_batches b
      where b.user_id=f.user_id
        and b.batch_date=f.batch_date
        and b.status='active'
    )
    and exists(
      select 1
      from english.attempts a
      where a.user_id=f.user_id
        and lower(coalesce(a.module,''))='reviewduetoday'
        and (a.attempted_at at time zone 'Asia/Kolkata')::date=f.batch_date
        and a.question_id=f.question_id
    );

  for r in
    select user_id,batch_date
    from english.daily_focus_batches
    where status='active'
  loop
    perform english.ensure_daily_focus_language_lanes(r.user_id,r.batch_date);
  end loop;
end;
$repair$;
