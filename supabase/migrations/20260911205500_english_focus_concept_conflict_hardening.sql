-- Harden Daily Focus vs Daily Mix conflict detection at concept level.
-- Review Due remains intentionally separate and may overlap when an independent learning reason exists.
-- Grammar/Phrasal keep their existing exact-question conflict semantics.

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
  );
$function$;

revoke all on function english.focus_conflicts_with_required_daily(uuid,text,date) from public,anon,authenticated;
