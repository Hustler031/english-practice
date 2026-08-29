create or replace function public.english_get_learning_progress()
returns jsonb language sql stable security definer
set search_path=pg_catalog,public,english,auth as $$
with universe as (
  select q.question_id,q.topic,q.concept_id,q.source_id,q.source_file,q.active,
         english.learning_category(q.topic) category_id,
         coalesce(o.origin_kind,'core') origin_kind,
         english.recent_content_date(q) recent_date,
         coalesce(s.mastered,false) manual_mastered,
         coalesce(s.attempts,0) state_attempts,
         coalesce(s.status,'New') state
  from english.questions q
  left join english.question_origins o on o.question_id=q.question_id
  left join english.question_state s on s.user_id=auth.uid() and s.question_id=q.question_id
  where auth.uid() is not null and q.active and (not coalesce(s.mastered,false) or coalesce(s.attempts,0)>0)
), a0 as (
  select a.*,(a.attempted_at at time zone 'Asia/Kolkata')::date study_date,
    row_number() over(partition by a.question_id order by a.attempted_at,a.source_row nulls last,a.created_at,a.attempt_id) overall_rn,
    row_number() over(partition by a.question_id,(a.attempted_at at time zone 'Asia/Kolkata')::date order by a.attempted_at,a.source_row nulls last,a.created_at,a.attempt_id) day_rn
  from english.attempts a join universe u on u.question_id=a.question_id
  where a.user_id=auth.uid()
), cp as (
  select a0.*,row_number() over(partition by question_id order by study_date,attempted_at,source_row nulls last,created_at,attempt_id) cp_rn
  from a0 where day_rn=1
), perq as (
  select u.question_id,u.category_id,u.concept_id,u.origin_kind,u.recent_date,u.source_id,u.source_file,
    count(a0.attempt_id)::int attempts,
    coalesce(bool_or(a0.overall_rn=1 and a0.correct),false) first_correct,
    count(cp.attempt_id) filter(where cp.cp_rn>1)::int retention_attempts,
    count(cp.attempt_id) filter(where cp.cp_rn>1 and cp.correct)::int retention_correct,
    count(a0.attempt_id) filter(where a0.day_rn>1)::int after_attempts,
    count(a0.attempt_id) filter(where a0.day_rn>1 and a0.correct)::int after_correct,
    u.state,u.manual_mastered
  from universe u
  left join a0 on a0.question_id=u.question_id
  left join cp on cp.attempt_id=a0.attempt_id
  group by u.question_id,u.category_id,u.concept_id,u.origin_kind,u.recent_date,u.source_id,u.source_file,u.state,u.manual_mastered
), bank as (
  select p.* from perq p join english.questions q on q.question_id=p.question_id where english.is_genuine_bank_question(q)
), category_metrics as (
  select category_id,
    count(*)::int total,count(*) filter(where attempts>0)::int exposed,
    count(*) filter(where attempts>0)::int first_n,count(*) filter(where attempts>0 and first_correct)::int first_c,
    coalesce(sum(retention_attempts),0)::int ret_n,coalesce(sum(retention_correct),0)::int ret_c,
    coalesce(sum(after_attempts),0)::int after_n,coalesce(sum(after_correct),0)::int after_c,
    count(*) filter(where state in ('Persistent Weak','Weak','Fragile'))::int weak,
    count(distinct case when state in ('Persistent Weak','Weak') and attempts>0 then coalesce(nullif(concept_id,''),'Q:'||question_id) end)::int weak_concepts,
    count(*) filter(where state='Persistent Weak')::int persistent_weak,
    count(*) filter(where state='Fragile')::int fragile,
    count(*) filter(where state='Strong')::int strong,
    count(*) filter(where state='Proven Mastered')::int mastered
  from bank group by grouping sets((category_id),())
), composition as (
  select english.learning_category(q.topic) category_id,
    count(*)::int total_active,
    count(*) filter(where coalesce(o.origin_kind,'core')='core')::int core,
    count(*) filter(where coalesce(o.origin_kind,'core') in ('saved_generated','hindu_generated','other_generated'))::int added,
    count(*) filter(where coalesce(o.origin_kind,'core')='demand_generated')::int demand
  from english.questions q left join english.question_origins o on o.question_id=q.question_id
  where q.active group by grouping sets((english.learning_category(q.topic)),())
), cats as (
  select m.category_id,m.total,m.exposed,m.first_n,m.first_c,m.ret_n,m.ret_c,m.after_n,m.after_c,
         m.weak,m.weak_concepts,m.persistent_weak,m.fragile,m.strong,m.mastered,
         c.total_active,c.core,c.added,c.demand,
    case m.category_id when 'VOC' then 'Vocabulary' when 'IDIOM' then 'Idioms & Phrases' when 'PHRASAL' then 'Phrasal Verbs'
      when 'OWS' then 'One Word Substitution' when 'FIELDS_OF_STUDY' then 'Fields of Study' when 'FIXED_PREPOSITION' then 'Fixed Preposition'
      when 'SYN_ANT' then 'Synonyms & Antonyms' when 'CONFUSED' then 'Confused Words' when 'SPELLING' then 'Spelling'
      when 'GRAMMAR' then 'Grammar' when 'ERROR' then 'Error Detection' when 'SENT_IMP' then 'Sentence Improvement'
      when 'FILL' then 'Fill in the Blanks' when 'CLOZE' then 'Cloze Test' when 'PARA' then 'Para Jumbles'
      when 'RC' then 'Reading Comprehension' else coalesce(m.category_id,'Overall') end name
  from category_metrics m left join composition c on c.category_id is not distinct from m.category_id
), module_sets as (
  select 'practice'::text module,question_id from bank
  union
  select 'new',p.question_id from perq p where p.recent_date >= ((now() at time zone 'Asia/Kolkata')::date-6) or p.origin_kind in ('hindu_generated','saved_generated')
  union
  select 'demanded',p.question_id from perq p where exists(
    select 1 from english.practice_set_items i join english.practice_sets s on s.set_id=i.set_id
    where i.question_id=p.question_id and coalesce(s.active,true)
  )
  union
  select 'hindu',p.question_id from perq p where p.origin_kind='hindu_generated' or p.question_id ~* '^HV20[0-9]{6}_'
  union
  select 'sources',p.question_id from perq p where nullif(btrim(coalesce(p.source_id,p.source_file,'')),'') is not null
  union
  select 'saved',p.question_id from perq p where exists(
    select 1 from english.saved_items si where si.user_id=auth.uid() and si.active and si.practice_question_id=p.question_id
  )
), module_metrics as (
  select ms.module,
    count(*)::int total,count(*) filter(where p.attempts>0)::int exposed,
    count(*) filter(where p.attempts>0)::int first_n,count(*) filter(where p.attempts>0 and p.first_correct)::int first_c,
    coalesce(sum(p.retention_attempts),0)::int ret_n,coalesce(sum(p.retention_correct),0)::int ret_c,
    coalesce(sum(p.after_attempts),0)::int after_n,coalesce(sum(p.after_correct),0)::int after_c,
    count(*) filter(where p.state in ('Persistent Weak','Weak','Fragile'))::int weak,
    count(distinct case when p.state in ('Persistent Weak','Weak') and p.attempts>0 then coalesce(nullif(p.concept_id,''),'Q:'||p.question_id) end)::int weak_concepts,
    count(*) filter(where p.state='Persistent Weak')::int persistent_weak,
    count(*) filter(where p.state='Fragile')::int fragile,
    count(*) filter(where p.state='Strong')::int strong,
    count(*) filter(where p.state='Proven Mastered')::int mastered
  from module_sets ms join perq p on p.question_id=ms.question_id group by ms.module
), totalrow as (select * from cats where category_id is null),
active_comp as (select * from composition where category_id is null)
select jsonb_build_object(
  'schemaVersion',3,
  'bankExposed',case when t.total>0 then round(t.exposed*100.0/t.total,1) else 0 end,
  'exposed',t.exposed,'total',t.total,'left',greatest(0,t.total-t.exposed),
  'firstAttemptAccuracy',case when t.first_n>0 then round(t.first_c*100.0/t.first_n,1) else 0 end,
  'afterReviewAccuracy',case when t.after_n>0 then round(t.after_c*100.0/t.after_n,1) else 0 end,
  'retentionAccuracy',case when t.ret_n>0 then round(t.ret_c*100.0/t.ret_n,1) else 0 end,
  'weakCount',t.weak,'weakConcepts',t.weak_concepts,'persistentWeakCount',t.persistent_weak,
  'fragileCount',t.fragile,'strongCount',t.strong,'masteredCount',t.mastered,
  'composition',jsonb_build_object('coreBank',ac.core,'addedGenerated',ac.added,'demandCreated',ac.demand,'totalActive',ac.total_active),
  'categories',coalesce((select jsonb_agg(jsonb_build_object(
    'id',c.category_id,'name',c.name,'total',c.total,'exposed',c.exposed,'left',greatest(0,c.total-c.exposed),
    'coveragePercent',case when c.total>0 then round(c.exposed*100.0/c.total,1) else 0 end,
    'firstAttemptAccuracy',case when c.first_n>0 then round(c.first_c*100.0/c.first_n,1) else 0 end,
    'afterReviewAccuracy',case when c.after_n>0 then round(c.after_c*100.0/c.after_n,1) else 0 end,
    'retentionAccuracy',case when c.ret_n>0 then round(c.ret_c*100.0/c.ret_n,1) else 0 end,
    'weak',c.weak,'weakConcepts',c.weak_concepts,'persistentWeak',c.persistent_weak,'fragile',c.fragile,'strong',c.strong,'mastered',c.mastered,
    'core',c.core,'added',c.added,'demand',c.demand,'totalActive',c.total_active
  ) order by c.total desc,c.name) from cats c where c.category_id is not null),'[]'::jsonb),
  'modules',coalesce((select jsonb_object_agg(m.module,jsonb_build_object(
    'total',m.total,'encountered',m.exposed,'exposed',m.exposed,'left',greatest(0,m.total-m.exposed),
    'coveragePercent',case when m.total>0 then round(m.exposed*100.0/m.total,1) else 0 end,
    'firstAttemptAccuracy',case when m.first_n>0 then round(m.first_c*100.0/m.first_n,1) else 0 end,
    'afterReviewAccuracy',case when m.after_n>0 then round(m.after_c*100.0/m.after_n,1) else 0 end,
    'retentionAccuracy',case when m.ret_n>0 then round(m.ret_c*100.0/m.ret_n,1) else 0 end,
    'weak',m.weak,'weakConcepts',m.weak_concepts,'persistentWeak',m.persistent_weak,'fragile',m.fragile,'strong',m.strong,'mastered',m.mastered
  )) from module_metrics m),'{}'::jsonb)
) from totalrow t cross join active_comp ac;
$$;
