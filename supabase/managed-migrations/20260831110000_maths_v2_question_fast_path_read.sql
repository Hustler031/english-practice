-- Read-only SSC fast-path metadata for the coach UI. No strategy is invented: preserved family/card/question metadata only.
create or replace function public.maths_get_question_fast_path(p_question_id text)
returns jsonb language plpgsql stable security definer set search_path='pg_catalog','public','maths' as $$
declare uid uuid:=maths._require_uid(); fam text; con text; out_ jsonb;
begin
  if not exists(select 1 from maths.runtime_questions where question_id=p_question_id and runtime_active) then raise exception 'Question not found'; end if;
  select family_id into fam from maths.question_families where question_id=p_question_id and active limit 1;
  select concept_id into con from maths.question_concepts where question_id=p_question_id and active order by confidence desc limit 1;
  select jsonb_build_object(
    'ok',true,'questionId',p_question_id,'familyId',fam,'conceptId',con,
    'pattern',coalesce(a.pattern,f.family_name),
    'trigger',coalesce(a.trigger_text,f.recognition_trigger,q.memory_cue),
    'firstThought',a.first_thought,
    'fastMethod',coalesce(a.fast_method,f.common_method,q.memory_cue),
    'trap',a.trap,
    'concept',c.concept_name,
    'source',case when a.card_id is not null then 'personal' when f.family_id is not null then 'template_group' else 'question' end
  ) into out_
  from maths.runtime_questions q
  left join maths.family_catalog f on f.family_id=fam and f.active
  left join maths.concept_catalog c on c.concept_id=con and c.active
  left join lateral(select * from maths.approach_cards x where x.user_id=uid and x.family_id=fam and x.active order by x.updated_at desc limit 1)a on true
  where q.question_id=p_question_id;
  return coalesce(out_,jsonb_build_object('ok',true,'questionId',p_question_id));
end $$;
revoke all on function public.maths_get_question_fast_path(text) from public,anon;
grant execute on function public.maths_get_question_fast_path(text) to authenticated;
