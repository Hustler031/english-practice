-- Strict global invariant: learner-facing explanations are order-neutral.
-- Options are shuffled at runtime, so explanations must name actual option text,
-- never mutable positions such as A/B/C/D, 1/2/3/4, or first/second option.

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
  v text:=replace(coalesce(p_text,''),chr(92)||'1','');
  qa text:='“'||coalesce(nullif(btrim(p_a),''),'this answer')||'”';
  qb text:='“'||coalesce(nullif(btrim(p_b),''),'this answer')||'”';
  qc text:='“'||coalesce(nullif(btrim(p_c),''),'this answer')||'”';
  qd text:='“'||coalesce(nullif(btrim(p_d),''),'this answer')||'”';
  ra text:=replace(qa,E'\\',E'\\\\');
  rb text:=replace(qb,E'\\',E'\\\\');
  rc text:=replace(qc,E'\\',E'\\\\');
  rd text:=replace(qd,E'\\',E'\\\\');
  label_word text:='(Option|option|OPTION|Choice|choice|CHOICE|Answer|answer|ANSWER|Alternative|alternative|ALTERNATIVE)';
begin
  if v='' then return v; end if;

  -- Explicit positions: Option A, Answer 2, Choice (C), etc.
  v:=regexp_replace(v,'(^|[^[:alnum:]_])'||label_word||'[[:space:]*#:_=-]*(no[.]?[[:space:]]*)?[\(\[]?(A|1)[\)\]]?([^[:alnum:]_]|$)',E'\\1'||ra||E'\\5','g');
  v:=regexp_replace(v,'(^|[^[:alnum:]_])'||label_word||'[[:space:]*#:_=-]*(no[.]?[[:space:]]*)?[\(\[]?(B|2)[\)\]]?([^[:alnum:]_]|$)',E'\\1'||rb||E'\\5','g');
  v:=regexp_replace(v,'(^|[^[:alnum:]_])'||label_word||'[[:space:]*#:_=-]*(no[.]?[[:space:]]*)?[\(\[]?(C|3)[\)\]]?([^[:alnum:]_]|$)',E'\\1'||rc||E'\\5','g');
  v:=regexp_replace(v,'(^|[^[:alnum:]_])'||label_word||'[[:space:]*#:_=-]*(no[.]?[[:space:]]*)?[\(\[]?(D|4)[\)\]]?([^[:alnum:]_]|$)',E'\\1'||rd||E'\\5','g');

  -- Ordinal option references.
  v:=regexp_replace(v,'(^|[^[:alnum:]_])(the[[:space:]]+)?first[[:space:]-]+(option|choice|answer|alternative)([^[:alnum:]_]|$)',E'\\1'||ra||E'\\4','gi');
  v:=regexp_replace(v,'(^|[^[:alnum:]_])(the[[:space:]]+)?second[[:space:]-]+(option|choice|answer|alternative)([^[:alnum:]_]|$)',E'\\1'||rb||E'\\4','gi');
  v:=regexp_replace(v,'(^|[^[:alnum:]_])(the[[:space:]]+)?third[[:space:]-]+(option|choice|answer|alternative)([^[:alnum:]_]|$)',E'\\1'||rc||E'\\4','gi');
  v:=regexp_replace(v,'(^|[^[:alnum:]_])(the[[:space:]]+)?fourth[[:space:]-]+(option|choice|answer|alternative)([^[:alnum:]_]|$)',E'\\1'||rd||E'\\4','gi');

  -- Correct: A / Correct answer is B / Correct option - C.
  v:=regexp_replace(v,'(^|[^[:alnum:]_])([Cc][Oo][Rr][Rr][Ee][Cc][Tt])([[:space:]]+([Aa][Nn][Ss][Ww][Ee][Rr]|[Oo][Pp][Tt][Ii][Oo][Nn]|[Cc][Hh][Oo][Ii][Cc][Ee]))?[[:space:]]*(is|:|=|—|–|-)?[[:space:]]*[\(\[]?A[\)\]]?([^[:alnum:]_]|$)',E'\\1\\2: '||ra||E'\\6','g');
  v:=regexp_replace(v,'(^|[^[:alnum:]_])([Cc][Oo][Rr][Rr][Ee][Cc][Tt])([[:space:]]+([Aa][Nn][Ss][Ww][Ee][Rr]|[Oo][Pp][Tt][Ii][Oo][Nn]|[Cc][Hh][Oo][Ii][Cc][Ee]))?[[:space:]]*(is|:|=|—|–|-)?[[:space:]]*[\(\[]?B[\)\]]?([^[:alnum:]_]|$)',E'\\1\\2: '||rb||E'\\6','g');
  v:=regexp_replace(v,'(^|[^[:alnum:]_])([Cc][Oo][Rr][Rr][Ee][Cc][Tt])([[:space:]]+([Aa][Nn][Ss][Ww][Ee][Rr]|[Oo][Pp][Tt][Ii][Oo][Nn]|[Cc][Hh][Oo][Ii][Cc][Ee]))?[[:space:]]*(is|:|=|—|–|-)?[[:space:]]*[\(\[]?C[\)\]]?([^[:alnum:]_]|$)',E'\\1\\2: '||rc||E'\\6','g');
  v:=regexp_replace(v,'(^|[^[:alnum:]_])([Cc][Oo][Rr][Rr][Ee][Cc][Tt])([[:space:]]+([Aa][Nn][Ss][Ww][Ee][Rr]|[Oo][Pp][Tt][Ii][Oo][Nn]|[Cc][Hh][Oo][Ii][Cc][Ee]))?[[:space:]]*(is|:|=|—|–|-)?[[:space:]]*[\(\[]?D[\)\]]?([^[:alnum:]_]|$)',E'\\1\\2: '||rd||E'\\6','g');

  -- A:, A), A., A —, including labels after ordinary whitespace.
  v:=regexp_replace(v,'(^|[[:space:];:—–])[*_]*A[*_]*[[:space:]]*([:.)]|—|–|-|=)[[:space:]]+',E'\\1'||ra||' — ','g');
  v:=regexp_replace(v,'(^|[[:space:];:—–])[*_]*B[*_]*[[:space:]]*([:.)]|—|–|-|=)[[:space:]]+',E'\\1'||rb||' — ','g');
  v:=regexp_replace(v,'(^|[[:space:];:—–])[*_]*C[*_]*[[:space:]]*([:.)]|—|–|-|=)[[:space:]]+',E'\\1'||rc||' — ','g');
  v:=regexp_replace(v,'(^|[[:space:];:—–])[*_]*D[*_]*[[:space:]]*([:.)]|—|–|-|=)[[:space:]]+',E'\\1'||rd||' — ','g');

  -- Bracketed standalone labels.
  v:=regexp_replace(v,'(^|[[:space:];:—–])[\(\[]A[\)\]][[:space:]]+',E'\\1'||ra||' — ','g');
  v:=regexp_replace(v,'(^|[[:space:];:—–])[\(\[]B[\)\]][[:space:]]+',E'\\1'||rb||' — ','g');
  v:=regexp_replace(v,'(^|[[:space:];:—–])[\(\[]C[\)\]][[:space:]]+',E'\\1'||rc||' — ','g');
  v:=regexp_replace(v,'(^|[[:space:];:—–])[\(\[]D[\)\]][[:space:]]+',E'\\1'||rd||' — ','g');

  -- Bare positional verdicts: B is correct / C is wrong.
  v:=regexp_replace(v,'(^|[^[:alnum:]_])A[[:space:]]+is[[:space:]]+(correct|wrong|incorrect|right)([^[:alnum:]_]|$)',E'\\1'||ra||E' is \\2\\3','gi');
  v:=regexp_replace(v,'(^|[^[:alnum:]_])B[[:space:]]+is[[:space:]]+(correct|wrong|incorrect|right)([^[:alnum:]_]|$)',E'\\1'||rb||E' is \\2\\3','gi');
  v:=regexp_replace(v,'(^|[^[:alnum:]_])C[[:space:]]+is[[:space:]]+(correct|wrong|incorrect|right)([^[:alnum:]_]|$)',E'\\1'||rc||E' is \\2\\3','gi');
  v:=regexp_replace(v,'(^|[^[:alnum:]_])D[[:space:]]+is[[:space:]]+(correct|wrong|incorrect|right)([^[:alnum:]_]|$)',E'\\1'||rd||E' is \\2\\3','gi');

  -- Legacy “A <exact option text>” style.
  if nullif(btrim(p_a),'') is not null then v:=replace(v,'A '||p_a,qa); end if;
  if nullif(btrim(p_b),'') is not null then v:=replace(v,'B '||p_b,qb); end if;
  if nullif(btrim(p_c),'') is not null then v:=replace(v,'C '||p_c,qc); end if;
  if nullif(btrim(p_d),'') is not null then v:=replace(v,'D '||p_d,qd); end if;

  -- Collapse duplicate option text introduced by legacy labelled explanations.
  if nullif(btrim(p_a),'') is not null then
    v:=replace(v,qa||': '||p_a,qa); v:=replace(v,qa||' — '||p_a,qa);
    v:=replace(v,qa||' ("'||p_a||'")',qa); v:=replace(v,qa||' (“'||p_a||'”)',qa);
  end if;
  if nullif(btrim(p_b),'') is not null then
    v:=replace(v,qb||': '||p_b,qb); v:=replace(v,qb||' — '||p_b,qb);
    v:=replace(v,qb||' ("'||p_b||'")',qb); v:=replace(v,qb||' (“'||p_b||'”)',qb);
  end if;
  if nullif(btrim(p_c),'') is not null then
    v:=replace(v,qc||': '||p_c,qc); v:=replace(v,qc||' — '||p_c,qc);
    v:=replace(v,qc||' ("'||p_c||'")',qc); v:=replace(v,qc||' (“'||p_c||'”)',qc);
  end if;
  if nullif(btrim(p_d),'') is not null then
    v:=replace(v,qd||': '||p_d,qd); v:=replace(v,qd||' — '||p_d,qd);
    v:=replace(v,qd||' ("'||p_d||'")',qd); v:=replace(v,qd||' (“'||p_d||'”)',qd);
  end if;
  return v;
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

create or replace function english.explanation_is_order_neutral(p_text text)
returns boolean
language sql
immutable
parallel safe
set search_path='pg_catalog','english'
as $function$
  select not (
    strpos(coalesce(p_text,''),chr(92)||'1')>0
    or coalesce(p_text,'') ~ '(^|[^[:alnum:]_])(Option|option|OPTION|Choice|choice|CHOICE|Answer|answer|ANSWER|Alternative|alternative|ALTERNATIVE)[[:space:]*#:_=-]*(no[.]?[[:space:]]*)?[\(\[]?([A-D]|[1-4])[\)\]]?([^[:alnum:]_]|$)'
    or coalesce(p_text,'') ~* '(^|[^[:alnum:]_])(the[[:space:]]+)?(first|second|third|fourth)[[:space:]-]+(option|choice|answer|alternative)([^[:alnum:]_]|$)'
    or coalesce(p_text,'') ~ '(^|[^[:alnum:]_])([Cc][Oo][Rr][Rr][Ee][Cc][Tt])([[:space:]]+([Aa][Nn][Ss][Ww][Ee][Rr]|[Oo][Pp][Tt][Ii][Oo][Nn]|[Cc][Hh][Oo][Ii][Cc][Ee]))?[[:space:]]*(is|:|=|—|–|-)?[[:space:]]*[\(\[]?[A-D][\)\]]?([^[:alnum:]_]|$)'
    or coalesce(p_text,'') ~ '(^|[[:space:];:—–])[*_]*[A-D][*_]*[[:space:]]*([:.)]|—|–|-|=)[[:space:]]+'
    or coalesce(p_text,'') ~ '(^|[[:space:];:—–])[\(\[][A-D][\)\]][[:space:]]+'
    or coalesce(p_text,'') ~* '(^|[^[:alnum:]_])[A-D][[:space:]]+is[[:space:]]+(correct|wrong|incorrect|right)([^[:alnum:]_]|$)'
  );
$function$;

create or replace function english.explanation_is_order_neutral(p_text text,p_a text,p_b text,p_c text,p_d text)
returns boolean
language sql
immutable
parallel safe
set search_path='pg_catalog','english'
as $function$
  select english.explanation_is_order_neutral(p_text)
    and english.explanation_order_neutralized(p_text,p_a,p_b,p_c,p_d)=coalesce(p_text,'');
$function$;

create or replace function english.explanation_is_order_neutral(p_text text,p_options jsonb)
returns boolean
language sql
immutable
parallel safe
set search_path='pg_catalog','english'
as $function$
  select english.explanation_is_order_neutral(
    p_text,
    (select e->>'text' from jsonb_array_elements(coalesce(p_options,'[]'::jsonb)) e where upper(coalesce(e->>'key',''))='A' limit 1),
    (select e->>'text' from jsonb_array_elements(coalesce(p_options,'[]'::jsonb)) e where upper(coalesce(e->>'key',''))='B' limit 1),
    (select e->>'text' from jsonb_array_elements(coalesce(p_options,'[]'::jsonb)) e where upper(coalesce(e->>'key',''))='C' limit 1),
    (select e->>'text' from jsonb_array_elements(coalesce(p_options,'[]'::jsonb)) e where upper(coalesce(e->>'key',''))='D' limit 1)
  );
$function$;

create or replace function english.normalize_question_explanation_trigger()
returns trigger
language plpgsql
set search_path='pg_catalog','english'
as $function$
begin
  new.explanation:=english.explanation_order_neutralized(new.explanation,new.option_a,new.option_b,new.option_c,new.option_d);
  if not english.explanation_is_order_neutral(new.explanation,new.option_a,new.option_b,new.option_c,new.option_d) then
    raise exception 'Explanation must name actual answer/distractor text and must never depend on mutable option positions';
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
  new.explanation:=english.explanation_order_neutralized(new.explanation,new.option_a,new.option_b,new.option_c,new.option_d);
  if not english.explanation_is_order_neutral(new.explanation,new.option_a,new.option_b,new.option_c,new.option_d) then
    raise exception 'Explanation must name actual answer/distractor text and must never depend on mutable option positions';
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
  if not english.explanation_is_order_neutral(new.explanation,new.options) then
    raise exception 'Explanation must name actual answer/distractor text and must never depend on mutable option positions';
  end if;
  return new;
end;
$function$;

-- One-time legacy cleanup. Keep semantic/AI queue ownership untouched.
alter table english.questions disable trigger english_questions_order_neutral_explanation;
alter table english.questions disable trigger english_question_semantic_queue;
update english.questions
set explanation=english.explanation_order_neutralized(explanation,option_a,option_b,option_c,option_d)
where explanation is distinct from english.explanation_order_neutralized(explanation,option_a,option_b,option_c,option_d);
alter table english.questions enable trigger english_question_semantic_queue;
alter table english.questions enable trigger english_questions_order_neutral_explanation;

alter table english.saved_items disable trigger english_saved_order_neutral_explanation;
update english.saved_items
set explanation=english.explanation_order_neutralized(explanation,option_a,option_b,option_c,option_d)
where explanation is distinct from english.explanation_order_neutralized(explanation,option_a,option_b,option_c,option_d);
alter table english.saved_items enable trigger english_saved_order_neutral_explanation;

alter table english.sprint_items disable trigger english_sprint_order_neutral_explanation;
update english.sprint_items
set explanation=english.explanation_order_neutralized(explanation,options)
where explanation is distinct from english.explanation_order_neutralized(explanation,options);
alter table english.sprint_items enable trigger english_sprint_order_neutral_explanation;

alter table english.editorial_tone_items disable trigger english_editorial_order_neutral_explanation;
update english.editorial_tone_items
set explanation=english.explanation_order_neutralized(explanation,options)
where explanation is distinct from english.explanation_order_neutralized(explanation,options);
alter table english.editorial_tone_items enable trigger english_editorial_order_neutral_explanation;

do $contract$
begin
  if exists(select 1 from english.questions where explanation is not null and not english.explanation_is_order_neutral(explanation,option_a,option_b,option_c,option_d))
     or exists(select 1 from english.saved_items where explanation is not null and not english.explanation_is_order_neutral(explanation,option_a,option_b,option_c,option_d))
     or exists(select 1 from english.sprint_items where explanation is not null and not english.explanation_is_order_neutral(explanation,options))
     or exists(select 1 from english.editorial_tone_items where explanation is not null and not english.explanation_is_order_neutral(explanation,options)) then
    raise exception 'Strict order-neutral explanation contract did not fully converge';
  end if;
end;
$contract$;

-- Diagnostic helpers are no longer needed once the production contract is live.
drop function if exists english.explanation_is_order_neutral_v2_candidate(text);
drop function if exists english.explanation_is_order_neutral_v3_candidate(text,text,text,text,text);
drop function if exists english.explanation_is_order_neutral_v4_candidate(text,text,text,text,text);
drop function if exists english.explanation_is_order_neutral_v5_candidate(text,text,text,text,text);
drop function if exists english.explanation_order_neutralized_v2_candidate(text,text,text,text,text);
drop function if exists english.explanation_order_neutralized_v3_candidate(text,text,text,text,text);
drop function if exists english.explanation_order_neutralized_v4_candidate(text,text,text,text,text);
drop function if exists english.explanation_order_neutralized_v5_candidate(text,text,text,text,text);
