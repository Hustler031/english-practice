-- English V2 intent-aware question repair and SSC quality hardening.
-- Improve Question repairs the question on screen; a new question is created only by an explicit related/transfer request.
-- Existing Central Intelligence, bank-first lookup, private generation and canonical grading identity are preserved.

alter table english.question_revision_proposals drop constraint if exists question_revision_proposals_feedback_reason_check;
alter table english.question_revision_proposals
  add constraint question_revision_proposals_feedback_reason_check
  check (feedback_reason in ('options_too_obvious','distractors_unrelated','explanation_weak','custom'));

alter table english.question_revision_proposals drop constraint if exists question_revision_proposals_generation_source_check;
alter table english.question_revision_proposals
  add constraint question_revision_proposals_generation_source_check
  check (generation_source is null or generation_source in ('bank_informed_ai','ai_last_resort'));

alter table english.question_revision_proposals drop constraint if exists english_question_revision_ready_payload_ck;
alter table english.question_revision_proposals
  add constraint english_question_revision_ready_payload_ck
  check (
    status not in ('ready','applied','kept')
    or (
      proposed_payload is not null
      and critic is not null
      and generation_source in ('bank_informed_ai','ai_last_resort')
    )
  );

create or replace function public.english_request_question_revision(
  p_question_id text,
  p_feedback_reason text,
  p_feedback_note text default null
) returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','public','english','auth'
as $$
declare
  uid uuid:=(select auth.uid());
  q english.questions%rowtype;
  v_reason text:=lower(trim(coalesce(p_feedback_reason,'')));
  v_note text:=nullif(trim(coalesce(p_feedback_note,'')),'');
  v_version integer;
  v_base_version integer:=0;
  v_base jsonb;
  v_id uuid;
begin
  if uid is null then raise exception 'authentication required'; end if;
  if v_reason='correct_answer_doubtful' then
    return public.english_request_question_quality_review(p_question_id,v_note);
  end if;
  select * into q from english.questions where question_id=p_question_id and active;
  if not found or not english.question_visible_to_user(uid,p_question_id) then raise exception 'question not found'; end if;
  if upper(coalesce(q.correct,'')) not in ('A','B','C','D') then raise exception 'question is not eligible for revision'; end if;
  if v_reason not in ('options_too_obvious','distractors_unrelated','explanation_weak','custom') then raise exception 'invalid improvement reason'; end if;
  if v_note is not null and char_length(v_note)>600 then raise exception 'feedback note must be at most 600 characters'; end if;
  if v_reason='custom' and coalesce(char_length(v_note),0)<3 then raise exception 'write a short improvement note'; end if;

  perform pg_advisory_xact_lock(hashtextextended(uid::text||'|'||p_question_id,0));
  select r.proposal_version,p.proposed_payload into v_base_version,v_base
  from english.user_question_revisions r
  join english.question_revision_proposals p on p.proposal_id=r.proposal_id
  where r.user_id=uid and r.question_id=p_question_id;

  if v_base is null then
    v_base:=jsonb_build_object(
      'question',q.question,
      'optionA',q.option_a,'optionB',q.option_b,'optionC',q.option_c,'optionD',q.option_d,
      'correctKey',upper(q.correct),'explanation',coalesce(q.explanation,''),
      'questionType',coalesce(q.question_type,''),'difficulty',coalesce(q.difficulty,''),'word',coalesce(q.word,'')
    );
    v_base_version:=0;
  end if;

  update english.question_revision_proposals
  set status='superseded',superseded_at=now(),updated_at=now()
  where user_id=uid and question_id=p_question_id and status in ('queued','processing','ready');

  select coalesce(max(proposal_version),0)+1 into v_version
  from english.question_revision_proposals where user_id=uid and question_id=p_question_id;

  insert into english.question_revision_proposals(
    user_id,question_id,proposal_version,base_version,feedback_reason,feedback_note,status,base_payload,next_attempt_at
  ) values(uid,p_question_id,v_version,v_base_version,v_reason,v_note,'queued',v_base,now())
  returning proposal_id into v_id;

  return jsonb_build_object('ok',true,'kind','revision','proposalId',v_id,'questionId',p_question_id,'version',v_version,'status','queued');
end $$;
revoke all on function public.english_request_question_revision(text,text,text) from public,anon;
grant execute on function public.english_request_question_revision(text,text,text) to authenticated,service_role;

create or replace function public.english_get_question_revision_state(
  p_question_id text,
  p_cache_buster bigint default null
) returns jsonb
language plpgsql
stable
security definer
set search_path to 'pg_catalog','public','english','auth'
as $$
declare
  uid uuid:=(select auth.uid());
  p english.question_revision_proposals%rowtype;
  qr english.question_quality_reviews%rowtype;
  v_active integer;
begin
  if uid is null then raise exception 'authentication required'; end if;
  if not exists(select 1 from english.questions q where q.question_id=p_question_id and english.question_visible_to_user(uid,q.question_id)) then raise exception 'question not found'; end if;
  select proposal_version into v_active from english.user_question_revisions where user_id=uid and question_id=p_question_id;
  select * into p from english.question_revision_proposals where user_id=uid and question_id=p_question_id order by proposal_version desc limit 1;
  select * into qr from english.question_quality_reviews where user_id=uid and question_id=p_question_id order by created_at desc limit 1;
  return jsonb_build_object(
    'ok',true,'activeVersion',v_active,
    'proposal',case when p.proposal_id is null then null else jsonb_strip_nulls(jsonb_build_object(
      'proposalId',p.proposal_id,'questionId',p.question_id,'version',p.proposal_version,'baseVersion',p.base_version,
      'feedbackReason',p.feedback_reason,'feedbackNote',p.feedback_note,'status',p.status,
      'proposed',case when p.status in ('ready','applied','kept') then p.proposed_payload else null end,
      'critic',case when p.status in ('ready','applied','kept') then p.critic else null end,
      'generationSource',p.generation_source,'lastError',case when p.status='failed' then left(coalesce(p.last_error,''),240) else null end,
      'createdAt',p.created_at,'readyAt',p.ready_at,'decidedAt',p.decided_at
    )) end,
    'qualityReview',case when qr.review_id is null then null else jsonb_strip_nulls(jsonb_build_object(
      'reviewId',qr.review_id,'status',qr.status,'verdict',qr.verdict,
      'rationale',case when qr.status='reviewed' then qr.critic->>'rationale' else null end,
      'confidence',case when qr.status='reviewed' then qr.critic->'confidence' else null end,
      'createdAt',qr.created_at,'reviewedAt',qr.reviewed_at
    )) end
  );
end $$;

create or replace function english.question_revision_claim(p_token text,p_limit integer default 1)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','english'
as $$
declare outv jsonb;
begin
  if not english.context_worker_authorized(p_token) then raise exception 'context worker unauthorized'; end if;
  update english.question_revision_proposals
  set status='queued',next_attempt_at=now(),last_error='stale background processing recovered',updated_at=now()
  where status='processing' and claimed_at<now()-interval '5 minutes' and attempts<3;
  update english.question_revision_proposals
  set status='failed',last_error=coalesce(last_error,'background processing exhausted retries'),updated_at=now()
  where status='processing' and claimed_at<now()-interval '5 minutes' and attempts>=3;

  with pick as(
    select proposal_id from english.question_revision_proposals
    where status='queued' and attempts<3 and (next_attempt_at is null or next_attempt_at<=now())
    order by created_at,proposal_id for update skip locked limit greatest(1,least(2,coalesce(p_limit,1)))
  ), upd as(
    update english.question_revision_proposals p
    set status='processing',attempts=p.attempts+1,claimed_at=now(),last_error=null,updated_at=now()
    from pick where p.proposal_id=pick.proposal_id returning p.*
  ), payload as(
    select u.*,q.correct,m.concept_id,c.name concept_name,c.skill_family,c.description concept_description,
      coalesce(bank.refs,'[]'::jsonb) bank_references,to_jsonb(qm) learner_quality,to_jsonb(rs) strategy_history
    from upd u
    join english.questions q on q.question_id=u.question_id
    left join english.question_concept_mappings m on m.question_id=u.question_id
    left join english.concepts c on c.concept_id=m.concept_id
    left join english.question_quality_metrics qm on qm.user_id=u.user_id and qm.question_id=u.question_id
    left join english.revision_strategy_stats rs on rs.user_id=u.user_id and rs.feedback_reason=u.feedback_reason
    left join lateral(
      select jsonb_agg(x.payload order by x.rank_key,x.question_id) refs from(
        select q2.question_id,
          case when coalesce(qm2.too_easy,false) then 2 else 1 end rank_key,
          jsonb_build_object(
            'questionId',q2.question_id,'question',q2.question,
            'optionA',q2.option_a,'optionB',q2.option_b,'optionC',q2.option_c,'optionD',q2.option_d,
            'correctKey',upper(q2.correct),'explanation',coalesce(q2.explanation,''),
            'questionType',coalesce(q2.question_type,''),'difficulty',coalesce(q2.difficulty,''),'word',coalesce(q2.word,''),
            'observedDifficulty',qm2.observed_difficulty,'tooEasy',coalesce(qm2.too_easy,false)
          ) payload
        from english.questions q2
        join english.question_concept_mappings m2 on m2.question_id=q2.question_id
        left join english.question_quality_metrics qm2 on qm2.user_id=u.user_id and qm2.question_id=q2.question_id
        where m.concept_id is not null and m2.concept_id=m.concept_id and q2.question_id<>u.question_id and q2.active
          and english.question_visible_to_user(u.user_id,q2.question_id)
          and upper(coalesce(q2.correct,'')) in ('A','B','C','D')
        order by case when coalesce(qm2.too_easy,false) then 2 else 1 end,
          case when lower(coalesce(q2.difficulty,''))=lower(coalesce(q.difficulty,'')) then 0 else 1 end,q2.question_id
        limit 3
      ) x
    ) bank on true
  )
  select jsonb_build_object('items',coalesce(jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
    'proposalId',proposal_id,'userId',user_id,'questionId',question_id,'version',proposal_version,'baseVersion',base_version,
    'feedbackReason',feedback_reason,'feedbackNote',feedback_note,'base',base_payload,
    'requiredCorrectKey',upper(correct),'conceptId',concept_id,'conceptName',concept_name,'skillFamily',skill_family,
    'conceptDescription',concept_description,'bankReferences',bank_references,'learnerQuality',learner_quality,'strategyHistory',strategy_history,
    'intentRules',jsonb_build_object(
      'preserveStem',feedback_reason in ('options_too_obvious','distractors_unrelated','explanation_weak'),
      'preserveAllOptions',feedback_reason='explanation_weak',
      'preserveCorrectOption',feedback_reason in ('options_too_obvious','distractors_unrelated','explanation_weak'),
      'newQuestionAllowed',false,
      'sscToughnessRequired',feedback_reason<>'explanation_weak'
    )
  )) order by created_at),'[]'::jsonb)) into outv from payload;
  return coalesce(outv,jsonb_build_object('items','[]'::jsonb));
end $$;

create or replace function english.apply_question_revision_result(
  p_token text,p_proposal_id uuid,p_item jsonb,p_critic jsonb,p_source text,
  p_model text default 'gpt-5.6-luna',p_usage jsonb default '{}'::jsonb
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
  if r.status='ready' then return jsonb_build_object('ok',true,'alreadyReady',true); end if;
  if r.status<>'processing' then raise exception 'revision proposal is not claimed'; end if;
  select * into q from english.questions where question_id=r.question_id;
  if not found then raise exception 'base question not found'; end if;

  v_key:=upper(trim(coalesce(p_item->>'correctKey','')));
  if v_key<>upper(coalesce(q.correct,'')) or v_key<>upper(coalesce(r.base_payload->>'correctKey','')) then raise exception 'revision changed the canonical correct key'; end if;
  if nullif(trim(coalesce(p_item->>'question','')),'') is null or char_length(trim(p_item->>'question'))<8 then raise exception 'revision question is incomplete'; end if;
  if nullif(trim(coalesce(p_item->>'explanation','')),'') is null or char_length(trim(p_item->>'explanation'))<20 then raise exception 'revision explanation is incomplete'; end if;
  if nullif(trim(coalesce(p_item->>'optionA','')),'') is null or nullif(trim(coalesce(p_item->>'optionB','')),'') is null
     or nullif(trim(coalesce(p_item->>'optionC','')),'') is null or nullif(trim(coalesce(p_item->>'optionD','')),'') is null then raise exception 'revision options are incomplete'; end if;
  if lower(trim(p_item->>'optionA')) in (lower(trim(p_item->>'optionB')),lower(trim(p_item->>'optionC')),lower(trim(p_item->>'optionD')))
     or lower(trim(p_item->>'optionB')) in (lower(trim(p_item->>'optionC')),lower(trim(p_item->>'optionD')))
     or lower(trim(p_item->>'optionC'))=lower(trim(p_item->>'optionD')) then raise exception 'revision options are not unique'; end if;

  v_score:=coalesce((p_critic->>'qualityScore')::numeric,0);
  v_closeness:=coalesce((p_critic->>'distractorCloseness')::numeric,0);
  v_traps:=coalesce((p_critic->>'realisticTrapCount')::integer,0);
  if not coalesce((p_critic->>'exactlyOneCorrect')::boolean,false)
     or not coalesce((p_critic->>'explanationMatches')::boolean,false)
     or not coalesce((p_critic->>'noStaleExplanation')::boolean,false)
     or not coalesce((p_critic->>'noAmbiguity')::boolean,false)
     or not coalesce((p_critic->>'faithfulConcept')::boolean,false)
     or not coalesce((p_critic->>'fairDifficulty')::boolean,false)
     or v_score<0.85 then raise exception 'revision critic rejected the proposal'; end if;

  if r.feedback_reason<>'explanation_weak' and (
       not coalesce((p_critic->>'closeDistractors')::boolean,false)
       or not coalesce((p_critic->>'notObviouslyEliminable')::boolean,false)
       or not coalesce((p_critic->>'sscDifficultyFit')::boolean,false)
       or coalesce((p_critic->>'obviousElimination')::boolean,true)
       or coalesce((p_critic->>'difficultyArtificial')::boolean,true)
       or v_closeness<0.70 or v_traps<2
     ) then raise exception 'revision failed SSC toughness gate'; end if;

  if lower(regexp_replace(trim(p_item->>'explanation'),'[[:space:]]+',' ','g'))=
     lower(regexp_replace(trim(coalesce(r.base_payload->>'explanation','')),'[[:space:]]+',' ','g')) then raise exception 'revision explanation is stale'; end if;

  v_base_stem:=lower(regexp_replace(trim(coalesce(r.base_payload->>'question','')),'[[:space:]]+',' ','g'));
  v_new_stem:=lower(regexp_replace(trim(coalesce(p_item->>'question','')),'[[:space:]]+',' ','g'));
  if r.feedback_reason in ('options_too_obvious','distractors_unrelated','explanation_weak') and v_new_stem<>v_base_stem then
    raise exception 'question stem changed during a repair-only revision';
  end if;

  v_base_correct:=lower(regexp_replace(trim(coalesce(r.base_payload->>('option'||v_key),'')),'[[:space:]]+',' ','g'));
  v_new_correct:=lower(regexp_replace(trim(coalesce(p_item->>('option'||v_key),'')),'[[:space:]]+',' ','g'));
  if r.feedback_reason in ('options_too_obvious','distractors_unrelated','explanation_weak') and v_new_correct<>v_base_correct then
    raise exception 'correct option changed during a repair-only revision';
  end if;

  foreach k in array array['A','B','C','D'] loop
    v_new:=lower(regexp_replace(trim(coalesce(p_item->>('option'||k),'')),'[[:space:]]+',' ','g'));
    v_old:=lower(regexp_replace(trim(coalesce(r.base_payload->>('option'||k),'')),'[[:space:]]+',' ','g'));
    if v_new<>v_old then v_changed:=v_changed+1; end if;
  end loop;
  if r.feedback_reason in ('options_too_obvious','distractors_unrelated') and v_changed<2 then raise exception 'revision did not materially improve the distractors'; end if;
  if r.feedback_reason='explanation_weak' and v_changed<>0 then raise exception 'explanation-only revision changed options'; end if;

  if p_source not in ('bank_informed_ai','ai_last_resort') then raise exception 'invalid revision generation source'; end if;
  v_payload:=jsonb_build_object(
    'question',trim(p_item->>'question'),'optionA',trim(p_item->>'optionA'),'optionB',trim(p_item->>'optionB'),
    'optionC',trim(p_item->>'optionC'),'optionD',trim(p_item->>'optionD'),'correctKey',v_key,'explanation',trim(p_item->>'explanation')
  );
  update english.question_revision_proposals set status='ready',proposed_payload=v_payload,critic=p_critic,generation_source=p_source,
    ai_model=p_model,ai_usage=coalesce(p_usage,'{}'::jsonb),ready_at=now(),last_error=null,updated_at=now()
  where proposal_id=p_proposal_id and status='processing';
  insert into english.revision_strategy_stats(user_id,feedback_reason,ready_count,updated_at)
  values(r.user_id,r.feedback_reason,1,now()) on conflict(user_id,feedback_reason) do update set
    ready_count=english.revision_strategy_stats.ready_count+1,updated_at=now();
  return jsonb_build_object('ok',true,'proposalId',p_proposal_id,'status','ready','qualityScore',v_score,'source',p_source);
end $$;

create or replace function public.english_apply_question_revision_result(
  p_token text,p_proposal_id uuid,p_item jsonb,p_critic jsonb,p_source text,p_model text default 'gpt-5.6-luna',p_usage jsonb default '{}'::jsonb
) returns jsonb language sql security definer set search_path to 'pg_catalog','public','english'
as $$ select english.apply_question_revision_result(p_token,p_proposal_id,p_item,p_critic,p_source,p_model,p_usage); $$;
revoke all on function public.english_apply_question_revision_result(text,uuid,jsonb,jsonb,text,text,jsonb) from public,anon,authenticated;
grant execute on function public.english_apply_question_revision_result(text,uuid,jsonb,jsonb,text,text,jsonb) to service_role;

create or replace function english.fail_question_revision(p_token text,p_proposal_id uuid,p_error text)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','english'
as $$
declare r english.question_revision_proposals%rowtype; v_final boolean:=false;
begin
  if not english.context_worker_authorized(p_token) then raise exception 'context worker unauthorized'; end if;
  select * into r from english.question_revision_proposals where proposal_id=p_proposal_id for update;
  if not found then return jsonb_build_object('ok',false,'missing',true); end if;
  if r.status='superseded' then return jsonb_build_object('ok',true,'stale',true); end if;
  if r.status<>'processing' then return jsonb_build_object('ok',true,'ignored',true,'status',r.status); end if;
  v_final:=r.attempts>=3;
  update english.question_revision_proposals set status=case when v_final then 'failed' else 'queued' end,
    next_attempt_at=case when v_final then null else now()+case when attempts=1 then interval '2 minutes' else interval '10 minutes' end end,
    last_error=left(coalesce(nullif(trim(p_error),''),'background revision failed'),800),updated_at=now() where proposal_id=p_proposal_id;
  if v_final then
    insert into english.revision_strategy_stats(user_id,feedback_reason,failed_count,updated_at)
    values(r.user_id,r.feedback_reason,1,now()) on conflict(user_id,feedback_reason) do update set
      failed_count=english.revision_strategy_stats.failed_count+1,updated_at=now();
  end if;
  return jsonb_build_object('ok',true,'retry',not v_final,'attempts',r.attempts);
end $$;

create or replace function public.english_use_question_revision(p_proposal_id uuid)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','public','english','auth'
as $$
declare uid uuid:=(select auth.uid()); p english.question_revision_proposals%rowtype;
begin
  if uid is null then raise exception 'authentication required'; end if;
  select * into p from english.question_revision_proposals where proposal_id=p_proposal_id and user_id=uid for update;
  if not found then raise exception 'revision proposal not found'; end if;
  if p.status='applied' and exists(select 1 from english.user_question_revisions r where r.user_id=uid and r.question_id=p.question_id and r.proposal_id=p.proposal_id) then
    return jsonb_build_object('ok',true,'alreadyApplied',true,'questionId',p.question_id,'version',p.proposal_version,'payload',p.proposed_payload);
  end if;
  if p.status<>'ready' or p.proposed_payload is null then raise exception 'revision proposal is not ready'; end if;
  if exists(select 1 from english.question_revision_proposals newer where newer.user_id=uid and newer.question_id=p.question_id and newer.proposal_version>p.proposal_version and newer.status<>'superseded') then raise exception 'a newer revision proposal exists'; end if;
  insert into english.user_question_revisions(user_id,question_id,proposal_id,proposal_version,applied_at)
  values(uid,p.question_id,p.proposal_id,p.proposal_version,now())
  on conflict(user_id,question_id) do update set proposal_id=excluded.proposal_id,proposal_version=excluded.proposal_version,applied_at=now();
  update english.question_revision_proposals set status='applied',decided_at=now(),updated_at=now() where proposal_id=p.proposal_id;
  insert into english.revision_strategy_stats(user_id,feedback_reason,applied_count,updated_at)
  values(uid,p.feedback_reason,1,now()) on conflict(user_id,feedback_reason) do update set
    applied_count=english.revision_strategy_stats.applied_count+1,updated_at=now();
  return jsonb_build_object('ok',true,'questionId',p.question_id,'version',p.proposal_version,'status','applied','payload',p.proposed_payload);
end $$;

create or replace function public.english_keep_question_revision(p_proposal_id uuid)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','public','english','auth'
as $$
declare uid uuid:=(select auth.uid()); p english.question_revision_proposals%rowtype;
begin
  if uid is null then raise exception 'authentication required'; end if;
  select * into p from english.question_revision_proposals where proposal_id=p_proposal_id and user_id=uid for update;
  if not found then raise exception 'revision proposal not found'; end if;
  if p.status='kept' then return jsonb_build_object('ok',true,'alreadyKept',true,'questionId',p.question_id,'version',p.proposal_version); end if;
  if p.status<>'ready' then raise exception 'revision proposal is not ready'; end if;
  update english.question_revision_proposals set status='kept',decided_at=now(),updated_at=now() where proposal_id=p.proposal_id;
  insert into english.revision_strategy_stats(user_id,feedback_reason,kept_count,updated_at)
  values(uid,p.feedback_reason,1,now()) on conflict(user_id,feedback_reason) do update set
    kept_count=english.revision_strategy_stats.kept_count+1,updated_at=now();
  return jsonb_build_object('ok',true,'questionId',p.question_id,'version',p.proposal_version,'status','kept');
end $$;

create or replace function english.text_token_jaccard(p_a text,p_b text)
returns numeric
language sql
immutable
set search_path to 'pg_catalog'
as $$
with a as(
  select distinct t from regexp_split_to_table(lower(regexp_replace(coalesce(p_a,''),'[^a-z0-9]+',' ','g')),'[[:space:]]+') t where char_length(t)>2
), b as(
  select distinct t from regexp_split_to_table(lower(regexp_replace(coalesce(p_b,''),'[^a-z0-9]+',' ','g')),'[[:space:]]+') t where char_length(t)>2
), i as(select count(*)::numeric n from a join b using(t)), u as(select count(*)::numeric n from (select t from a union select t from b) x)
select case when u.n=0 then 0 else round(i.n/u.n,4) end from i,u;
$$;

create or replace function english.transfer_claim(p_token text,p_limit integer default 1)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','english'
as $$
declare outv jsonb;
begin
  if not english.context_worker_authorized(p_token) then raise exception 'context worker unauthorized'; end if;
  update english.targeted_transfer_jobs set status='queued',next_attempt_at=now(),last_error='stale generation recovered',updated_at=now()
  where status='processing' and updated_at<now()-interval '5 minutes' and attempts<3;
  with pick as(
    select job_id from english.targeted_transfer_jobs
    where status='queued' and attempts<3 and (next_attempt_at is null or next_attempt_at<=now())
    order by case when coalesce((metadata->>'explicitRelatedPractice')::boolean,false) then 0 else 1 end,created_at,job_id
    for update skip locked limit greatest(1,least(2,coalesce(p_limit,1)))
  ), upd as(
    update english.targeted_transfer_jobs j set status='processing',attempts=j.attempts+1,updated_at=now(),last_error=null
    from pick p where j.job_id=p.job_id returning j.*
  ), payload as(
    select u.*,c.name concept_name,c.description concept_description,c.skill_family,c.exam_relevance,
      q.topic,q.word,q.question,q.option_a,q.option_b,q.option_c,q.option_d,q.correct,q.explanation,q.question_type,q.subtopic,
      coalesce(n.note,'') learner_note,to_jsonb(qm) source_quality,
      coalesce(u.metadata->'confusableTerms',english.confusable_terms_for_concept(u.concept_id,8)) confusable_terms
    from upd u join english.concepts c on c.concept_id=u.concept_id join english.questions q on q.question_id=u.source_question_id
    left join english.learner_context_notes n on n.note_id=u.source_note_id
    left join english.question_quality_metrics qm on qm.user_id=u.user_id and qm.question_id=u.source_question_id
  )
  select jsonb_build_object('items',coalesce(jsonb_agg(jsonb_build_object(
    'jobId',job_id,'userId',user_id,'conceptId',concept_id,'conceptName',concept_name,'conceptDescription',concept_description,
    'skillFamily',skill_family,'examRelevance',exam_relevance,'sourceQuestionId',source_question_id,'sourceNoteId',source_note_id,
    'relatedTerm',related_term,'reason',reason,'learnerNote',learner_note,'jobMetadata',metadata,
    'explicitRelatedPractice',coalesce((metadata->>'explicitRelatedPractice')::boolean,false),'confusableTerms',confusable_terms,'sourceQuality',source_quality,
    'sourceQuestion',jsonb_build_object('topic',topic,'word',word,'question',question,'options',jsonb_build_array(option_a,option_b,option_c,option_d),
      'correctKey',correct,'explanation',explanation,'questionType',question_type,'subtopic',subtopic)
  ) order by created_at),'[]'::jsonb)) into outv from payload;
  return coalesce(outv,jsonb_build_object('items','[]'::jsonb));
end $$;

create or replace function english.apply_generated_transfer(p_token text,p_job_id uuid,p_item jsonb,p_model text default 'gpt-5.6-luna',p_usage jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','english'
as $$
declare
  j english.targeted_transfer_jobs%rowtype; src english.questions%rowtype; qid text; fam text; skill text;
  qa text:=trim(coalesce(p_item->>'optionA','')); qb text:=trim(coalesce(p_item->>'optionB',''));
  qc text:=trim(coalesce(p_item->>'optionC','')); qd text:=trim(coalesce(p_item->>'optionD',''));
  ckey text:=upper(trim(coalesce(p_item->>'correctKey',''))); qtext text:=trim(coalesce(p_item->>'question',''));
  quality numeric:=coalesce((p_item->>'qualityScore')::numeric,0); closeness numeric:=coalesce((p_item->>'distractorCloseness')::numeric,0);
  novelty numeric:=coalesce((p_item->>'semanticNoveltyScore')::numeric,0); traps integer:=coalesce((p_item->>'realisticTrapCount')::integer,0);
  ambiguous boolean:=coalesce((p_item->>'ambiguous')::boolean,true); related jsonb:=coalesce(p_item->'relatedTerms','[]'::jsonb);
  v_intent text; v_overlap integer;
begin
  if not english.context_worker_authorized(p_token) then raise exception 'context worker unauthorized'; end if;
  select * into j from english.targeted_transfer_jobs where job_id=p_job_id for update;
  if not found then raise exception 'transfer job not found'; end if;
  if j.status='done' then return jsonb_build_object('ok',true,'alreadyDone',true,'questionId',j.generated_question_id); end if;
  if j.status<>'processing' then raise exception 'transfer job is not claimed'; end if;
  if char_length(qtext)<12 or char_length(qtext)>600 then raise exception 'invalid generated question length'; end if;
  if ckey not in ('A','B','C','D') then raise exception 'invalid generated correct key'; end if;
  if least(char_length(qa),char_length(qb),char_length(qc),char_length(qd))<1 then raise exception 'generated option missing'; end if;
  if (select count(distinct lower(v)) from unnest(array[qa,qb,qc,qd]) v)<>4 then raise exception 'generated options are not unique'; end if;
  if ambiguous or quality<0.85
     or not coalesce((p_item->>'exactlyOneCorrect')::boolean,false)
     or not coalesce((p_item->>'closeDistractors')::boolean,false)
     or not coalesce((p_item->>'notObviouslyEliminable')::boolean,false)
     or not coalesce((p_item->>'sscDifficultyFit')::boolean,false)
     or not coalesce((p_item->>'conceptFidelity')::boolean,false)
     or not coalesce((p_item->>'freshContext')::boolean,false)
     or coalesce((p_item->>'obviousElimination')::boolean,true)
     or closeness<0.70 or novelty<0.65 or traps<2 then raise exception 'generated transfer failed SSC quality gate'; end if;
  if exists(select 1 from english.questions where lower(trim(question))=lower(qtext)) then raise exception 'generated transfer duplicates existing question'; end if;
  if exists(
    select 1 from english.questions q2 join english.question_concept_mappings m2 on m2.question_id=q2.question_id
    where q2.active and m2.concept_id=j.concept_id and english.text_token_jaccard(q2.question,qtext)>=0.80
  ) then raise exception 'generated transfer is a near-duplicate of existing concept practice'; end if;

  if coalesce((j.metadata->>'explicitRelatedPractice')::boolean,false) and jsonb_array_length(related)<3 then
    raise exception 'explicit related practice lacks a real confusable cluster';
  end if;

  select * into src from english.questions where question_id=j.source_question_id;
  select m.family_id,c.skill_family into fam,skill from english.question_concept_mappings m join english.concepts c on c.concept_id=m.concept_id where m.question_id=j.source_question_id;
  qid:='AIT_'||upper(substr(replace(j.job_id::text,'-',''),1,16));
  insert into english.questions(
    question_id,topic,word,question,option_a,option_b,option_c,option_d,correct,explanation,subtopic,question_type,
    source_file,source_page,concept_id,difficulty,source_id,learning_status,content_status,exam_relevance,related_words,review_notes,active
  ) values(
    qid,coalesce(src.topic,skill),nullif(trim(coalesce(p_item->>'word','')),''),qtext,qa,qb,qc,qd,ckey,
    trim(coalesce(p_item->>'explanation','Fresh transfer validation.')),src.subtopic,
    coalesce(nullif(trim(p_item->>'questionType'),''),'Transfer / Discrimination'),'AI Targeted Transfer',null,j.concept_id,
    coalesce(nullif(trim(p_item->>'difficulty'),''),'Hard'),'AI_TARGETED_'||upper(substr(replace(j.job_id::text,'-',''),1,12)),
    'New','Active',coalesce(src.exam_relevance,'high'),array_to_string(array(select jsonb_array_elements_text(related)),', '),
    'Background Luna generated; independent SSC critic approved; quality='||quality::text||'; closeness='||closeness::text,true
  );
  insert into english.question_origins(question_id,origin_kind,origin_ref,owner_user_id)
  values(qid,'targeted_generated',j.job_id::text,j.user_id)
  on conflict(question_id) do update set origin_kind=excluded.origin_kind,origin_ref=excluded.origin_ref,owner_user_id=excluded.owner_user_id;
  insert into english.question_concept_mappings(question_id,concept_id,family_id,mapping_confidence,mapping_method,model,review_status,relation_type,updated_at)
  values(qid,j.concept_id,fam,1,'luna_validated_transfer',p_model,'verified','variant',now())
  on conflict(question_id) do update set concept_id=excluded.concept_id,family_id=excluded.family_id,mapping_confidence=1,
    mapping_method=excluded.mapping_method,model=excluded.model,review_status='verified',relation_type='variant',updated_at=now();

  v_intent:=case when coalesce((j.metadata->>'explicitRelatedPractice')::boolean,false) then 'explicit_related_practice' else 'targeted_transfer' end;
  insert into english.question_generation_provenance(question_id,owner_user_id,source_question_id,concept_id,intent,generation_source,critic,related_terms,model,usage)
  values(qid,j.user_id,j.source_question_id,j.concept_id,v_intent,'ai_last_resort',p_item,related,p_model,coalesce(p_usage,'{}'::jsonb))
  on conflict(question_id) do update set critic=excluded.critic,related_terms=excluded.related_terms,model=excluded.model,usage=excluded.usage;
  if jsonb_typeof(related)='array' and jsonb_array_length(related)>0 then perform english.upsert_confusable_terms(p_token,j.concept_id,related,'ai_validated'); end if;

  perform english.route_to_targeted(j.user_id,qid,case when v_intent='explicit_related_practice' then 'Related Practice' else 'AI Transfer' end,
    case when v_intent='explicit_related_practice' then 'Learner explicitly requested a fresh confusable-word practice item' else 'Fresh validated transfer generated because the existing bank lacked an alternate item' end);
  update english.learning_route_state set metadata=coalesce(metadata,'{}'::jsonb)||jsonb_build_object(
    'targeted_kind','transfer_check','generated_for_question',j.source_question_id,'transfer_job_id',j.job_id,'ai_model',p_model,
    'generation_intent',v_intent,'ssc_difficulty_fit',true,'distractor_closeness',closeness),updated_at=now()
  where user_id=j.user_id and question_id=qid;
  update english.targeted_transfer_jobs set status='done',generated_question_id=qid,processed_at=now(),updated_at=now(),last_error=null,
    metadata=coalesce(metadata,'{}'::jsonb)||jsonb_build_object('model',p_model,'qualityScore',quality,'distractorCloseness',closeness,
      'semanticNoveltyScore',novelty,'realisticTrapCount',traps,'usage',coalesce(p_usage,'{}'::jsonb)) where job_id=j.job_id;
  perform english.log_learning_activity(j.user_id,'transfer_generated',case when v_intent='explicit_related_practice' then 'Related practice prepared' else 'Fresh transfer prepared' end,
    case when v_intent='explicit_related_practice' then 'A validated SSC-level confusable-word question was prepared.' else 'Existing bank had no alternate item · a validated transfer question was added to Targeted.' end,
    qid,j.concept_id,j.source_note_id,'targeted',jsonb_build_object('sourceQuestionId',j.source_question_id,'qualityScore',quality,'model',p_model,'intent',v_intent),now());
  return jsonb_build_object('ok',true,'questionId',qid,'qualityScore',quality,'distractorCloseness',closeness,'intent',v_intent);
exception when others then
  if j.job_id is not null then
    update english.targeted_transfer_jobs set status=case when attempts>=3 then 'failed' else 'queued' end,
      next_attempt_at=case when attempts>=3 then null else now()+make_interval(mins=>least(30,greatest(1,attempts)*5)) end,
      last_error=left(sqlerrm,1000),updated_at=now() where job_id=j.job_id;
  end if;
  raise;
end $$;

create or replace function public.english_apply_generated_transfer(p_token text,p_job_id uuid,p_item jsonb,p_model text default 'gpt-5.6-luna',p_usage jsonb default '{}'::jsonb)
returns jsonb language sql security definer set search_path to 'pg_catalog','public','english'
as $$ select english.apply_generated_transfer(p_token,p_job_id,p_item,p_model,p_usage); $$;

create or replace function english.targeted_exit_evaluation(p_user_id uuid,p_concept_id text,p_targeted_at timestamptz)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'pg_catalog','english'
as $$
declare v_correct_q integer:=0; v_wrong integer:=0; v_first timestamptz; v_last timestamptz; v_confusions integer:=0; v_guesses integer:=0; v_gap numeric:=0;
begin
  select count(distinct a.question_id) filter(where a.correct)::int,count(*) filter(where not a.correct)::int,
    min(a.attempted_at) filter(where a.correct),max(a.attempted_at) filter(where a.correct)
  into v_correct_q,v_wrong,v_first,v_last from english.attempts a join english.question_concept_mappings m on m.question_id=a.question_id
  where a.user_id=p_user_id and m.concept_id=p_concept_id and a.attempted_at>=coalesce(p_targeted_at,'epoch'::timestamptz);
  select count(*)::int into v_confusions from english.learner_confusions c where c.user_id=p_user_id and c.status<>'resolved'
    and (c.primary_concept_id=p_concept_id or c.related_concept_id=p_concept_id);
  select count(*)::int into v_guesses from english.learner_confidence_signals g join english.question_concept_mappings m on m.question_id=g.question_id
    where g.user_id=p_user_id and m.concept_id=p_concept_id and g.signal='guessed' and g.resolved_at is null;
  if v_first is not null and v_last is not null then v_gap:=extract(epoch from (v_last-v_first))/3600.0; end if;
  return jsonb_build_object('ready',coalesce(v_wrong,0)=0 and coalesce(v_correct_q,0)>=2 and v_gap>=20 and v_confusions=0 and v_guesses=0,
    'distinctCorrectQuestions',coalesce(v_correct_q,0),'wrongSinceTargeted',coalesce(v_wrong,0),'spacingHours',round(coalesce(v_gap,0)::numeric,2),
    'openConfusions',v_confusions,'openGuesses',v_guesses,'requiredDistinctQuestions',2,'requiredSpacingHours',20);
end $$;

create or replace function public.english_get_targeted_batch(p_count integer default 15,p_kind text default null,p_confusion_id uuid default null)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'pg_catalog','public','english','auth'
as $$
declare uid uuid:=auth.uid(); n int:=greatest(1,least(30,coalesce(p_count,15))); k text:=lower(nullif(trim(coalesce(p_kind,'')),'')); session_nonce text:=nullif(current_setting('english.targeted_session_nonce',true),''); outv jsonb;
begin
  if uid is null then raise exception 'Authentication required'; end if;
  with focus as(
    select * from english.learner_confusions where user_id=uid and p_confusion_id is not null and confusion_id=p_confusion_id
  ), routed as(
    select r.question_id,m.concept_id,r.metadata,r.origins,r.last_route_reason,r.updated_at,ce.coverage_state,ce.confidence_score,ce.next_review,
      english.targeted_route_kind(r.metadata,r.origins) kind,coalesce(qm.too_easy,false) question_too_easy,coalesce(qm.observed_difficulty,0.5) question_observed_difficulty
    from english.learning_route_state r join english.questions q on q.question_id=r.question_id and q.active and english.question_visible_to_user(uid,q.question_id)
    left join english.question_concept_mappings m on m.question_id=r.question_id left join english.concept_evidence ce on ce.user_id=uid and ce.concept_id=m.concept_id
    left join english.question_quality_metrics qm on qm.user_id=uid and qm.question_id=r.question_id
    where r.user_id=uid and r.route='targeted'
  ), filtered as(
    select x.* from routed x where (p_confusion_id is null or exists(select 1 from focus f where x.concept_id=f.primary_concept_id or x.concept_id=f.related_concept_id or x.question_id=f.primary_question_id or x.question_id=f.related_question_id)) and (k is null or x.kind=k)
  ), delivery as(
    select f.*,coalesce(alt.question_id,f.question_id) delivery_question_id,row_number() over(partition by coalesce(f.concept_id,f.question_id)
      order by case f.kind when 'confusion' then 1 when 'transfer_check' then 2 when 'retention_check' then 3 else 4 end,f.updated_at desc) concept_pick
    from filtered f left join lateral(
      select q2.question_id from english.questions q2 join english.question_concept_mappings m2 on m2.question_id=q2.question_id
      left join english.question_state s2 on s2.user_id=uid and s2.question_id=q2.question_id
      left join english.question_quality_metrics qm2 on qm2.user_id=uid and qm2.question_id=q2.question_id
      where f.kind in('transfer_check','confusion') and not (f.kind='transfer_check' and ('AI Transfer'=any(coalesce(f.origins,'{}'::text[]))
        or exists(select 1 from english.question_origins qo where qo.question_id=f.question_id and qo.origin_kind='targeted_generated' and qo.owner_user_id=uid)))
        and f.concept_id is not null and m2.concept_id=f.concept_id and q2.question_id<>f.question_id and q2.active
        and english.question_visible_to_user(uid,q2.question_id) and not coalesce(s2.mastered,false)
      order by coalesce(qm2.too_easy,false),coalesce(qm2.observed_difficulty,0.5) desc,coalesce(s2.last_attempt,'epoch'::timestamptz),
        case when session_nonce is null then q2.question_id else md5(session_nonce||'|'||q2.question_id) end limit 1
    ) alt on true
  ), chosen as(
    select * from delivery where concept_pick=1 order by
      case when kind='confusion' then 1 when kind='transfer_check' then 2 when kind='retention_check' and (next_review is null or next_review<=now()) then 3 when kind='need_learning' then 4 else 5 end,
      case when kind='need_learning' and question_too_easy then 1 else 0 end,question_observed_difficulty desc,
      case when session_nonce is not null then md5(session_nonce||'|'||coalesce(concept_id,question_id)) else '' end,coalesce(next_review,'epoch'::timestamptz),updated_at desc limit n
  )
  select coalesce(jsonb_agg(english.question_payload(uid,c.delivery_question_id)||jsonb_build_object(
    'learningRoute','targeted','targetedKind',c.kind,'targetedReason',c.last_route_reason,'sourceQuestionId',c.question_id,'conceptId',c.concept_id,
    'conceptCoverage',coalesce(c.coverage_state,'unseen'),'conceptConfidence',coalesce(c.confidence_score,0),'conceptNextReview',c.next_review,
    'observedDifficulty',c.question_observed_difficulty,'questionTooEasy',c.question_too_easy
  ) order by case when c.kind='confusion' then 1 when c.kind='transfer_check' then 2 when c.kind='retention_check' and (c.next_review is null or c.next_review<=now()) then 3 when c.kind='need_learning' then 4 else 5 end,
    case when c.kind='need_learning' and c.question_too_easy then 1 else 0 end,c.question_observed_difficulty desc,c.updated_at desc),'[]'::jsonb) into outv from chosen c;
  return outv;
end $$;
