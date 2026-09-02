\set ON_ERROR_STOP on

create or replace function auth.uid() returns uuid
language sql stable
as $$ select '11111111-1111-1111-1111-111111111111'::uuid $$;

insert into english.learning_route_state(user_id,question_id,route,metadata,origins,last_route_reason,targeted_at,updated_at)
values(
  auth.uid(),'REV_Q1','targeted',jsonb_build_object('targetedKind','need_learning'),'{}'::text[],
  'UI exact-question fixture',now(),now()
)
on conflict(user_id,question_id) do update set
  route='targeted',metadata=excluded.metadata,last_route_reason=excluded.last_route_reason,updated_at=now();

do $$
declare labels jsonb; exact jsonb;
begin
  labels:=public.english_get_question_labels(array['REV_Q1']);
  assert labels->>'ok'='true', 'question labels RPC must succeed for authenticated user';
  assert jsonb_array_length(labels->'items')=1, 'question labels RPC must return one visible row';
  assert labels->'items'->0->>'questionId'='REV_Q1', 'question labels RPC identity mismatch';
  assert labels->'items'->0->>'displayName'='desultory', 'learner-facing label must prefer the real word/name over an internal ID';

  exact:=public.english_get_targeted_question('REV_Q1');
  assert jsonb_array_length(exact)=1, 'exact Targeted question RPC must return one item';
  assert exact->0->>'id'='REV_Q1', 'exact Targeted question must preserve canonical identity';
  assert exact->0->>'learningRoute'='targeted', 'exact Targeted question must preserve route metadata';
end $$;

-- A question that is not currently on this learner's Targeted route must not be exposed by the exact route RPC.
do $$
declare exact jsonb;
begin
  exact:=public.english_get_targeted_question('REV_Q2');
  assert jsonb_array_length(exact)=0, 'exact Targeted RPC must not bypass the current learner route';
end $$;

create or replace function auth.uid() returns uuid
language sql stable
as $$ select null::uuid $$;
