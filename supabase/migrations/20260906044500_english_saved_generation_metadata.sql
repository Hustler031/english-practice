create or replace function public.english_get_saved_items()
returns jsonb
language sql
stable
security definer
set search_path to 'pg_catalog', 'public', 'english', 'auth'
as $function$
select case when auth.uid() is null then '[]'::jsonb else coalesce(jsonb_agg(jsonb_build_object(
 'id',s.saved_id,
 'word',coalesce(s.word,''),
 'meaning',coalesce(s.meaning,''),
 'context',coalesce(s.context,''),
 'questionId',coalesce(s.origin_question_id,''),
 'module',coalesce(s.origin_module,''),
 'source',coalesce(s.source,''),
 'status',coalesce(s.status,'Saved'),
 'practiceQuestionId',coalesce(s.practice_question_id,''),
 'created',s.created_at,
 'updated',s.updated_at,
 'partOfSpeech',coalesce(s.part_of_speech,''),
 'synonyms',coalesce(s.synonyms,''),
 'antonyms',coalesce(s.antonyms,''),
 'example',coalesce(s.example,''),
 'explanation',coalesce(s.explanation,''),
 'question',coalesce(s.question,''),
 'optionA',coalesce(s.option_a,''),
 'optionB',coalesce(s.option_b,''),
 'optionC',coalesce(s.option_c,''),
 'optionD',coalesce(s.option_d,''),
 'correctOption',coalesce(s.correct_option,''),
 'gptStatus',coalesce(s.gpt_status,'Pending GPT'),
 'gptUpdated',s.gpt_updated_at,
 'gptSource',coalesce(s.gpt_source,''),
 'captureType',coalesce(t.capture_type,'AUTO'),
 'resolvedType',coalesce(t.resolved_type,english.resolve_saved_type('AUTO',s.word,s.meaning,s.context,s.part_of_speech,s.question,s.explanation)),
 'generatorProvider',coalesce(a.generator_provider,''),
 'generatorModel',coalesce(a.generator_model,''),
 'criticProvider',coalesce(a.critic_provider,''),
 'criticModel',coalesce(a.critic_model,''),
 'criticScore',a.quality_score,
 'criticDecision',coalesce(a.critic_decision,''),
 'generationRepairCount',coalesce(a.repair_count,0)
) order by s.created_at desc nulls last),'[]'::jsonb) end
from english.saved_items s
left join english.saved_item_types t
  on t.user_id=s.user_id and t.saved_id=s.saved_id
left join lateral (
  select cga.generator_provider,cga.generator_model,cga.critic_provider,cga.critic_model,
         cga.quality_score,cga.critic_decision,cga.repair_count
  from english.content_generation_audits cga
  where cga.lane='saved' and cga.entity_key=s.saved_id
  order by cga.created_at desc
  limit 1
) a on true
where s.user_id=auth.uid() and s.active;
$function$;

revoke all on function public.english_get_saved_items() from public;
grant execute on function public.english_get_saved_items() to authenticated;
