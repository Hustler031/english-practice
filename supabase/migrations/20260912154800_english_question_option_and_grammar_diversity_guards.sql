-- English V2 quality hardening (2026-09-12)
--
-- 1. Repair the ten known active canonical questions that had duplicate options.
-- 2. Prevent any active question from publishing duplicate nonblank options after
--    trim/case/whitespace normalization.
-- 3. Prevent an exact-20 Grammar Daily set from collapsing back to one/two
--    presentation families or allowing a single family to exceed 50%.
--
-- The Grammar routing expansion itself is owned by
-- 20260911234500_english_grammar_intelligence_ssc_family_routing.sql.

update english.questions
set option_d='for',
    explanation='The fixed construction is “hindrance to + noun/pronoun/gerund”. Therefore “to” is correct: “There is no hindrance to his going there.” “At”, “over”, and “for” do not form the required construction with “hindrance” here.',
    review_notes=concat_ws(' · ',nullif(review_notes,''),'2026-09-12 duplicate-option repair'),
    updated_at=now()
where question_id='FP0101';

update english.questions
set option_d='with',
    explanation='The fixed construction is “be/become inured to something”, meaning to become accustomed to something unpleasant. Therefore “to” is correct. “By”, “for”, and “with” do not complete “inured” in this sense.',
    review_notes=concat_ws(' · ',nullif(review_notes,''),'2026-09-12 duplicate-option repair'),
    updated_at=now()
where question_id='FP0205';

update english.questions
set option_d='with',
    explanation='The fixed construction is “fond of + noun/gerund”. Hence “of” is correct: “Naeem is fond of playing tennis.” “In”, “for”, and “with” are not used after “fond” in this construction.',
    review_notes=concat_ws(' · ',nullif(review_notes,''),'2026-09-12 duplicate-option repair'),
    updated_at=now()
where question_id='FP0300';

update english.questions
set option_c='Exhilirate',
    explanation='“Exhilarate” is correctly spelt and means to make someone feel very happy, excited, or elated. “Exilarate”, “Exhilerate”, and “Exhilirate” are misspellings. Spelling cue: ex + hilar + ate → exhilarate.',
    review_notes=concat_ws(' · ',nullif(review_notes,''),'2026-09-12 duplicate-option repair'),
    updated_at=now()
where question_id='SPL0046';

update english.questions
set option_d='Sattelite',
    explanation='“Satellite” is correctly spelt. “Satelite”, “Sattellite”, and “Sattelite” are misspellings. Spelling cue: satellite has one t in “sat-” and double l: sat-e-ll-ite.',
    review_notes=concat_ws(' · ',nullif(review_notes,''),'2026-09-12 duplicate-option repair'),
    updated_at=now()
where question_id='SPL0093';

update english.questions
set option_d='Adolesence',
    explanation='“Adolescence” is correctly spelt: a-d-o-l-e-s-c-e-n-c-e. “Adolescense”, “Adolscence”, and “Adolesence” are misspellings. The noun ends in “-scence”.',
    review_notes=concat_ws(' · ',nullif(review_notes,''),'2026-09-12 duplicate-option repair'),
    updated_at=now()
where question_id='SPL0227';

update english.questions
set option_d='Monolgue',
    explanation='“Monologue” is correctly spelt and means a long speech by one person. “Monolouge”, “Monologe”, and “Monolgue” are misspellings. Spelling cue: mono + logue.',
    review_notes=concat_ws(' · ',nullif(review_notes,''),'2026-09-12 duplicate-option repair'),
    updated_at=now()
where question_id='SPL0287';

update english.questions
set option_c='Skillfule',
    explanation='“Skillful” is the correctly spelt form used here (standard American spelling); British English commonly uses “skilful”. “Skilfull”, “Skillfull”, and “Skillfule” are misspellings. The keyed option remains uniquely correct within this option set.',
    review_notes=concat_ws(' · ',nullif(review_notes,''),'2026-09-12 duplicate-option repair'),
    updated_at=now()
where question_id='SPL0311';

update english.questions
set option_c='Expand',
    explanation='“Expaact” is the incorrectly spelt option. “Impact”, “Excite”, and “Expand” are correctly spelt words. The malformed form “Expaact” should not be confused with “impact”, “exact”, or “expand”.',
    review_notes=concat_ws(' · ',nullif(review_notes,''),'2026-09-12 duplicate-option repair'),
    updated_at=now()
where question_id='SPL0763';

update english.questions
set option_d='inoculating',
    explanation='“Inoculatted” is incorrectly spelt; the correct past-tense form is “inoculated”. “Inoculated”, “inoculation”, and “inoculating” are correctly spelt members of the same word family.',
    review_notes=concat_ws(' · ',nullif(review_notes,''),'2026-09-12 duplicate-option repair'),
    updated_at=now()
where question_id='SPL0920';

create or replace function english.enforce_distinct_active_question_options()
returns trigger
language plpgsql
set search_path to 'pg_catalog','english'
as $function$
declare
  v_nonblank integer;
  v_distinct integer;
begin
  if not coalesce(new.active,false) then
    return new;
  end if;

  select count(*), count(distinct lower(regexp_replace(btrim(v),'\s+',' ','g')))
    into v_nonblank,v_distinct
  from unnest(array[new.option_a,new.option_b,new.option_c,new.option_d]) as t(v)
  where nullif(btrim(v),'') is not null;

  if v_nonblank <> v_distinct then
    raise exception 'Active question % has duplicate nonblank answer options',coalesce(new.question_id,'<new>');
  end if;

  return new;
end
$function$;

drop trigger if exists trg_questions_distinct_active_options on english.questions;
create trigger trg_questions_distinct_active_options
before insert or update of option_a,option_b,option_c,option_d,active
on english.questions
for each row execute function english.enforce_distinct_active_question_options();

comment on function english.enforce_distinct_active_question_options() is
'Hard publication guard: active English questions may have blank optional choices, but every nonblank option must be unique after trim/case/whitespace normalization.';

create or replace function english.enforce_grammar_daily_family_diversity()
returns trigger
language plpgsql
set search_path to 'pg_catalog','english'
as $function$
declare
  v_count integer;
  v_families integer;
  v_max_family integer;
begin
  select count(*),count(distinct lower(btrim(question_family)))
    into v_count,v_families
  from english.grammar_daily_items
  where batch_date=new.batch_date;

  if v_count=20 then
    select max(c) into v_max_family
    from (
      select count(*)::integer c
      from english.grammar_daily_items
      where batch_date=new.batch_date
      group by lower(btrim(question_family))
    ) s;

    if v_families < 3 or coalesce(v_max_family,0) > 10 then
      raise exception 'Grammar daily family-diversity gate failed for %: % families, max family count %',new.batch_date,v_families,v_max_family;
    end if;
  end if;

  return null;
end
$function$;

drop trigger if exists trg_grammar_daily_family_diversity on english.grammar_daily_items;
create constraint trigger trg_grammar_daily_family_diversity
after insert or update of question_family on english.grammar_daily_items
deferrable initially deferred
for each row execute function english.enforce_grammar_daily_family_diversity();

comment on function english.enforce_grammar_daily_family_diversity() is
'Hard exact-20 Grammar batch gate. Once a daily batch has 20 rows it must contain at least 3 question families and no single family may exceed 10 items.';
