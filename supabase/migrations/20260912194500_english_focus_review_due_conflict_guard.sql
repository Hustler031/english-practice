-- Prevent same-day concept duplication between Review Due Today and Daily Focus.
-- Review Due is scheduler-owned and has priority; Daily Focus must not independently select
-- the same canonical concept for the same study date.

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
    from english.review_due_obligations rd
    cross join candidate c
    where rd.user_id=p_user_id
      and rd.due_date=p_batch_date
      and rd.concept_key=c.concept_key
  );
$function$;

revoke all on function english.focus_conflicts_with_required_daily(uuid,text,date) from public,anon,authenticated;

-- Existing completed evidence is immutable. Only pending Grammar/Phrasal Focus rows that now
-- conflict with Review Due are removed and deterministically refilled through the existing
-- Central Intelligence selector.
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
      from english.review_due_obligations rd
      where rd.user_id=f.user_id
        and rd.due_date=f.batch_date
        and rd.concept_key=f.concept_key
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
