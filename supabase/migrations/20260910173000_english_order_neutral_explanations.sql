-- English explanation order-neutrality contract.
-- Options are shuffled at runtime, so learner-facing explanations must name the
-- actual answer/distractor text and must never depend on mutable option positions.

create or replace function english.explanation_is_order_neutral(p_text text)
returns boolean
language sql
immutable
parallel safe
set search_path='pg_catalog','english'
as $function$
  select not (
    coalesce(p_text,'') ~* '(^|[^[:alnum:]_])(option|choice|answer|alternative)[[:space:]*#:_-]*(no[.]?[[:space:]]*)?([A-D]|[1-4])([^[:alnum:]_]|$)'
    or coalesce(p_text,'') ~* '(^|[^[:alnum:]_])(first|second|third|fourth)[[:space:]-]+(option|choice|answer|alternative)([^[:alnum:]_]|$)'
    or coalesce(p_text,'') ~ '(^|[[:space:]—–;,])[*_]*[A-D][*_]*[[:space:]]*:'
    or coalesce(p_text,'') ~ '(^|[\n\r;—–])[[:space:]*_-]*[A-D][[:space:]]*[.)][[:space:]]+'
  );
$function$;

create or replace function english.explanation_order_neutralized(
  p_text text,
  p_a text,
  p_b text,
  p_c text,
  p_d text
)
returns text
language plpgsql
immutable
parallel safe
set search_path='pg_catalog','english'
as $function$
declare
  v text:=coalesce(p_text,'');
  ra text:=replace('“'||coalesce(nullif(btrim(p_a),''),'this answer')||'”',E'\\',E'\\\\');
  rb text:=replace('“'||coalesce(nullif(btrim(p_b),''),'this answer')||'”',E'\\',E'\\\\');
  rc text:=replace('“'||coalesce(nullif(btrim(p_c),''),'this answer')||'”',E'\\',E'\\\\');
  rd text:=replace('“'||coalesce(nullif(btrim(p_d),''),'this answer')||'”',E'\\',E'\\\\');
begin
  if v='' then return v; end if;

  -- Explicit positional references: Option A, Choice B, Answer 3, etc.
  v:=regexp_replace(v,'(^|[^[:alnum:]_])(option|choice|answer|alternative)[[:space:]*#:_-]*(no[.]?[[:space:]]*)?(A|1)([^[:alnum:]_]|$)',E'\\1'||ra||E'\\5','gi');
  v:=regexp_replace(v,'(^|[^[:alnum:]_])(option|choice|answer|alternative)[[:space:]*#:_-]*(no[.]?[[:space:]]*)?(B|2)([^[:alnum:]_]|$)',E'\\1'||rb||E'\\5','gi');
  v:=regexp_replace(v,'(^|[^[:alnum:]_])(option|choice|answer|alternative)[[:space:]*#:_-]*(no[.]?[[:space:]]*)?(C|3)([^[:alnum:]_]|$)',E'\\1'||rc||E'\\5','gi');
  v:=regexp_replace(v,'(^|[^[:alnum:]_])(option|choice|answer|alternative)[[:space:]*#:_-]*(no[.]?[[:space:]]*)?(D|4)([^[:alnum:]_]|$)',E'\\1'||rd||E'\\5','gi');

  -- Ordinal references: first option, second choice, etc.
  v:=regexp_replace(v,'(^|[^[:alnum:]_])first[[:space:]-]+(option|choice|answer|alternative)([^[:alnum:]_]|$)',E'\\1'||ra||E'\\3','gi');
  v:=regexp_replace(v,'(^|[^[:alnum:]_])second[[:space:]-]+(option|choice|answer|alternative)([^[:alnum:]_]|$)',E'\\1'||rb||E'\\3','gi');
  v:=regexp_replace(v,'(^|[^[:alnum:]_])third[[:space:]-]+(option|choice|answer|alternative)([^[:alnum:]_]|$)',E'\\1'||rc||E'\\3','gi');
  v:=regexp_replace(v,'(^|[^[:alnum:]_])fourth[[:space:]-]+(option|choice|answer|alternative)([^[:alnum:]_]|$)',E'\\1'||rd||E'\\3','gi');

  -- Common distractor labels such as “A: …” and list bullets such as “A. …”.
  v:=regexp_replace(v,'(^|[[:space:]—–;,])[*_]*A[*_]*[[:space:]]*:',E'\\1'||ra||':','g');
  v:=regexp_replace(v,'(^|[[:space:]—–;,])[*_]*B[*_]*[[:space:]]*:',E'\\1'||rb||':','g');
  v:=regexp_replace(v,'(^|[[:space:]—–;,])[*_]*C[*_]*[[:space:]]*:',E'\\1'||rc||':','g');
  v:=regexp_replace(v,'(^|[[:space:]—–;,])[*_]*D[*_]*[[:space:]]*:',E'\\1'||rd||':','g');
  v:=regexp_replace(v,'(^|[\n\r;—–])[[:space:]*_-]*A[[:space:]]*[.)][[:space:]]+',E'\\1'||ra||' — ','g');
  v:=regexp_replace(v,'(^|[\n\r;—–])[[:space:]*_-]*B[[:space:]]*[.)][[:space:]]+',E'\\1'||rb||' — ','g');
  v:=regexp_replace(v,'(^|[\n\r;—–])[[:space:]*_-]*C[[:space:]]*[.)][[:space:]]+',E'\\1'||rc||' — ','g');
  v:=regexp_replace(v,'(^|[\n\r;—–])[[:space:]*_-]*D[[:space:]]*[.)][[:space:]]+',E'\\1'||rd||' — ','g');

  return regexp_replace(v,'[[:space:]]+([,;:.])','\\1','g');
end;
$function$;

create or replace function english.explanation_order_neutralized(p_text text,p_options jsonb)
returns text
language sql
immutable
parallel safe
set search_path='pg_catalog','english'
as $function$
  select english.explanation_order_neutralized(
    p_text,
    (select e->>'text' from jsonb_array_elements(coalesce(p_options,'[]'::jsonb)) e where upper(coalesce(e->>'key',''))='A' limit 1),
    (select e->>'text' from jsonb_array_elements(coalesce(p_options,'[]'::jsonb)) e where upper(coalesce(e->>'key',''))='B' limit 1),
    (select e->>'text' from jsonb_array_elements(coalesce(p_options,'[]'::jsonb)) e where upper(coalesce(e->>'key',''))='C' limit 1),
    (select e->>'text' from jsonb_array_elements(coalesce(p_options,'[]'::jsonb)) e where upper(coalesce(e->>'key',''))='D' limit 1)
  );
$function$;

-- Normalize legacy explanations once without creating a semantic-revision storm.
alter table english.questions disable trigger english_question_semantic_queue;
update english.questions
set explanation=english.explanation_order_neutralized(explanation,option_a,option_b,option_c,option_d)
where not english.explanation_is_order_neutral(explanation);
alter table english.questions enable trigger english_question_semantic_queue;

update english.saved_items
set explanation=english.explanation_order_neutralized(explanation,option_a,option_b,option_c,option_d)
where not english.explanation_is_order_neutral(explanation);

update english.sprint_items
set explanation=english.explanation_order_neutralized(explanation,options)
where not english.explanation_is_order_neutral(explanation);

update english.editorial_tone_items
set explanation=english.explanation_order_neutralized(explanation,options)
where not english.explanation_is_order_neutral(explanation);

-- Storage-boundary enforcement: normalize supported legacy generator wording, then
-- reject anything that still depends on an answer position. This protects every
-- caller, including Grammar, Phrasal, Saved enrichment, Sprint and manual writes.
create or replace function english.normalize_question_explanation_trigger()
returns trigger
language plpgsql
set search_path='pg_catalog','english'
as $function$
begin
  new.explanation:=english.explanation_order_neutralized(
    new.explanation,new.option_a,new.option_b,new.option_c,new.option_d
  );
  if not english.explanation_is_order_neutral(new.explanation) then
    raise exception 'Explanation must name the answer/distractor text, not a mutable option position';
  end if;
  return new;
end;
$function$;

create or replace function english.normalize_saved_explanation_trigger()
returns trigger
language plpgsql
set search_path='pg_catalog','english'
as $function$
begin
  new.explanation:=english.explanation_order_neutralized(
    new.explanation,new.option_a,new.option_b,new.option_c,new.option_d
  );
  if not english.explanation_is_order_neutral(new.explanation) then
    raise exception 'Explanation must name the answer/distractor text, not a mutable option position';
  end if;
  return new;
end;
$function$;

create or replace function english.normalize_json_options_explanation_trigger()
returns trigger
language plpgsql
set search_path='pg_catalog','english'
as $function$
begin
  new.explanation:=english.explanation_order_neutralized(new.explanation,new.options);
  if not english.explanation_is_order_neutral(new.explanation) then
    raise exception 'Explanation must name the answer/distractor text, not a mutable option position';
  end if;
  return new;
end;
$function$;

drop trigger if exists english_questions_order_neutral_explanation on english.questions;
create trigger english_questions_order_neutral_explanation
before insert or update of explanation on english.questions
for each row execute function english.normalize_question_explanation_trigger();

drop trigger if exists english_saved_order_neutral_explanation on english.saved_items;
create trigger english_saved_order_neutral_explanation
before insert or update of explanation on english.saved_items
for each row execute function english.normalize_saved_explanation_trigger();

drop trigger if exists english_sprint_order_neutral_explanation on english.sprint_items;
create trigger english_sprint_order_neutral_explanation
before insert or update of explanation on english.sprint_items
for each row execute function english.normalize_json_options_explanation_trigger();

drop trigger if exists english_editorial_order_neutral_explanation on english.editorial_tone_items;
create trigger english_editorial_order_neutral_explanation
before insert or update of explanation on english.editorial_tone_items
for each row execute function english.normalize_json_options_explanation_trigger();

revoke all on function english.normalize_question_explanation_trigger() from public,anon,authenticated;
revoke all on function english.normalize_saved_explanation_trigger() from public,anon,authenticated;
revoke all on function english.normalize_json_options_explanation_trigger() from public,anon,authenticated;

-- Migration-time contract: no existing explanation may leave this migration with
-- a mutable option-position reference.
do $contract$
begin
  if exists(select 1 from english.questions where not english.explanation_is_order_neutral(explanation))
     or exists(select 1 from english.saved_items where not english.explanation_is_order_neutral(explanation))
     or exists(select 1 from english.sprint_items where not english.explanation_is_order_neutral(explanation))
     or exists(select 1 from english.editorial_tone_items where not english.explanation_is_order_neutral(explanation)) then
    raise exception 'Order-neutral explanation backfill did not fully converge';
  end if;
end;
$contract$;