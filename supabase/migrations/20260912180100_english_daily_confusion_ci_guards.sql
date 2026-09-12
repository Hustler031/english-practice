-- Daily Confusion is a first-class Central Intelligence source, but its first
-- exposure belongs to the dedicated Daily Confusion module. After the learner
-- has attempted a confusion question there, normal intelligence may revisit it.

create or replace function english.hindu_daily_eligible(p_user_id uuid,p_question_id text)
returns boolean
language sql
stable
security definer
set search_path = pg_catalog, english, auth
as $$
select case
  -- Compatibility function name retained because current Daily Mix callers use it.
  -- Daily Confusion must receive its first exposure in the dedicated module.
  when exists(
    select 1
    from english.questions q
    where q.question_id=p_question_id
      and (
        lower(coalesce(q.topic,''))='daily confusion'
        or upper(coalesce(q.source_id,'')) like 'CONFUSION_%'
      )
  ) then exists(
    select 1
    from english.attempts a
    where a.user_id=p_user_id
      and a.question_id=p_question_id
      and lower(coalesce(a.module,''))='confusion'
  )
  -- Preserve the retired Hindu exposure-only behavior for historical content.
  when not exists(
    select 1
    from english.questions q
    where q.question_id=p_question_id
      and (
        lower(coalesce(q.topic,''))='the hindu vocabulary'
        or upper(coalesce(q.source_id,'')) like 'HINDU_%'
      )
  ) then true
  else exists(
    select 1
    from english.hindu_vocab_registry r
    where r.user_id=p_user_id
      and r.question_id=p_question_id
      and r.active
      and (coalesce(r.marked,false) or coalesce(r.in_vocab,false))
  )
end;
$$;

create or replace function english.focus_conflicts_with_required_daily(
  p_user_id uuid,
  p_question_id text,
  p_batch_date date
)
returns boolean
language sql
stable
security definer
set search_path = pg_catalog, english, auth
as $$
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
  );
$$;
