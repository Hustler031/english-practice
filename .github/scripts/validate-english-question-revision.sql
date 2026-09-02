\set ON_ERROR_STOP on

create or replace function auth.uid() returns uuid
language sql stable
as $$ select '11111111-1111-1111-1111-111111111111'::uuid $$;

insert into auth.users(id) values
  ('11111111-1111-1111-1111-111111111111'),
  ('22222222-2222-2222-2222-222222222222')
on conflict do nothing;

insert into english.concepts(concept_id,name,skill_family,description,exam_relevance,active)
values ('REV_CONCEPT','desultory','Vocabulary','Revision test concept','high',true)
on conflict(concept_id) do nothing;

insert into english.questions(
  question_id,topic,word,question,option_a,option_b,option_c,option_d,correct,explanation,subtopic,question_type,difficulty,exam_relevance,active
) values
  ('REV_Q1','Vocabulary','desultory','Choose the correct meaning of the test word.','Correct base','Weak distractor one','Weak distractor two','Weak distractor three','A','Base explanation for the original options only.','Vocabulary','Vocabulary','Moderate','high',true),
  ('REV_Q2','Vocabulary','desultory','Choose the best use of the same test concept.','Correct bank','Close bank one','Close bank two','Close bank three','A','Bank explanation for the same concept.','Vocabulary','Vocabulary','Hard','high',true),
  ('REV_Q3','Vocabulary','desultory','Choose the option that best distinguishes the target word in context.','Correct strong bank','Plausible near meaning one','Plausible near meaning two','Plausible near meaning three','A','Strong bank explanation distinguishes the close alternatives.','Vocabulary','Vocabulary','Hard','high',true)
on conflict(question_id) do nothing;

insert into english.question_concept_mappings(question_id,concept_id,family_id)
values ('REV_Q1','REV_CONCEPT','REV_FAMILY'),('REV_Q2','REV_CONCEPT','REV_FAMILY'),('REV_Q3','REV_CONCEPT','REV_FAMILY')
on conflict(question_id) do update set concept_id=excluded.concept_id,family_id=excluded.family_id;

-- Learner-specific difficulty calibration: three fast clean attempts should mark REV_Q2 trivial for this learner.
insert into english.attempts(attempt_id,user_id,question_id,attempted_at,selected_answer,correct,time_seconds)
values
 ('QMET1',auth.uid(),'REV_Q2',now()-interval '3 minutes','A',true,6),
 ('QMET2',auth.uid(),'REV_Q2',now()-interval '2 minutes','A',true,7),
 ('QMET3',auth.uid(),'REV_Q2',now()-interval '1 minute','A',true,5);

do $$
declare r english.question_quality_metrics%rowtype;
begin
  select * into r from english.question_quality_metrics where user_id=auth.uid() and question_id='REV_Q2';
  assert r.attempts=3, 'question-quality attempts were not calibrated';
  assert r.too_easy, 'fast repeated clean evidence should mark the item too easy for this learner';
end $$;

-- First repair request is valid and owned by the current user.
select public.english_request_question_revision('REV_Q1','options_too_obvious',null);

do $$
declare r english.question_revision_proposals%rowtype;
begin
  select * into r from english.question_revision_proposals where user_id=auth.uid() and question_id='REV_Q1' order by proposal_version desc limit 1;
  assert r.proposal_version=1, 'first proposal version must be 1';
  assert r.status='queued', 'first proposal must be queued';
  assert r.base_version=0, 'first proposal must be based on canonical version 0';
end $$;

-- New feedback supersedes unresolved work instead of racing it.
select public.english_request_question_revision('REV_Q1','distractors_unrelated','Make the wrong options genuinely confusable.');

do $$
declare v1 text; v2 text;
begin
  select status into v1 from english.question_revision_proposals where user_id=auth.uid() and question_id='REV_Q1' and proposal_version=1;
  select status into v2 from english.question_revision_proposals where user_id=auth.uid() and question_id='REV_Q1' and proposal_version=2;
  assert v1='superseded', 'older unresolved proposal must be superseded';
  assert v2='queued', 'newest proposal must be queued';
end $$;

select public.english_question_revision_claim('ci-worker',1);

-- Options repair must keep the current stem and correct option, while materially improving distractors + explanation.
do $$
declare pid uuid; outv jsonb;
begin
  select proposal_id into pid from english.question_revision_proposals where user_id=auth.uid() and question_id='REV_Q1' and proposal_version=2;
  outv:=public.english_apply_question_revision_result(
    'ci-worker',pid,
    jsonb_build_object(
      'question','Choose the correct meaning of the test word.',
      'optionA','Correct base',
      'optionB','Close but contextually narrower meaning',
      'optionC','Close but deceptively adjacent meaning',
      'optionD','Close but semantically distinct meaning',
      'correctKey','A',
      'explanation','A is correct for the target sense. B is narrower, C is only superficially related, and D expresses a different semantic relation.'
    ),
    jsonb_build_object(
      'exactlyOneCorrect',true,'closeDistractors',true,'notObviouslyEliminable',true,
      'explanationMatches',true,'noStaleExplanation',true,'noAmbiguity',true,
      'faithfulConcept',true,'fairDifficulty',true,'sscDifficultyFit',true,
      'obviousElimination',false,'difficultyArtificial',false,'distractorCloseness',0.86,
      'realisticTrapCount',3,'qualityScore',0.96,'rationale','SSC repair fixture'
    ),
    'bank_informed_ai','ci-model','{}'::jsonb
  );
  assert outv->>'status'='ready', 'critic-approved repair must become ready';
end $$;

-- Explicit Use applies only the user overlay; canonical bank content stays immutable.
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

-- Applied overlay keeps the canonical question id.
do $$
declare outv jsonb;
begin
  outv:=public.english_get_applied_question_revisions(array['REV_Q1'],1);
  assert jsonb_array_length(outv->'revisions')=1, 'one active revision must be returned';
  assert outv->'revisions'->0->>'questionId'='REV_Q1', 'overlay must preserve canonical question id';
  assert (outv->'revisions'->0->>'version')::integer=2, 'active revision version mismatch';
end $$;

-- Explanation-only repair starts from the accepted overlay and may not touch stem/options.
select public.english_request_question_revision('REV_Q1','explanation_weak','Make the reasoning even clearer.');
select public.english_question_revision_claim('ci-worker',1);

do $$
declare pid uuid;
begin
  select proposal_id into pid from english.question_revision_proposals where user_id=auth.uid() and question_id='REV_Q1' and proposal_version=3;
  perform public.english_apply_question_revision_result(
    'ci-worker',pid,
    jsonb_build_object(
      'question','Choose the correct meaning of the test word.',
      'optionA','Correct base',
      'optionB','Close but contextually narrower meaning',
      'optionC','Close but deceptively adjacent meaning',
      'optionD','Close but semantically distinct meaning',
      'correctKey','A',
      'explanation','A matches the exact target sense. B narrows it too far, C shares surface similarity but not the tested meaning, and D belongs to a distinct semantic relation.'
    ),
    jsonb_build_object(
      'exactlyOneCorrect',true,'closeDistractors',true,'notObviouslyEliminable',true,
      'explanationMatches',true,'noStaleExplanation',true,'noAmbiguity',true,
      'faithfulConcept',true,'fairDifficulty',true,'sscDifficultyFit',true,
      'obviousElimination',false,'difficultyArtificial',false,'distractorCloseness',0.86,
      'realisticTrapCount',3,'qualityScore',0.95,'rationale','Explanation-only fixture'
    ),
    'bank_informed_ai','ci-model','{}'::jsonb
  );
  perform public.english_keep_question_revision(pid);
end $$;

do $$
declare active_version integer; latest_status text;
begin
  select proposal_version into active_version from english.user_question_revisions where user_id=auth.uid() and question_id='REV_Q1';
  select status into latest_status from english.question_revision_proposals where user_id=auth.uid() and question_id='REV_Q1' and proposal_version=3;
  assert active_version=2, 'Keep current must preserve the previously active revision';
  assert latest_status='kept', 'kept proposal must remain auditable';
end $$;

-- Correct-answer doubt is a canonical review request, not a personal rewrite.
do $$
declare outv jsonb; before_count integer; after_count integer;
begin
  select count(*) into before_count from english.question_revision_proposals where user_id=auth.uid() and question_id='REV_Q1';
  outv:=public.english_request_question_revision('REV_Q1','correct_answer_doubtful','Please verify the marked key independently.');
  select count(*) into after_count from english.question_revision_proposals where user_id=auth.uid() and question_id='REV_Q1';
  assert outv->>'kind'='canonical_review', 'doubtful answer must route to canonical review';
  assert after_count=before_count, 'canonical review must not create a personal rewrite proposal';
end $$;

select public.english_question_quality_review_claim('ci-worker',1);

do $$
declare rid uuid; outv jsonb;
begin
  select review_id into rid from english.question_quality_reviews where user_id=auth.uid() and question_id='REV_Q1' order by created_at desc limit 1;
  outv:=public.english_apply_question_quality_review_result(
    'ci-worker',rid,
    jsonb_build_object('verdict','issue_suspected','exactlyOneCorrect',false,'recommendedCorrectKey','',
      'ambiguous',true,'explanationConsistent',false,'confidence',0.91,'rationale','Fixture detects a possible canonical issue.'),
    'ci-model','{}'::jsonb
  );
  assert outv->>'verdict'='issue_suspected', 'quality review verdict must be preserved';
  assert (select correct from english.questions where question_id='REV_Q1')='A', 'quality review must never mutate the canonical key';
end $$;

-- Explicit related practice skips a learner-trivial alternate and reuses the suitable bank item before generation.
do $$
declare outv jsonb;
begin
  outv:=public.english_request_related_practice('REV_Q1','I want a related/confusable-word question.');
  assert outv->>'source'='bank_first', 'explicit related practice must reuse a suitable bank item first';
  assert outv->>'questionId'='REV_Q3', 'bank-first related practice must skip the learner-trivial alternate';
end $$;

-- Another authenticated user cannot apply or inspect this user's revision proposal.
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
  exception when others then rejected:=true;
  end;
  assert rejected, 'cross-user apply must be rejected';
  outv:=public.english_get_question_revision_state('REV_Q1',2);
  assert (outv->>'proposal') is null, 'cross-user proposal state must not be disclosed';
end $$;

create or replace function auth.uid() returns uuid
language sql stable
as $$ select null::uuid $$;
