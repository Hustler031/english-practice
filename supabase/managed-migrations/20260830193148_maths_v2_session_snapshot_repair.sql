-- Reconstruct only missing operational session snapshots from preserved ordered membership.
update maths.sessions s
set rendered_questions = maths._render_questions(
  s.user_id,
  (select array_agg(sq.question_id order by sq.position) from maths.session_questions sq where sq.session_id = s.session_id),
  false
)
where coalesce(jsonb_array_length(s.rendered_questions), 0) = 0
  and exists (select 1 from maths.session_questions sq where sq.session_id = s.session_id);

-- A migrated session with every frozen question answered and its cursor past the end is complete.
update maths.sessions s
set completed = true,
    updated_at = coalesce(s.updated_at, now())
where not s.completed
  and s.current_index >= (select count(*) from maths.session_questions sq where sq.session_id = s.session_id)
  and (select count(*) from maths.session_questions sq where sq.session_id = s.session_id) > 0
  and (select count(distinct a.question_id)
       from maths.attempts a
       where a.user_id = s.user_id and a.session_id = s.session_id)
      = (select count(*) from maths.session_questions sq where sq.session_id = s.session_id);

-- Keep every remaining resumable cursor inside its immutable snapshot boundary.
update maths.sessions s
set current_index = greatest(
  0,
  least(
    s.current_index,
    greatest(0, coalesce(jsonb_array_length(s.rendered_questions), 0) - 1)
  )
)
where not s.completed
  and coalesce(jsonb_array_length(s.rendered_questions), 0) > 0
  and (s.current_index < 0 or s.current_index >= jsonb_array_length(s.rendered_questions));

create or replace function maths._get_session(p_uid uuid,p_session_id text)
returns jsonb
language plpgsql
stable
security definer
set search_path=pg_catalog,public,maths
as $$
declare
  s maths.sessions%rowtype;
  attempts_ jsonb;
  flags_ jsonb;
  total_ int;
  current_ int;
begin
  select * into s from maths.sessions where session_id=p_session_id and user_id=p_uid;
  if not found then raise exception 'Session not found'; end if;
  total_ := coalesce(jsonb_array_length(s.rendered_questions), 0);
  if total_ = 0 then
    select count(*) into total_ from maths.session_questions where session_id=s.session_id;
  end if;
  current_ := case when total_ = 0 then 0 else greatest(0, least(s.current_index, total_ - 1)) end;
  select coalesce(jsonb_object_agg(a.question_id,jsonb_build_object(
    'result',lower(coalesce(a.result,'')),
    'selectedOption',coalesce(a.selected_option,''),
    'responseSec',coalesce(a.response_sec,0),
    'attemptId',a.attempt_id
  )),'{}'::jsonb)
  into attempts_
  from (
    select distinct on(question_id) *
    from maths.attempts
    where user_id=p_uid and session_id=s.session_id
    order by question_id,attempted_at desc,attempt_id desc
  ) a;
  select coalesce(jsonb_object_agg(r.question_id,jsonb_build_object(
    'starred',r.starred,
    'difficult',r.difficult,
    'mastered',r.mastered,
    'inConcept',exists(
      select 1 from maths.concept_membership c
      where c.user_id=p_uid and c.question_id=r.question_id and c.active
    )
  )),'{}'::jsonb)
  into flags_
  from maths._user_runtime(p_uid) r
  where r.question_id in(
    select question_id from maths.session_questions where session_id=s.session_id
  );
  return jsonb_build_object(
    'ok',true,
    'sessionId',s.session_id,
    'mode',coalesce(s.mode,''),
    'title',coalesce(s.title,''),
    'currentIndex',current_,
    'completed',s.completed,
    'target',total_,
    'params',coalesce(s.params,'{}'::jsonb),
    'questions',coalesce(s.rendered_questions,'[]'::jsonb),
    'attempts',attempts_,
    'flags',flags_
  );
end
$$;

revoke all on function maths._get_session(uuid,text) from public,anon,authenticated;
