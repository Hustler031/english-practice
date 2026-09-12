-- Daily Mix reader compatibility for performance-v3 and future performance-vN batches.
-- Frozen performance batches own their stored selection reason; legacy batches still use english.daily_reason().

create or replace function english.daily_effective_counts(
  p_user_id uuid,
  p_batch_date date,
  p_target integer default 120
)
returns table(total integer, completed integer, satisfied_elsewhere integer, remaining integer, raw_planned integer)
language sql
stable
security definer
set search_path to 'pg_catalog','english','auth'
as $function$
with sat as materialized (
  select concept_key from english.daily_satisfied_concepts(p_user_id,p_batch_date)
), base as (
  select d.question_id,d.sequence,d.status,
         lower(coalesce(d.status,''))='completed' is_completed,
         case
           when coalesce(d.selection_snapshot->>'buildVersion','') like 'performance-v%' then
             case when coalesce(s.mastered,false) then '' else coalesce(nullif(d.reason,''),'Mixed Performance') end
           else english.daily_reason(p_user_id,d.question_id,d.quiz_date)
         end reason_now,
         case when lower(coalesce(d.status,''))='completed' then false else sc.concept_key is not null end satisfied
  from english.daily_current d
  left join english.question_state s on s.user_id=p_user_id and s.question_id=d.question_id
  left join english.question_concept_mappings m on m.question_id=d.question_id
  left join sat sc on sc.concept_key=coalesce(m.concept_id,d.question_id)
  where d.user_id=p_user_id and d.quiz_date=p_batch_date
), planned as (
  select b.*,row_number() over(order by case when b.is_completed then 0 else 1 end,b.sequence,b.question_id) slot_rank
  from base b
  where b.is_completed or b.reason_now<>'' or b.satisfied
), effective as (
  select * from planned where slot_rank<=greatest(1,least(120,coalesce(p_target,120)))
)
select count(*)::int,
       count(*) filter(where is_completed)::int,
       count(*) filter(where not is_completed and satisfied)::int,
       count(*) filter(where not is_completed and not satisfied and reason_now<>'')::int,
       (select count(*)::int from planned)
from effective;
$function$;

create or replace function english.current_daily_items(p_user_id uuid)
returns table(
  sequence integer, priority integer, reason text, quiz_date date, status text,
  question_id text, topic text, word text, question text,
  option_a text, option_b text, option_c text, option_d text, correct_key text,
  explanation text, subtopic text, question_type text, source_file text, source_page text,
  concept_id text, difficulty text, tip text, usage_note text, example_sentence text,
  memory_aid text, related_words text, source_url text, starred boolean, difficult boolean
)
language sql
stable
security definer
set search_path to 'pg_catalog','english','auth'
as $function$
with batch as (
  select min(quiz_date) quiz_date from english.daily_current where user_id=p_user_id
), sat as materialized (
  select s.concept_key from batch b cross join lateral english.daily_satisfied_concepts(p_user_id,b.quiz_date) s
  where b.quiz_date is not null
), base as (
  select d.sequence,d.priority,d.reason,d.quiz_date,d.status,
         q.question_id,q.topic,q.word,q.question,q.option_a,q.option_b,q.option_c,q.option_d,upper(q.correct) correct_key,
         q.explanation,q.subtopic,q.question_type,q.source_file,q.source_page,q.concept_id,q.difficulty,
         q.tip,q.usage_note,q.example_sentence,q.memory_aid,q.related_words,q.source_url,
         coalesce(s.last_marked,false) starred,coalesce(ds.difficult,false) difficult,
         lower(coalesce(d.status,''))='completed' is_completed,
         case
           when coalesce(d.selection_snapshot->>'buildVersion','') like 'performance-v%' then
             case when coalesce(s.mastered,false) then '' else coalesce(nullif(d.reason,''),'Mixed Performance') end
           else english.daily_reason(p_user_id,q.question_id,d.quiz_date)
         end reason_now,
         case when lower(coalesce(d.status,''))='completed' then false else sc.concept_key is not null end satisfied
  from english.daily_current d
  join english.questions q on q.question_id=d.question_id
  left join english.question_concept_mappings m on m.question_id=q.question_id
  left join sat sc on sc.concept_key=coalesce(m.concept_id,q.question_id)
  left join english.question_state s on s.user_id=p_user_id and s.question_id=q.question_id
  left join english.difficult_state ds on ds.user_id=p_user_id and ds.question_id=q.question_id
  where d.user_id=p_user_id
    and q.active
    and not coalesce(s.mastered,false)
), planned as (
  select b.*,
         row_number() over(order by case when b.is_completed then 0 else 1 end,b.sequence,b.question_id) slot_rank
  from base b
  where b.is_completed or b.reason_now<>'' or b.satisfied
)
select sequence,priority,reason,quiz_date,status,
       question_id,topic,word,question,option_a,option_b,option_c,option_d,correct_key,
       explanation,subtopic,question_type,source_file,source_page,concept_id,difficulty,
       tip,usage_note,example_sentence,memory_aid,related_words,source_url,starred,difficult
from planned
where slot_rank<=120
  and (is_completed or (reason_now<>'' and not satisfied))
order by sequence;
$function$;
