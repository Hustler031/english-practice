-- Follow-up hardening for the global order-neutral explanation contract.
-- 1) remove a literal backreference artifact found by post-migration verification;
-- 2) cover legacy distractor labels written as "A — ...";
-- 3) collapse common duplicate option-text echoes after normalization.

create or replace function english.explanation_is_order_neutral(p_text text)
returns boolean
language sql
immutable
parallel safe
set search_path='pg_catalog','english'
as $function$
  select not (
    coalesce(p_text,'') like '%'||E'\\1'||'%'
    or coalesce(p_text,'') ~* '(^|[^[:alnum:]_])(option|choice|answer|alternative)[[:space:]*#:_-]*(no[.]?[[:space:]]*)?([A-D]|[1-4])([^[:alnum:]_]|$)'
    or coalesce(p_text,'') ~* '(^|[^[:alnum:]_])(the[[:space:]]+)?(first|second|third|fourth)[[:space:]-]+(option|choice|answer|alternative)([^[:alnum:]_]|$)'
    or coalesce(p_text,'') ~ '(^|[[:space:]—–;,])[*_]*[A-D][*_]*[[:space:]]*:'
    or coalesce(p_text,'') ~ '(^|[\n\r;—–])[[:space:]*_-]*[A-D][[:space:]]*[.)][[:space:]]+'
    or coalesce(p_text,'') ~ '(^|[;:])[[:space:]*_-]*[A-D][[:space:]]*(—|–|-)[[:space:]]*'
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
  v text:=replace(coalesce(p_text,''),E'\\1','');
  qa text:='“'||coalesce(nullif(btrim(p_a),''),'this answer')||'”';
  qb text:='“'||coalesce(nullif(btrim(p_b),''),'this answer')||'”';
  qc text:='“'||coalesce(nullif(btrim(p_c),''),'this answer')||'”';
  qd text:='“'||coalesce(nullif(btrim(p_d),''),'this answer')||'”';
  ra text:=replace(qa,E'\\',E'\\\\');
  rb text:=replace(qb,E'\\',E'\\\\');
  rc text:=replace(qc,E'\\',E'\\\\');
  rd text:=replace(qd,E'\\',E'\\\\');
begin
  if v='' then return v; end if;

  v:=regexp_replace(v,'(^|[^[:alnum:]_])(option|choice|answer|alternative)[[:space:]*#:_-]*(no[.]?[[:space:]]*)?(A|1)([^[:alnum:]_]|$)',E'\\1'||ra||E'\\5','gi');
  v:=regexp_replace(v,'(^|[^[:alnum:]_])(option|choice|answer|alternative)[[:space:]*#:_-]*(no[.]?[[:space:]]*)?(B|2)([^[:alnum:]_]|$)',E'\\1'||rb||E'\\5','gi');
  v:=regexp_replace(v,'(^|[^[:alnum:]_])(option|choice|answer|alternative)[[:space:]*#:_-]*(no[.]?[[:space:]]*)?(C|3)([^[:alnum:]_]|$)',E'\\1'||rc||E'\\5','gi');
  v:=regexp_replace(v,'(^|[^[:alnum:]_])(option|choice|answer|alternative)[[:space:]*#:_-]*(no[.]?[[:space:]]*)?(D|4)([^[:alnum:]_]|$)',E'\\1'||rd||E'\\5','gi');

  v:=regexp_replace(v,'(^|[^[:alnum:]_])(the[[:space:]]+)?first[[:space:]-]+(option|choice|answer|alternative)([^[:alnum:]_]|$)',E'\\1'||ra||E'\\4','gi');
  v:=regexp_replace(v,'(^|[^[:alnum:]_])(the[[:space:]]+)?second[[:space:]-]+(option|choice|answer|alternative)([^[:alnum:]_]|$)',E'\\1'||rb||E'\\4','gi');
  v:=regexp_replace(v,'(^|[^[:alnum:]_])(the[[:space:]]+)?third[[:space:]-]+(option|choice|answer|alternative)([^[:alnum:]_]|$)',E'\\1'||rc||E'\\4','gi');
  v:=regexp_replace(v,'(^|[^[:alnum:]_])(the[[:space:]]+)?fourth[[:space:]-]+(option|choice|answer|alternative)([^[:alnum:]_]|$)',E'\\1'||rd||E'\\4','gi');

  v:=regexp_replace(v,'(^|[[:space:]—–;,])[*_]*A[*_]*[[:space:]]*:',E'\\1'||ra||':','g');
  v:=regexp_replace(v,'(^|[[:space:]—–;,])[*_]*B[*_]*[[:space:]]*:',E'\\1'||rb||':','g');
  v:=regexp_replace(v,'(^|[[:space:]—–;,])[*_]*C[*_]*[[:space:]]*:',E'\\1'||rc||':','g');
  v:=regexp_replace(v,'(^|[[:space:]—–;,])[*_]*D[*_]*[[:space:]]*:',E'\\1'||rd||':','g');
  v:=regexp_replace(v,'(^|[\n\r;—–])[[:space:]*_-]*A[[:space:]]*[.)][[:space:]]+',E'\\1'||ra||' — ','g');
  v:=regexp_replace(v,'(^|[\n\r;—–])[[:space:]*_-]*B[[:space:]]*[.)][[:space:]]+',E'\\1'||rb||' — ','g');
  v:=regexp_replace(v,'(^|[\n\r;—–])[[:space:]*_-]*C[[:space:]]*[.)][[:space:]]+',E'\\1'||rc||' — ','g');
  v:=regexp_replace(v,'(^|[\n\r;—–])[[:space:]*_-]*D[[:space:]]*[.)][[:space:]]+',E'\\1'||rd||' — ','g');
  v:=regexp_replace(v,'(^|[;:])[[:space:]*_-]*A[[:space:]]*(—|–|-)[[:space:]]*',E'\\1 '||ra||' — ','g');
  v:=regexp_replace(v,'(^|[;:])[[:space:]*_-]*B[[:space:]]*(—|–|-)[[:space:]]*',E'\\1 '||rb||' — ','g');
  v:=regexp_replace(v,'(^|[;:])[[:space:]*_-]*C[[:space:]]*(—|–|-)[[:space:]]*',E'\\1 '||rc||' — ','g');
  v:=regexp_replace(v,'(^|[;:])[[:space:]*_-]*D[[:space:]]*(—|–|-)[[:space:]]*',E'\\1 '||rd||' — ','g');

  if nullif(btrim(p_a),'') is not null then
    v:=replace(v,qa||': '||p_a,qa);
    v:=replace(v,qa||' — '||p_a,qa);
    v:=replace(v,qa||' ("'||p_a||'")',qa);
    v:=replace(v,qa||' (“'||p_a||'”)',qa);
  end if;
  if nullif(btrim(p_b),'') is not null then
    v:=replace(v,qb||': '||p_b,qb);
    v:=replace(v,qb||' — '||p_b,qb);
    v:=replace(v,qb||' ("'||p_b||'")',qb);
    v:=replace(v,qb||' (“'||p_b||'”)',qb);
  end if;
  if nullif(btrim(p_c),'') is not null then
    v:=replace(v,qc||': '||p_c,qc);
    v:=replace(v,qc||' — '||p_c,qc);
    v:=replace(v,qc||' ("'||p_c||'")',qc);
    v:=replace(v,qc||' (“'||p_c||'”)',qc);
  end if;
  if nullif(btrim(p_d),'') is not null then
    v:=replace(v,qd||': '||p_d,qd);
    v:=replace(v,qd||' — '||p_d,qd);
    v:=replace(v,qd||' ("'||p_d||'")',qd);
    v:=replace(v,qd||' (“'||p_d||'”)',qd);
  end if;

  return regexp_replace(v,'[[:space:]]+([,;:.])',E'\\1','g');
end;
$function$;

-- Temporarily suspend only the explanation guard during the one-time rewrite.
-- The semantic-queue trigger is also suspended so text cleanup does not create
-- a fresh semantic/AI workload. Everything is re-enabled in the same transaction.
alter table english.questions disable trigger english_questions_order_neutral_explanation;
alter table english.questions disable trigger english_question_semantic_queue;
update english.questions
set explanation=english.explanation_order_neutralized(explanation,option_a,option_b,option_c,option_d)
where not english.explanation_is_order_neutral(explanation);
alter table english.questions enable trigger english_question_semantic_queue;
alter table english.questions enable trigger english_questions_order_neutral_explanation;

alter table english.saved_items disable trigger english_saved_order_neutral_explanation;
update english.saved_items
set explanation=english.explanation_order_neutralized(explanation,option_a,option_b,option_c,option_d)
where not english.explanation_is_order_neutral(explanation);
alter table english.saved_items enable trigger english_saved_order_neutral_explanation;

alter table english.sprint_items disable trigger english_sprint_order_neutral_explanation;
update english.sprint_items
set explanation=english.explanation_order_neutralized(explanation,options)
where not english.explanation_is_order_neutral(explanation);
alter table english.sprint_items enable trigger english_sprint_order_neutral_explanation;

alter table english.editorial_tone_items disable trigger english_editorial_order_neutral_explanation;
update english.editorial_tone_items
set explanation=english.explanation_order_neutralized(explanation,options)
where not english.explanation_is_order_neutral(explanation);
alter table english.editorial_tone_items enable trigger english_editorial_order_neutral_explanation;

do $contract$
begin
  if exists(select 1 from english.questions where not english.explanation_is_order_neutral(explanation))
     or exists(select 1 from english.saved_items where not english.explanation_is_order_neutral(explanation))
     or exists(select 1 from english.sprint_items where not english.explanation_is_order_neutral(explanation))
     or exists(select 1 from english.editorial_tone_items where not english.explanation_is_order_neutral(explanation)) then
    raise exception 'Order-neutral explanation hotfix did not fully converge';
  end if;
end;
$contract$;