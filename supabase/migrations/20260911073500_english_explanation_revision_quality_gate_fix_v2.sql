-- Explanation-only repairs are judged on explanation safety/accuracy, not on immutable pre-existing distractor difficulty.

create or replace function english.apply_question_revision_result(
  p_token text,
  p_proposal_id uuid,
  p_item jsonb,
  p_critic jsonb,
  p_source text,
  p_model text default 'gpt-5.6-luna',
  p_usage jsonb default '{}'::jsonb
) returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','english'
as $$
declare
  r english.question_revision_proposals%rowtype;
  q english.questions%rowtype;
  v_key text; v_payload jsonb; v_changed integer:=0; k text; v_new text; v_old text;
  v_score numeric; v_closeness numeric; v_traps integer; v_base_stem text; v_new_stem text; v_base_correct text; v_new_correct text;
begin
  if not english.context_worker_authorized(p_token) then raise exception 'context worker unauthorized'; end if;
  select * into r from english.question_revision_proposals where proposal_id=p_proposal_id for update;
  if not found then raise exception 'revision proposal not found'; end if;
  if r.status='superseded' then return jsonb_build_object('ok',true,'stale',true); end if;
  if r.status in ('ready','applied') then return jsonb_build_object('ok',true,'alreadyReady',true,'status',r.status); end if;
  if r.status<>'processing' then raise exception 'revision proposal is not claimed'; end if;
  select * into q from english.questions where question_id=r.question_id;
  if not found then raise exception 'base question not found'; end if;

  v_key:=upper(trim(coalesce(p_item->>'correctKey','')));
  if v_key<>upper(coalesce(q.correct,'')) or v_key<>upper(coalesce(r.base_payload->>'correctKey','')) then raise exception 'revision changed the canonical correct key'; end if;
  if nullif(trim(coalesce(p_item->>'question','')),'') is null or char_length(trim(p_item->>'question'))<8 then raise exception 'revision question is incomplete'; end if;
  if nullif(trim(coalesce(p_item->>'explanation','')),'') is null or char_length(trim(p_item->>'explanation'))<20 then raise exception 'revision explanation is incomplete'; end if;
  if nullif(trim(coalesce(p_item->>'optionA','')),'') is null or nullif(trim(coalesce(p_item->>'optionB','')),'') is null or nullif(trim(coalesce(p_item->>'optionC','')),'') is null or nullif(trim(coalesce(p_item->>'optionD','')),'') is null then raise exception 'revision options are incomplete'; end if;
  if lower(trim(p_item->>'optionA')) in (lower(trim(p_item->>'optionB')),lower(trim(p_item->>'optionC')),lower(trim(p_item->>'optionD'))) or lower(trim(p_item->>'optionB')) in (lower(trim(p_item->>'optionC')),lower(trim(p_item->>'optionD'))) or lower(trim(p_item->>'optionC'))=lower(trim(p_item->>'optionD')) then raise exception 'revision options are not unique'; end if;

  v_score:=coalesce((p_critic->>'qualityScore')::numeric,0);
  v_closeness:=coalesce((p_critic->>'distractorCloseness')::numeric,0);
  v_traps:=coalesce((p_critic->>'realisticTrapCount')::integer,0);

  -- Explanation-only work still protects correctness, ambiguity, concept fidelity and the new explanation.
  -- It does not fail because the untouched original question is easy or has weak distractors.
  if not coalesce((p_critic->>'exactlyOneCorrect')::boolean,false)
     or not coalesce((p_critic->>'explanationMatches')::boolean,false)
     or not coalesce((p_critic->>'noStaleExplanation')::boolean,false)
     or not coalesce((p_critic->>'noAmbiguity')::boolean,false)
     or not coalesce((p_critic->>'faithfulConcept')::boolean,false)
     or (r.feedback_reason<>'explanation_weak' and not coalesce((p_critic->>'fairDifficulty')::boolean,false))
     or (r.feedback_reason<>'explanation_weak' and v_score<0.85) then
    raise exception 'revision critic rejected the proposal';
  end if;

  if r.feedback_reason<>'explanation_weak' and (
       not coalesce((p_critic->>'closeDistractors')::boolean,false)
       or not coalesce((p_critic->>'notObviouslyEliminable')::boolean,false)
       or not coalesce((p_critic->>'sscDifficultyFit')::boolean,false)
       or coalesce((p_critic->>'obviousElimination')::boolean,true)
       or coalesce((p_critic->>'difficultyArtificial')::boolean,true)
       or v_closeness<0.70
       or v_traps<2
     ) then raise exception 'revision failed SSC toughness gate'; end if;

  if lower(regexp_replace(trim(p_item->>'explanation'),'[[:space:]]+',' ','g'))=lower(regexp_replace(trim(coalesce(r.base_payload->>'explanation','')),'[[:space:]]+',' ','g')) then raise exception 'revision explanation is stale'; end if;

  v_base_stem:=lower(regexp_replace(trim(coalesce(r.base_payload->>'question','')),'[[:space:]]+',' ','g'));
  v_new_stem:=lower(regexp_replace(trim(coalesce(p_item->>'question','')),'[[:space:]]+',' ','g'));
  if r.feedback_reason in ('options_too_obvious','distractors_unrelated','explanation_weak') and v_new_stem<>v_base_stem then raise exception 'question stem changed during a repair-only revision'; end if;

  v_base_correct:=lower(regexp_replace(trim(coalesce(r.base_payload->>('option'||v_key),'')),'[[:space:]]+',' ','g'));
  v_new_correct:=lower(regexp_replace(trim(coalesce(p_item->>('option'||v_key),'')),'[[:space:]]+',' ','g'));
  if r.feedback_reason in ('options_too_obvious','distractors_unrelated','explanation_weak') and v_new_correct<>v_base_correct then raise exception 'correct option changed during a repair-only revision'; end if;

  foreach k in array array['A','B','C','D'] loop
    v_new:=lower(regexp_replace(trim(coalesce(p_item->>('option'||k),'')),'[[:space:]]+',' ','g'));
    v_old:=lower(regexp_replace(trim(coalesce(r.base_payload->>('option'||k),'')),'[[:space:]]+',' ','g'));
    if v_new<>v_old then v_changed:=v_changed+1; end if;
  end loop;
  if r.feedback_reason in ('options_too_obvious','distractors_unrelated') and v_changed<2 then raise exception 'revision did not materially improve the distractors'; end if;
  if r.feedback_reason='explanation_weak' and v_changed<>0 then raise exception 'explanation-only revision changed options'; end if;

  if p_source not in ('bank_informed_ai','ai_last_resort') then raise exception 'invalid revision generation source'; end if;
  v_payload:=jsonb_build_object(
    'question',trim(p_item->>'question'),
    'optionA',trim(p_item->>'optionA'),'optionB',trim(p_item->>'optionB'),'optionC',trim(p_item->>'optionC'),'optionD',trim(p_item->>'optionD'),
    'correctKey',v_key,'explanation',trim(p_item->>'explanation')
  );

  update english.question_revision_proposals
  set status='ready',proposed_payload=v_payload,critic=p_critic,generation_source=p_source,
      ai_model=p_model,ai_usage=coalesce(p_usage,'{}'::jsonb),ready_at=now(),last_error=null,error_code=null,updated_at=now()
  where proposal_id=p_proposal_id and status='processing';

  insert into english.revision_strategy_stats(user_id,feedback_reason,ready_count,updated_at)
  values(r.user_id,r.feedback_reason,1,now())
  on conflict(user_id,feedback_reason) do update
    set ready_count=english.revision_strategy_stats.ready_count+1,updated_at=now();

  return jsonb_build_object('ok',true,'proposalId',p_proposal_id,'status','ready','qualityScore',v_score,'source',p_source);
end $$;

revoke all on function english.apply_question_revision_result(text,uuid,jsonb,jsonb,text,text,jsonb) from public,anon,authenticated;
grant execute on function english.apply_question_revision_result(text,uuid,jsonb,jsonb,text,text,jsonb) to service_role;

create or replace function public.english_apply_question_revision_result(
  p_token text,p_proposal_id uuid,p_item jsonb,p_critic jsonb,p_source text,p_model text default 'gpt-5.6-luna',p_usage jsonb default '{}'::jsonb
) returns jsonb language sql security definer set search_path to 'pg_catalog','public','english'
as $$ select english.apply_question_revision_result(p_token,p_proposal_id,p_item,p_critic,p_source,p_model,p_usage); $$;
revoke all on function public.english_apply_question_revision_result(text,uuid,jsonb,jsonb,text,text,jsonb) from public,anon,authenticated;
grant execute on function public.english_apply_question_revision_result(text,uuid,jsonb,jsonb,text,text,jsonb) to service_role;
