-- English V2 question revision proposals.
-- User feedback is queued, bank-first, background-only, critic-gated, previewed, and explicitly applied.
-- Canonical question ids never change: accepted revisions are user-owned presentation overlays so attempts/mastery stay intact.

create table if not exists english.question_revision_proposals (
  proposal_id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  question_id text not null references english.questions(question_id) on delete cascade,
  proposal_version integer not null check (proposal_version > 0),
  base_version integer not null default 0 check (base_version >= 0),
  feedback_reason text not null check (feedback_reason in ('options_too_obvious','distractors_unrelated','explanation_weak','correct_answer_doubtful','custom')),
  feedback_note text,
  status text not null default 'queued' check (status in ('queued','processing','ready','applied','kept','failed','superseded')),
  base_payload jsonb not null,
  proposed_payload jsonb,
  critic jsonb,
  generation_source text check (generation_source is null or generation_source in ('bank_first','ai_last_resort')),
  ai_model text,
  ai_usage jsonb not null default '{}'::jsonb,
  attempts integer not null default 0 check (attempts between 0 and 3),
  claimed_at timestamptz,
  next_attempt_at timestamptz,
  last_error text,
  ready_at timestamptz,
  decided_at timestamptz,
  superseded_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(user_id, question_id, proposal_version)
);

create table if not exists english.user_question_revisions (
  user_id uuid not null references auth.users(id) on delete cascade,
  question_id text not null references english.questions(question_id) on delete cascade,
  proposal_id uuid not null references english.question_revision_proposals(proposal_id) on delete restrict,
  proposal_version integer not null check (proposal_version > 0),
  applied_at timestamptz not null default now(),
  primary key(user_id, question_id)
);

create index if not exists english_revision_jobs_idx
  on english.question_revision_proposals(status,next_attempt_at,created_at)
  where status in ('queued','processing');
create index if not exists english_revision_user_question_idx
  on english.question_revision_proposals(user_id,question_id,proposal_version desc);

alter table english.question_revision_proposals enable row level security;
alter table english.user_question_revisions enable row level security;
revoke all on english.question_revision_proposals from public,anon,authenticated;
revoke all on english.user_question_revisions from public,anon,authenticated;
grant select,insert,update,delete on english.question_revision_proposals to service_role;
grant select,insert,update,delete on english.user_question_revisions to service_role;

drop policy if exists english_revision_proposals_own_read on english.question_revision_proposals;
create policy english_revision_proposals_own_read on english.question_revision_proposals
  for select to authenticated using (user_id=(select auth.uid()));
drop policy if exists english_user_revisions_own_read on english.user_question_revisions;
create policy english_user_revisions_own_read on english.user_question_revisions
  for select to authenticated using (user_id=(select auth.uid()));

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
  select * into q from english.questions where question_id=p_question_id and active;
  if not found or not english.question_visible_to_user(uid,p_question_id) then raise exception 'question not found'; end if;
  if upper(coalesce(q.correct,'')) not in ('A','B','C','D') then raise exception 'question is not eligible for revision'; end if;
  if v_reason not in ('options_too_obvious','distractors_unrelated','explanation_weak','correct_answer_doubtful','custom') then
    raise exception 'invalid improvement reason';
  end if;
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

  return jsonb_build_object('ok',true,'proposalId',v_id,'questionId',p_question_id,'version',v_version,'status','queued');
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
  v_active integer;
begin
  if uid is null then raise exception 'authentication required'; end if;
  if not exists(select 1 from english.questions q where q.question_id=p_question_id and english.question_visible_to_user(uid,q.question_id)) then
    raise exception 'question not found';
  end if;
  select proposal_version into v_active from english.user_question_revisions where user_id=uid and question_id=p_question_id;
  select * into p from english.question_revision_proposals
  where user_id=uid and question_id=p_question_id order by proposal_version desc limit 1;
  if not found then return jsonb_build_object('ok',true,'proposal',null,'activeVersion',v_active); end if;
  return jsonb_build_object(
    'ok',true,'activeVersion',v_active,
    'proposal',jsonb_strip_nulls(jsonb_build_object(
      'proposalId',p.proposal_id,'questionId',p.question_id,'version',p.proposal_version,'baseVersion',p.base_version,
      'feedbackReason',p.feedback_reason,'feedbackNote',p.feedback_note,'status',p.status,
      'proposed',case when p.status in ('ready','applied','kept') then p.proposed_payload else null end,
      'critic',case when p.status in ('ready','applied','kept') then p.critic else null end,
      'generationSource',p.generation_source,'lastError',case when p.status='failed' then left(coalesce(p.last_error,''),240) else null end,
      'createdAt',p.created_at,'readyAt',p.ready_at,'decidedAt',p.decided_at
    ))
  );
end $$;
revoke all on function public.english_get_question_revision_state(text,bigint) from public,anon;
grant execute on function public.english_get_question_revision_state(text,bigint) to authenticated,service_role;

create or replace function public.english_get_applied_question_revisions(
  p_question_ids text[],
  p_cache_buster bigint default null
) returns jsonb
language plpgsql
stable
security definer
set search_path to 'pg_catalog','public','english','auth'
as $$
declare uid uuid:=(select auth.uid()); outv jsonb;
begin
  if uid is null then raise exception 'authentication required'; end if;
  if coalesce(cardinality(p_question_ids),0)>120 then raise exception 'too many question ids'; end if;
  select coalesce(jsonb_agg(jsonb_build_object(
    'questionId',r.question_id,'proposalId',r.proposal_id,'version',r.proposal_version,'payload',p.proposed_payload
  ) order by r.question_id),'[]'::jsonb)
  into outv
  from english.user_question_revisions r
  join english.question_revision_proposals p on p.proposal_id=r.proposal_id
  where r.user_id=uid and r.question_id=any(coalesce(p_question_ids,'{}'::text[])) and p.status='applied';
  return jsonb_build_object('ok',true,'revisions',outv);
end $$;
revoke all on function public.english_get_applied_question_revisions(text[],bigint) from public,anon;
grant execute on function public.english_get_applied_question_revisions(text[],bigint) to authenticated,service_role;

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

  with pick as (
    select proposal_id from english.question_revision_proposals
    where status='queued' and attempts<3 and (next_attempt_at is null or next_attempt_at<=now())
    order by created_at,proposal_id
    for update skip locked
    limit greatest(1,least(2,coalesce(p_limit,1)))
  ), upd as (
    update english.question_revision_proposals p
    set status='processing',attempts=p.attempts+1,claimed_at=now(),last_error=null,updated_at=now()
    from pick where p.proposal_id=pick.proposal_id returning p.*
  ), payload as (
    select u.*,q.correct,m.concept_id,c.name concept_name,c.skill_family,c.description concept_description,
      bank.payload bank_candidate
    from upd u
    join english.questions q on q.question_id=u.question_id
    left join english.question_concept_mappings m on m.question_id=u.question_id
    left join english.concepts c on c.concept_id=m.concept_id
    left join lateral (
      select jsonb_build_object(
        'questionId',q2.question_id,'question',q2.question,
        'optionA',q2.option_a,'optionB',q2.option_b,'optionC',q2.option_c,'optionD',q2.option_d,
        'correctKey',upper(q2.correct),'explanation',coalesce(q2.explanation,''),
        'questionType',coalesce(q2.question_type,''),'difficulty',coalesce(q2.difficulty,''),'word',coalesce(q2.word,'')
      ) payload
      from english.questions q2
      join english.question_concept_mappings m2 on m2.question_id=q2.question_id
      where m.concept_id is not null and m2.concept_id=m.concept_id and q2.question_id<>u.question_id and q2.active
        and english.question_visible_to_user(u.user_id,q2.question_id)
        and upper(coalesce(q2.correct,'')) in ('A','B','C','D')
        and nullif(trim(coalesce(q2.option_a,'')),'') is not null
        and nullif(trim(coalesce(q2.option_b,'')),'') is not null
        and nullif(trim(coalesce(q2.option_c,'')),'') is not null
        and nullif(trim(coalesce(q2.option_d,'')),'') is not null
        and nullif(trim(coalesce(q2.explanation,'')),'') is not null
      order by case when lower(coalesce(q2.difficulty,''))=lower(coalesce(q.difficulty,'')) then 0 else 1 end,q2.question_id
      limit 1
    ) bank on true
  )
  select jsonb_build_object('items',coalesce(jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
    'proposalId',proposal_id,'userId',user_id,'questionId',question_id,'version',proposal_version,'baseVersion',base_version,
    'feedbackReason',feedback_reason,'feedbackNote',feedback_note,'base',base_payload,
    'requiredCorrectKey',upper(correct),'conceptId',concept_id,'conceptName',concept_name,'skillFamily',skill_family,
    'conceptDescription',concept_description,'bankCandidate',bank_candidate
  )) order by created_at),'[]'::jsonb)) into outv from payload;
  return coalesce(outv,jsonb_build_object('items','[]'::jsonb));
end $$;
revoke all on function english.question_revision_claim(text,integer) from public,anon,authenticated;
grant execute on function english.question_revision_claim(text,integer) to service_role;

create or replace function public.english_question_revision_claim(p_token text,p_limit integer default 1)
returns jsonb language sql security definer set search_path to 'pg_catalog','public','english'
as $$ select english.question_revision_claim(p_token,p_limit); $$;
revoke all on function public.english_question_revision_claim(text,integer) from public,anon,authenticated;
grant execute on function public.english_question_revision_claim(text,integer) to service_role;

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
  v_key text;
  v_payload jsonb;
  v_changed integer:=0;
  k text;
  v_new text;
  v_old text;
  v_score numeric;
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
  if v_key<>upper(coalesce(q.correct,'')) or v_key<>upper(coalesce(r.base_payload->>'correctKey','')) then
    raise exception 'revision changed the canonical correct key';
  end if;
  if nullif(trim(coalesce(p_item->>'question','')),'') is null or char_length(trim(p_item->>'question'))<8 then raise exception 'revision question is incomplete'; end if;
  if nullif(trim(coalesce(p_item->>'explanation','')),'') is null or char_length(trim(p_item->>'explanation'))<20 then raise exception 'revision explanation is incomplete'; end if;
  if nullif(trim(coalesce(p_item->>'optionA','')),'') is null or nullif(trim(coalesce(p_item->>'optionB','')),'') is null
     or nullif(trim(coalesce(p_item->>'optionC','')),'') is null or nullif(trim(coalesce(p_item->>'optionD','')),'') is null then
    raise exception 'revision options are incomplete';
  end if;
  if lower(trim(p_item->>'optionA')) in (lower(trim(p_item->>'optionB')),lower(trim(p_item->>'optionC')),lower(trim(p_item->>'optionD')))
     or lower(trim(p_item->>'optionB')) in (lower(trim(p_item->>'optionC')),lower(trim(p_item->>'optionD')))
     or lower(trim(p_item->>'optionC'))=lower(trim(p_item->>'optionD')) then
    raise exception 'revision options are not unique';
  end if;

  v_score:=coalesce((p_critic->>'qualityScore')::numeric,0);
  if not coalesce((p_critic->>'exactlyOneCorrect')::boolean,false)
     or not coalesce((p_critic->>'closeDistractors')::boolean,false)
     or not coalesce((p_critic->>'notObviouslyEliminable')::boolean,false)
     or not coalesce((p_critic->>'explanationMatches')::boolean,false)
     or not coalesce((p_critic->>'noStaleExplanation')::boolean,false)
     or not coalesce((p_critic->>'noAmbiguity')::boolean,false)
     or not coalesce((p_critic->>'faithfulConcept')::boolean,false)
     or not coalesce((p_critic->>'fairDifficulty')::boolean,false)
     or v_score<0.85 then
    raise exception 'revision critic rejected the proposal';
  end if;

  if lower(regexp_replace(trim(p_item->>'explanation'),'[[:space:]]+',' ','g'))=
     lower(regexp_replace(trim(coalesce(r.base_payload->>'explanation','')),'[[:space:]]+',' ','g')) then
    raise exception 'revision explanation is stale';
  end if;

  foreach k in array array['A','B','C','D'] loop
    if k<>v_key then
      v_new:=lower(regexp_replace(trim(coalesce(p_item->>('option'||k),'')),'[[:space:]]+',' ','g'));
      v_old:=lower(regexp_replace(trim(coalesce(r.base_payload->>('option'||k),'')),'[[:space:]]+',' ','g'));
      if v_new<>v_old then v_changed:=v_changed+1; end if;
    end if;
  end loop;
  if r.feedback_reason in ('options_too_obvious','distractors_unrelated') and v_changed<2 then
    raise exception 'revision did not materially improve the distractors';
  end if;

  if p_source not in ('bank_first','ai_last_resort') then raise exception 'invalid revision generation source'; end if;
  v_payload:=jsonb_build_object(
    'question',trim(p_item->>'question'),
    'optionA',trim(p_item->>'optionA'),'optionB',trim(p_item->>'optionB'),'optionC',trim(p_item->>'optionC'),'optionD',trim(p_item->>'optionD'),
    'correctKey',v_key,'explanation',trim(p_item->>'explanation')
  );

  update english.question_revision_proposals
  set status='ready',proposed_payload=v_payload,critic=p_critic,generation_source=p_source,
      ai_model=p_model,ai_usage=coalesce(p_usage,'{}'::jsonb),ready_at=now(),last_error=null,updated_at=now()
  where proposal_id=p_proposal_id and status='processing';
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

create or replace function english.fail_question_revision(p_token text,p_proposal_id uuid,p_error text)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','english'
as $$
declare r english.question_revision_proposals%rowtype;
begin
  if not english.context_worker_authorized(p_token) then raise exception 'context worker unauthorized'; end if;
  select * into r from english.question_revision_proposals where proposal_id=p_proposal_id for update;
  if not found then return jsonb_build_object('ok',false,'missing',true); end if;
  if r.status='superseded' then return jsonb_build_object('ok',true,'stale',true); end if;
  if r.status<>'processing' then return jsonb_build_object('ok',true,'ignored',true,'status',r.status); end if;
  update english.question_revision_proposals
  set status=case when attempts<3 then 'queued' else 'failed' end,
      next_attempt_at=case when attempts<3 then now()+case when attempts=1 then interval '2 minutes' else interval '10 minutes' end else null end,
      last_error=left(coalesce(nullif(trim(p_error),''),'background revision failed'),800),updated_at=now()
  where proposal_id=p_proposal_id;
  return jsonb_build_object('ok',true,'retry',r.attempts<3,'attempts',r.attempts);
end $$;
revoke all on function english.fail_question_revision(text,uuid,text) from public,anon,authenticated;
grant execute on function english.fail_question_revision(text,uuid,text) to service_role;

create or replace function public.english_fail_question_revision(p_token text,p_proposal_id uuid,p_error text)
returns jsonb language sql security definer set search_path to 'pg_catalog','public','english'
as $$ select english.fail_question_revision(p_token,p_proposal_id,p_error); $$;
revoke all on function public.english_fail_question_revision(text,uuid,text) from public,anon,authenticated;
grant execute on function public.english_fail_question_revision(text,uuid,text) to service_role;

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
  if exists(select 1 from english.question_revision_proposals newer where newer.user_id=uid and newer.question_id=p.question_id and newer.proposal_version>p.proposal_version and newer.status<>'superseded') then
    raise exception 'a newer revision proposal exists';
  end if;
  insert into english.user_question_revisions(user_id,question_id,proposal_id,proposal_version,applied_at)
  values(uid,p.question_id,p.proposal_id,p.proposal_version,now())
  on conflict(user_id,question_id) do update set proposal_id=excluded.proposal_id,proposal_version=excluded.proposal_version,applied_at=now();
  update english.question_revision_proposals set status='applied',decided_at=now(),updated_at=now() where proposal_id=p.proposal_id;
  return jsonb_build_object('ok',true,'questionId',p.question_id,'version',p.proposal_version,'status','applied','payload',p.proposed_payload);
end $$;
revoke all on function public.english_use_question_revision(uuid) from public,anon;
grant execute on function public.english_use_question_revision(uuid) to authenticated,service_role;

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
  return jsonb_build_object('ok',true,'questionId',p.question_id,'version',p.proposal_version,'status','kept');
end $$;
revoke all on function public.english_keep_question_revision(uuid) from public,anon;
grant execute on function public.english_keep_question_revision(uuid) to authenticated,service_role;
