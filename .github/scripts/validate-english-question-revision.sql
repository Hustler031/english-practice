\set ON_ERROR_STOP on

create or replace function auth.uid() returns uuid
language sql stable
as $$ select '11111111-1111-1111-1111-111111111111'::uuid $$;

insert into auth.users(id) values
  ('11111111-1111-1111-1111-111111111111'),
  ('22222222-2222-2222-2222-222222222222')
on conflict do nothing;

insert into english.concepts(concept_id,name,skill_family,description)
values ('REV_CONCEPT','Revision Test Concept','Vocabulary','Ephemeral CI concept')
on conflict(concept_id) do nothing;

insert into english.questions(question_id,question,option_a,option_b,option_c,option_d,correct,explanation,question_type,difficulty,word,active)
values
  ('REV_Q1','Choose the correct meaning of the test word.','Correct base','Weak distractor one','Weak distractor two','Weak distractor three','A','Base explanation for the original options only.','Vocabulary','Moderate','testword',true),
  ('REV_Q2','Choose the best use of the same test concept.','Correct bank','Close bank one','Close bank two','Close bank three','A','Bank explanation for the same concept.','Vocabulary','Moderate','testword',true)
on conflict(question_id) do nothing;

insert into english.question_concept_mappings(question_id,concept_id)
values ('REV_Q1','REV_CONCEPT'),('REV_Q2','REV_CONCEPT')
on conflict(question_id) do update set concept_id=excluded.concept_id;

-- First feedback request is valid and owned by the current user.
select public.english_request_question_revision('REV_Q1','options_too_obvious',null);

do $$
declare r english.question_revision_proposals%rowtype;
begin
  select * into r from english.question_revision_proposals
  where user_id=auth.uid() and question_id='REV_Q1' order by proposal_version desc limit 1;
  assert r.proposal_version=1, 'first proposal version must be 1';
  assert r.status='queued', 'first proposal must be queued';
  assert r.base_version=0, 'first proposal must be based on canonical version 0';
  assert r.base_payload->>'question'='Choose the correct meaning of the test word.', 'canonical base snapshot missing';
end $$;

-- A newer request supersedes unresolved work instead of racing it.
select public.english_request_question_revision('REV_Q1','distractors_unrelated','Make the wrong options genuinely confusable.');

do $$
declare v1 text; v2 text;
begin
  select status into v1 from english.question_revision_proposals where user_id=auth.uid() and question_id='REV_Q1' and proposal_version=1;
  select status into v2 from english.question_revision_proposals where user_id=auth.uid() and question_id='REV_Q1' and proposal_version=2;
  assert v1='superseded', 'older unresolved proposal must be superseded';
  assert v2='queued', 'newest proposal must be queued';
end $$;

-- Worker claim is bounded and returns only the live proposal.
select public.english_question_revision_claim('ci-worker',1);

do $$
declare r english.question_revision_proposals%rowtype;
begin
  select * into r from english.question_revision_proposals where user_id=auth.uid() and question_id='REV_Q1' and proposal_version=2;
  assert r.status='processing', 'claimed proposal must be processing';
  assert r.attempts=1, 'first claim must increment attempt counter once';
end $$;

-- A fully critic-approved atomic replacement becomes previewable.
do $$
declare pid uuid; outv jsonb;
begin
  select proposal_id into pid from english.question_revision_proposals where user_id=auth.uid() and question_id='REV_Q1' and proposal_version=2;
  outv:=public.english_apply_question_revision_result(
    'ci-worker',pid,
    jsonb_build_object(
      'question','Choose the most precise meaning of the test word in this sentence.',
      'optionA','Correct revised meaning',
      'optionB','Close but contextually narrower meaning',
      'optionC','Close but grammatically incompatible meaning',
      'optionD','Close but semantically opposite meaning',
      'correctKey','A',
      'explanation','A is correct in this context; B is too narrow, C does not fit the construction, and D reverses the intended meaning.'
    ),
    jsonb_build_object(
      'exactlyOneCorrect',true,
      'closeDistractors',true,
      'notObviouslyEliminable',true,
      'explanationMatches',true,
      'noStaleExplanation',true,
      'noAmbiguity',true,
      'faithfulConcept',true,
      'fairDifficulty',true,
      'qualityScore',0.96,
      'rationale','CI quality gate fixture'
    ),
    'bank_first','ci-model','{}'::jsonb
  );
  assert outv->>'status'='ready', 'critic-approved proposal must become ready';
end $$;

-- Explicit Use applies only the user overlay; canonical bank content remains immutable.
do $$
declare pid uuid; active_version integer; qtext text; qopt text; qcorrect text;
begin
  select proposal_id into pid from english.question_revision_proposals where user_id=auth.uid() and question_id='REV_Q1' and proposal_version=2;
  perform public.english_use_question_revision(pid);
  select proposal_version into active_version from english.user_question_revisions where user_id=auth.uid() and question_id='REV_Q1';
  select question,option_b,correct into qtext,qopt,qcorrect from english.questions where question_id='REV_Q1';
  assert active_version=2, 'accepted proposal must become active version';
  assert qtext='Choose the correct meaning of the test word.', 'canonical stem must not be rewritten';
  assert qopt='Weak distractor one', 'canonical options must not be rewritten';
  assert qcorrect='A', 'canonical grading key must remain unchanged';
end $$;

-- Applied overlay is returned as the same canonical question id.
do $$
declare outv jsonb;
begin
  outv:=public.english_get_applied_question_revisions(array['REV_Q1'],1);
  assert jsonb_array_length(outv->'revisions')=1, 'one active revision must be returned';
  assert outv->'revisions'->0->>'questionId'='REV_Q1', 'overlay must preserve canonical question id';
  assert (outv->'revisions'->0->>'version')::integer=2, 'active revision version mismatch';
  assert outv->'revisions'->0->'payload'->>'explanation' like 'A is correct%', 'active explanation must be the revised explanation';
end $$;

-- A later request starts from the accepted version, not stale canonical text.
select public.english_request_question_revision('REV_Q1','explanation_weak','Make the reasoning even clearer.');

do $$
declare r english.question_revision_proposals%rowtype;
begin
  select * into r from english.question_revision_proposals where user_id=auth.uid() and question_id='REV_Q1' and proposal_version=3;
  assert r.base_version=2, 'new proposal must be based on the active revision';
  assert r.base_payload->>'question'='Choose the most precise meaning of the test word in this sentence.', 'new proposal must snapshot the active revision';
end $$;

select public.english_question_revision_claim('ci-worker',1);

do $$
declare pid uuid;
begin
  select proposal_id into pid from english.question_revision_proposals where user_id=auth.uid() and question_id='REV_Q1' and proposal_version=3;
  perform public.english_apply_question_revision_result(
    'ci-worker',pid,
    jsonb_build_object(
      'question','Choose the most precise meaning of the test word in the revised sentence.',
      'optionA','Correct revised meaning',
      'optionB','Close but contextually narrower meaning',
      'optionC','Close but grammatically incompatible meaning',
      'optionD','Close but semantically opposite meaning',
      'correctKey','A',
      'explanation','A alone matches the sentence and target concept. B narrows the sense incorrectly, C fails the grammatical environment, and D expresses the opposite relation.'
    ),
    jsonb_build_object(
      'exactlyOneCorrect',true,'closeDistractors',true,'notObviouslyEliminable',true,
      'explanationMatches',true,'noStaleExplanation',true,'noAmbiguity',true,
      'faithfulConcept',true,'fairDifficulty',true,'qualityScore',0.95,'rationale','CI keep-current fixture'
    ),
    'ai_last_resort','ci-model','{}'::jsonb
  );
  perform public.english_keep_question_revision(pid);
end $$;

-- Keep current does not move the active pointer.
do $$
declare active_version integer; latest_status text;
begin
  select proposal_version into active_version from english.user_question_revisions where user_id=auth.uid() and question_id='REV_Q1';
  select status into latest_status from english.question_revision_proposals where user_id=auth.uid() and question_id='REV_Q1' and proposal_version=3;
  assert active_version=2, 'Keep current must preserve previously active revision';
  assert latest_status='kept', 'kept proposal must remain auditable';
end $$;

-- Another authenticated user cannot apply or inspect this user's proposal.
create or replace function auth.uid() returns uuid
language sql stable
as $$ select '22222222-2222-2222-2222-222222222222'::uuid $$;

do $$
declare pid uuid; outv jsonb; rejected boolean:=false;
begin
  select proposal_id into pid from english.question_revision_proposals
  where user_id='11111111-1111-1111-1111-111111111111'::uuid and question_id='REV_Q1' and proposal_version=2;
  begin
    perform public.english_use_question_revision(pid);
  exception when others then
    rejected:=true;
  end;
  assert rejected, 'cross-user apply must be rejected';
  outv:=public.english_get_question_revision_state('REV_Q1',2);
  assert outv->'proposal' is null, 'cross-user proposal state must not be disclosed';
end $$;

-- Restore neutral auth fixture for any later CI checks.
create or replace function auth.uid() returns uuid
language sql stable
as $$ select null::uuid $$;
