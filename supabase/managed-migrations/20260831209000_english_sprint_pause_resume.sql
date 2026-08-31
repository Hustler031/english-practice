-- Durable SSC Sprint runtime state: pause/resume, visited/review flags and authoritative recovery.
-- Additive only; completed scoring/history remains owned by existing sprint tables/RPCs.

alter table english.sprint_sessions
  add column if not exists current_position integer not null default 1,
  add column if not exists remaining_seconds integer not null default 900,
  add column if not exists runtime_updated_at timestamptz not null default now(),
  add column if not exists paused_at timestamptz;

alter table english.sprint_answers
  add column if not exists visited boolean not null default false,
  add column if not exists marked_for_review boolean not null default false,
  add column if not exists updated_at timestamptz not null default now();

alter table english.sprint_sessions drop constraint if exists sprint_sessions_status_check;
alter table english.sprint_sessions add constraint sprint_sessions_status_check
  check (status in ('in_progress','paused','completed','abandoned'));

update english.sprint_sessions
set remaining_seconds=greatest(0,900-least(900,greatest(0,floor(extract(epoch from (now()-started_at)))::integer))),
    runtime_updated_at=now()
where status='in_progress' and remaining_seconds=900;

create unique index if not exists english_sprint_one_active_per_user_idx
  on english.sprint_sessions(user_id)
  where status in ('in_progress','paused');

create or replace function public.english_get_sprint_session(p_session_id uuid)
returns jsonb language sql stable security definer
set search_path=pg_catalog,public,english,auth as $$
with s as (
  select *,case
    when status='in_progress' then greatest(0,coalesce(remaining_seconds,900)-greatest(0,floor(extract(epoch from (now()-coalesce(runtime_updated_at,started_at))))::integer))
    else greatest(0,coalesce(remaining_seconds,900))
  end effective_remaining
  from english.sprint_sessions
  where session_id=p_session_id and user_id=auth.uid()
), i as (
  select x.*,a.selected_key,a.time_seconds,a.visited,a.marked_for_review
  from english.sprint_items x
  join s on s.session_id=x.session_id
  left join english.sprint_answers a
    on a.session_id=x.session_id and a.position=x.position and a.user_id=auth.uid()
  order by x.position
)
select case
 when not exists(select 1 from s) then jsonb_build_object('ok',false,'error','Sprint not found')
 else jsonb_build_object(
   'ok',true,
   'sessionId',(select session_id from s),
   'mode',(select mode from s),
   'status',(select status from s),
   'startedAt',(select started_at from s),
   'pausedAt',(select paused_at from s),
   'questionCount',(select question_count from s),
   'durationLimitSeconds',900,
   'remainingSeconds',(select effective_remaining from s),
   'currentPosition',least((select question_count from s),greatest(1,(select current_position from s))),
   'items',coalesce((
      select jsonb_agg(
        case when (select status from s)='completed' then
          jsonb_build_object(
            'position',position,'category',category,'questionType',question_type,
            'question',question,'options',options,'selectedKey',selected_key,
            'visited',coalesce(visited,false),'markedForReview',coalesce(marked_for_review,false),
            'correctKey',correct_key,'explanation',explanation,'sourceType',source_type,
            'canonicalQuestionId',canonical_question_id
          )
        else
          jsonb_build_object(
            'position',position,'category',category,'questionType',question_type,
            'question',question,'options',options,'selectedKey',selected_key,
            'visited',coalesce(visited,false),'markedForReview',coalesce(marked_for_review,false),
            'timeSeconds',coalesce(time_seconds,0)
          )
        end
        order by position
      ) from i
   ),'[]'::jsonb),
   'result',case when (select status from s)='completed' then
      jsonb_build_object(
        'score',(select score from s),
        'maxMarks',(select question_count*2 from s),
        'correct',(select correct_count from s),
        'wrong',(select wrong_count from s),
        'unanswered',(select unanswered_count from s),
        'accuracy',(select accuracy from s),
        'durationSeconds',(select duration_seconds from s),
        'analysis',(select analysis from s)
      )
    else null end
 )
end;
$$;

create or replace function public.english_get_active_sprint()
returns jsonb language sql stable security definer
set search_path=pg_catalog,public,english,auth as $$
with latest as (
  select session_id
  from english.sprint_sessions
  where user_id=auth.uid() and status in ('in_progress','paused')
  order by created_at desc,session_id desc
  limit 1
)
select case
 when auth.uid() is null then jsonb_build_object('ok',false,'error','Authentication required')
 when not exists(select 1 from latest) then jsonb_build_object('ok',true,'active',false)
 else public.english_get_sprint_session((select session_id from latest))||jsonb_build_object('active',true)
end;
$$;

create or replace function public.english_save_sprint_progress(
  p_session_id uuid,
  p_items jsonb default '[]'::jsonb,
  p_current_position integer default 1,
  p_remaining_seconds integer default 900
)
returns jsonb language plpgsql security definer
set search_path=pg_catalog,public,english,auth as $$
declare
  uid uuid:=auth.uid();
  s english.sprint_sessions%rowtype;
  x jsonb;
  pos integer;
  selected text;
  spent numeric;
  was_visited boolean;
  review boolean;
begin
  if uid is null then raise exception 'Authentication required'; end if;
  select * into s from english.sprint_sessions
   where session_id=p_session_id and user_id=uid for update;
  if not found then raise exception 'Sprint not found'; end if;
  if s.status not in ('in_progress','paused') then return public.english_get_sprint_session(p_session_id); end if;
  if jsonb_typeof(coalesce(p_items,'[]'::jsonb))<>'array' then raise exception 'Sprint progress items must be an array'; end if;

  for x in select value from jsonb_array_elements(coalesce(p_items,'[]'::jsonb)) loop
    pos:=coalesce((x->>'position')::integer,0);
    if pos<1 or pos>s.question_count or not exists(select 1 from english.sprint_items i where i.session_id=p_session_id and i.position=pos) then
      raise exception 'Invalid Sprint progress position %',pos;
    end if;
    selected:=upper(nullif(btrim(coalesce(x->>'selectedKey','')),''));
    if selected is not null and selected not in ('A','B','C','D') then raise exception 'Invalid Sprint option at %',pos; end if;
    spent:=least(900,greatest(0,coalesce((x->>'timeSeconds')::numeric,0)));
    was_visited:=coalesce((x->>'visited')::boolean,false);
    review:=coalesce((x->>'markedForReview')::boolean,false);
    if selected is not null then was_visited:=true; end if;

    insert into english.sprint_answers(session_id,position,user_id,selected_key,correct,time_seconds,visited,marked_for_review,updated_at)
    values(p_session_id,pos,uid,selected,false,spent,was_visited,review,now())
    on conflict(session_id,position) do update set
      selected_key=excluded.selected_key,
      time_seconds=excluded.time_seconds,
      visited=excluded.visited,
      marked_for_review=excluded.marked_for_review,
      updated_at=now();
  end loop;

  update english.sprint_sessions
     set current_position=least(question_count,greatest(1,coalesce(p_current_position,1))),
         remaining_seconds=least(900,greatest(0,coalesce(p_remaining_seconds,900))),
         runtime_updated_at=now()
   where session_id=p_session_id and user_id=uid;

  return public.english_get_sprint_session(p_session_id);
end $$;

create or replace function public.english_pause_sprint(
  p_session_id uuid,
  p_items jsonb default '[]'::jsonb,
  p_current_position integer default 1,
  p_remaining_seconds integer default 900
)
returns jsonb language plpgsql security definer
set search_path=pg_catalog,public,english,auth as $$
declare uid uuid:=auth.uid(); current_status text;
begin
  if uid is null then raise exception 'Authentication required'; end if;
  perform public.english_save_sprint_progress(p_session_id,p_items,p_current_position,p_remaining_seconds);
  select status into current_status from english.sprint_sessions
   where session_id=p_session_id and user_id=uid for update;
  if not found then raise exception 'Sprint not found'; end if;
  if current_status='in_progress' then
    update english.sprint_sessions set status='paused',paused_at=now(),runtime_updated_at=now()
     where session_id=p_session_id and user_id=uid;
  end if;
  return public.english_get_sprint_session(p_session_id);
end $$;

create or replace function public.english_resume_sprint(p_session_id uuid)
returns jsonb language plpgsql security definer
set search_path=pg_catalog,public,english,auth as $$
declare
  uid uuid:=auth.uid();
  s english.sprint_sessions%rowtype;
  effective integer;
begin
  if uid is null then raise exception 'Authentication required'; end if;
  select * into s from english.sprint_sessions where session_id=p_session_id and user_id=uid for update;
  if not found then raise exception 'Sprint not found'; end if;
  if s.status not in ('in_progress','paused') then return public.english_get_sprint_session(p_session_id); end if;
  effective:=case when s.status='in_progress'
    then greatest(0,coalesce(s.remaining_seconds,900)-greatest(0,floor(extract(epoch from (now()-coalesce(s.runtime_updated_at,s.started_at))))::integer))
    else greatest(0,coalesce(s.remaining_seconds,900)) end;
  update english.sprint_sessions
     set status='in_progress',remaining_seconds=effective,runtime_updated_at=now(),paused_at=null
   where session_id=p_session_id and user_id=uid;
  return public.english_get_sprint_session(p_session_id);
end $$;

create or replace function public.english_abandon_sprint(p_session_id uuid)
returns jsonb language plpgsql security definer
set search_path=pg_catalog,public,english,auth as $$
declare uid uuid:=auth.uid(); current_status text;
begin
  if uid is null then raise exception 'Authentication required'; end if;
  select status into current_status from english.sprint_sessions
   where session_id=p_session_id and user_id=uid for update;
  if not found then raise exception 'Sprint not found'; end if;
  if current_status in ('in_progress','paused') then
    update english.sprint_sessions set status='abandoned',paused_at=null,runtime_updated_at=now()
     where session_id=p_session_id and user_id=uid and status in ('in_progress','paused');
    current_status:='abandoned';
  end if;
  return jsonb_build_object('ok',true,'sessionId',p_session_id,'status',current_status);
end $$;

-- Explicit execute boundary for the browser-authenticated app.
revoke all on function public.english_get_active_sprint() from public,anon;
revoke all on function public.english_save_sprint_progress(uuid,jsonb,integer,integer) from public,anon;
revoke all on function public.english_pause_sprint(uuid,jsonb,integer,integer) from public,anon;
revoke all on function public.english_resume_sprint(uuid) from public,anon;
grant execute on function public.english_get_active_sprint() to authenticated;
grant execute on function public.english_save_sprint_progress(uuid,jsonb,integer,integer) to authenticated;
grant execute on function public.english_pause_sprint(uuid,jsonb,integer,integer) to authenticated;
grant execute on function public.english_resume_sprint(uuid) to authenticated;
