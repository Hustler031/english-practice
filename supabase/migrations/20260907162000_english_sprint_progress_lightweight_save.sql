-- Reduce Exam Sprint submit latency by making the frequent progress autosave cheap.
-- The browser ignores this RPC's response; returning the full 25-question session on
-- every autosave created unnecessary payload/read work and could leave a chain of
-- pending saves in front of the final authoritative submit.

create or replace function public.english_save_sprint_progress(
  p_session_id uuid,
  p_items jsonb default '[]'::jsonb,
  p_current_position integer default 1,
  p_remaining_seconds integer default 900
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','public','english','auth'
as $function$
declare
  uid uuid:=auth.uid();
  s english.sprint_sessions%rowtype;
  x jsonb;
  pos integer;
  selected text;
  spent numeric;
  was_visited boolean;
  review boolean;
  v_current integer;
  v_remaining integer;
begin
  if uid is null then raise exception 'Authentication required'; end if;

  select * into s
  from english.sprint_sessions
  where session_id=p_session_id and user_id=uid
  for update;

  if not found then raise exception 'Sprint not found'; end if;

  -- A late autosave after final submission must be a cheap no-op. In particular,
  -- do not rebuild/return the complete Sprint result here.
  if s.status not in ('in_progress','paused') then
    return jsonb_build_object(
      'ok',true,
      'sessionId',p_session_id,
      'status',s.status,
      'ignored',true,
      'currentPosition',s.current_position,
      'remainingSeconds',s.remaining_seconds
    );
  end if;

  if jsonb_typeof(coalesce(p_items,'[]'::jsonb))<>'array' then
    raise exception 'Sprint progress items must be an array';
  end if;

  for x in select value from jsonb_array_elements(coalesce(p_items,'[]'::jsonb)) loop
    pos:=coalesce((x->>'position')::integer,0);
    if pos<1 or pos>s.question_count
       or not exists(select 1 from english.sprint_items i where i.session_id=p_session_id and i.position=pos) then
      raise exception 'Invalid Sprint progress position %',pos;
    end if;

    selected:=upper(nullif(btrim(coalesce(x->>'selectedKey','')),''));
    if selected is not null and selected not in ('A','B','C','D') then
      raise exception 'Invalid Sprint option at %',pos;
    end if;

    spent:=least(900,greatest(0,coalesce((x->>'timeSeconds')::numeric,0)));
    was_visited:=coalesce((x->>'visited')::boolean,false);
    review:=coalesce((x->>'markedForReview')::boolean,false);
    if selected is not null then was_visited:=true; end if;

    insert into english.sprint_answers(
      session_id,position,user_id,selected_key,correct,time_seconds,visited,marked_for_review,updated_at
    ) values (
      p_session_id,pos,uid,selected,false,spent,was_visited,review,now()
    )
    on conflict(session_id,position) do update set
      selected_key=excluded.selected_key,
      time_seconds=excluded.time_seconds,
      visited=excluded.visited,
      marked_for_review=excluded.marked_for_review,
      updated_at=now()
    where english.sprint_answers.selected_key is distinct from excluded.selected_key
       or english.sprint_answers.time_seconds is distinct from excluded.time_seconds
       or english.sprint_answers.visited is distinct from excluded.visited
       or english.sprint_answers.marked_for_review is distinct from excluded.marked_for_review;
  end loop;

  v_current:=least(s.question_count,greatest(1,coalesce(p_current_position,1)));
  v_remaining:=least(900,greatest(0,coalesce(p_remaining_seconds,900)));

  update english.sprint_sessions
  set current_position=v_current,
      remaining_seconds=v_remaining,
      runtime_updated_at=now()
  where session_id=p_session_id and user_id=uid
    and (
      current_position is distinct from v_current
      or remaining_seconds is distinct from v_remaining
    );

  return jsonb_build_object(
    'ok',true,
    'sessionId',p_session_id,
    'status',s.status,
    'saved',true,
    'currentPosition',v_current,
    'remainingSeconds',v_remaining
  );
end
$function$;
