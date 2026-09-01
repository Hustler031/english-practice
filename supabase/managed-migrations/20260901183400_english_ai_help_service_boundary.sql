-- AI Help is manual and authenticated, but hidden answer context and Luna-driven
-- learning mutations stay behind the Edge Function service-role boundary.

create or replace function public.english_get_ai_help_context_service(p_user_id uuid,p_question_id text) returns jsonb
language plpgsql stable security definer set search_path=pg_catalog,public,english,auth as $$
declare uid uuid:=p_user_id; outv jsonb;
begin
  if coalesce(auth.jwt()->>'role','')<>'service_role' then raise exception 'Service role required'; end if;
  if uid is null or not exists(select 1 from auth.users u where u.id=uid) then raise exception 'Valid learner required'; end if;
  if not exists(select 1 from english.questions q where q.question_id=p_question_id and q.active) then raise exception 'Question not found'; end if;
  select jsonb_build_object(
    'question_id',q.question_id,'question',q.question,
    'options',jsonb_build_array(jsonb_build_object('key','A','text',q.option_a),jsonb_build_object('key','B','text',q.option_b),jsonb_build_object('key','C','text',q.option_c),jsonb_build_object('key','D','text',q.option_d)),
    'correct_answer',q.correct,'explanation',q.explanation,'topic',q.topic,'subtopic',q.subtopic,'word',q.word,'question_type',q.question_type,'difficulty',q.difficulty,
    'concept',jsonb_strip_nulls(jsonb_build_object('concept_id',m.concept_id,'name',c.name,'family',c.skill_family,'domain',c.domain,'exam_relevance',c.exam_relevance,'mapping_confidence',m.mapping_confidence,'mapping_method',m.mapping_method,'review_status',m.review_status)),
    'question_state',jsonb_strip_nulls(jsonb_build_object('status',s.status,'attempts',s.attempts,'correct',s.correct,'wrong',s.wrong,'accuracy',s.accuracy,'correct_streak',s.correct_streak,'next_review',s.next_review,'mastered',s.mastered,'last_attempt',s.last_attempt,'last_result',s.last_result,'last_time',s.last_time)),
    'concept_evidence',jsonb_strip_nulls(jsonb_build_object('coverage_state',ce.coverage_state,'confidence_score',ce.confidence_score,'attempts',ce.attempts,'correct',ce.correct,'wrong',ce.wrong,'guessed',ce.guessed,'distinct_questions',ce.distinct_questions,'distinct_variants',ce.distinct_variants,'transfer_successes',ce.transfer_successes,'delayed_successes',ce.delayed_successes,'recent_failures',ce.recent_failures,'confusion_count',ce.confusion_count,'next_review',ce.next_review,'last_attempt_at',ce.last_attempt_at)),
    'recent_attempts',(select coalesce(jsonb_agg(to_jsonb(a) order by a.attempted_at desc),'[]'::jsonb) from (select a.attempted_at,a.selected_answer,a.correct,a.time_seconds,a.module from english.attempts a where a.user_id=uid and a.question_id=p_question_id order by a.attempted_at desc limit 8) a),
    'related_concepts',(select coalesce(jsonb_agg(jsonb_strip_nulls(jsonb_build_object('relationship',r.relationship,'confidence',r.confidence,'concept_id',rc.concept_id,'name',rc.name,'family',rc.skill_family,'learner_state',re.coverage_state,'learner_confidence',re.confidence_score)) order by r.confidence desc),'[]'::jsonb) from english.concept_relationships r join english.concepts rc on rc.concept_id=r.related_concept_id left join english.concept_evidence re on re.user_id=uid and re.concept_id=rc.concept_id where r.concept_id=m.concept_id limit 12),
    'route',(select jsonb_strip_nulls(jsonb_build_object('route',lr.route,'fast_track_status',lr.fast_track_status,'origins',lr.origins,'last_reason',lr.last_route_reason,'next_fast_track_check',lr.next_fast_track_check,'pending_failure_decision',lr.pending_failure_decision)) from english.learning_route_state lr where lr.user_id=uid and lr.question_id=p_question_id),
    'latest_confidence_signals',(select coalesce(jsonb_agg(jsonb_build_object('signal',g.signal,'created_at',g.created_at) order by g.created_at desc),'[]'::jsonb) from (select signal,created_at from english.learner_confidence_signals where user_id=uid and question_id=p_question_id order by created_at desc limit 5) g)
  ) into outv
  from english.questions q
  left join english.question_concept_mappings m on m.question_id=q.question_id
  left join english.concepts c on c.concept_id=m.concept_id
  left join english.question_state s on s.user_id=uid and s.question_id=q.question_id
  left join english.concept_evidence ce on ce.user_id=uid and ce.concept_id=m.concept_id
  where q.question_id=p_question_id;
  return outv;
end $$;
revoke all on function public.english_get_ai_help_context_service(uuid,text) from public,anon,authenticated;
grant execute on function public.english_get_ai_help_context_service(uuid,text) to service_role;

create or replace function public.english_apply_ai_help_result_service(
  p_user_id uuid,p_question_id text,p_model text,p_diagnosis text,p_confidence numeric,p_action_code text,p_help text,
  p_input_tokens integer default null,p_output_tokens integer default null,p_reasoning_tokens integer default null,p_metadata jsonb default '{}'
) returns jsonb
language plpgsql security definer set search_path=pg_catalog,public,english,auth as $$
declare uid uuid:=p_user_id; cid text; action_taken text:='none'; diag text:=lower(trim(coalesce(p_diagnosis,'no_action'))); act text:=lower(trim(coalesce(p_action_code,'no_action')));
begin
  if coalesce(auth.jwt()->>'role','')<>'service_role' then raise exception 'Service role required'; end if;
  if uid is null or not exists(select 1 from auth.users u where u.id=uid) then raise exception 'Valid learner required'; end if;
  if not exists(select 1 from english.questions where question_id=p_question_id) then raise exception 'Question not found'; end if;
  select m.concept_id into cid from english.question_concept_mappings m where m.question_id=p_question_id;
  if act not in ('targeted_mastery','retention_check','quality_review','no_action') then act:='no_action'; end if;
  if coalesce(p_confidence,0)>=.72 and act='targeted_mastery' and diag in ('rule_gap','knowledge_gap','confusion_pair','retention_issue','transfer_needed') then
    perform english.route_to_targeted(uid,p_question_id,'AI Help','Learner-reported '||replace(diag,'_',' ')); action_taken:='targeted_mastery';
  elsif coalesce(p_confidence,0)>=.70 and act='retention_check' and cid is not null then
    update english.concept_evidence set next_review=least(coalesce(next_review,now()),now()+interval '12 hours'),coverage_state=case when coverage_state='exam_ready' then 'retention_risk' else coverage_state end,updated_at=now() where user_id=uid and concept_id=cid; action_taken:='retention_check';
  elsif coalesce(p_confidence,0)>=.78 and act='quality_review' and diag in ('questionable_key','ambiguous_wording','explanation_issue') then
    insert into english.question_quality_flags(question_id,status,flags,provenance,updated_by,updated_at)
    values(p_question_id,case when diag='ambiguous_wording' then 'potentially_ambiguous' else 'needs_review' end,jsonb_build_array(diag),jsonb_build_object('source','AI Help','confidence',p_confidence,'learner_help',left(coalesce(p_help,''),500)),'luna_ai_help',now())
    on conflict(question_id) do update set status=case when english.question_quality_flags.status in ('quarantined','repaired') then english.question_quality_flags.status else excluded.status end,flags=(select jsonb_agg(distinct x) from jsonb_array_elements(english.question_quality_flags.flags||excluded.flags) x),provenance=english.question_quality_flags.provenance||excluded.provenance,updated_by='luna_ai_help',updated_at=now(); action_taken:='quality_review';
  end if;
  insert into english.ai_interventions(user_id,trigger,request_type,question_id,concept_id,model,diagnosis,confidence,recommended_action,action_taken,input_tokens,output_tokens,reasoning_tokens,status)
  values(uid,'learner_ai_help','quiz_ai_help',p_question_id,cid,coalesce(nullif(p_model,''),'gpt-5.6-luna'),jsonb_build_object('type',diag,'help',left(coalesce(p_help,''),1500),'metadata',coalesce(p_metadata,'{}'::jsonb)),greatest(0,least(1,coalesce(p_confidence,0))),act,action_taken,p_input_tokens,p_output_tokens,p_reasoning_tokens,'completed');
  return jsonb_build_object('ok',true,'concept_id',cid,'action_taken',action_taken);
end $$;
revoke all on function public.english_apply_ai_help_result_service(uuid,text,text,text,numeric,text,text,integer,integer,integer,jsonb) from public,anon,authenticated;
grant execute on function public.english_apply_ai_help_result_service(uuid,text,text,text,numeric,text,text,integer,integer,integer,jsonb) to service_role;

-- Old user-context AI RPCs remain defined for migration compatibility but are inaccessible.
revoke execute on function public.english_get_ai_help_context(text) from public,anon,authenticated;
revoke execute on function public.english_apply_ai_help_result(text,text,text,numeric,text,text,integer,integer,integer,jsonb) from public,anon,authenticated;

-- Status is learner-readable but never anonymous.
revoke execute on function public.english_get_semantic_status() from public,anon;
grant execute on function public.english_get_semantic_status() to authenticated,service_role;
