-- Durable, navigation-safe English Sprint generation.
-- Generation is tracked independently from the Exam Preparation page lifecycle.

alter table english.sprint_sessions
  drop constraint if exists sprint_sessions_status_check;

alter table english.sprint_sessions
  add constraint sprint_sessions_status_check
  check (status in ('ready','in_progress','paused','completed','abandoned'));

create or replace function english.defer_sprint_start_from_blueprint()
returns trigger
language plpgsql
set search_path = pg_catalog, english
as $$
begin
  if lower(coalesce(new.blueprint->>'startImmediately','true')) = 'false' then
    new.status := 'ready';
    new.remaining_seconds := 900;
  end if;
  return new;
end;
$$;

revoke all on function english.defer_sprint_start_from_blueprint() from public;

drop trigger if exists zz_english_defer_sprint_start on english.sprint_sessions;
create trigger zz_english_defer_sprint_start
before insert on english.sprint_sessions
for each row execute function english.defer_sprint_start_from_blueprint();

create table if not exists english.sprint_generation_jobs (
  job_id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  mode text not null check (mode in ('standard','weakness','trap','mistakes')),
  status text not null default 'queued' check (status in ('queued','generating','ready','failed','claimed')),
  session_id uuid null references english.sprint_sessions(session_id) on delete set null,
  request_group uuid null,
  error text null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  completed_at timestamptz null,
  expires_at timestamptz not null default (now() + interval '5 minutes')
);

create index if not exists sprint_generation_jobs_user_created_idx
  on english.sprint_generation_jobs(user_id, created_at desc);

create unique index if not exists sprint_generation_jobs_one_active_idx
  on english.sprint_generation_jobs(user_id)
  where status in ('queued','generating','ready');

alter table english.sprint_generation_jobs enable row level security;
revoke all on table english.sprint_generation_jobs from anon, authenticated;

create or replace function public.english_start_sprint_generation(p_mode text)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public, english, auth
as $$
declare
  uid uuid := auth.uid();
  m text := lower(coalesce(p_mode,'standard'));
  j english.sprint_generation_jobs%rowtype;
  active_sid uuid;
begin
  if uid is null then raise exception 'Authentication required'; end if;
  if english.sprint_expected_count(m)=0 then raise exception 'Unknown Sprint mode'; end if;

  update english.sprint_generation_jobs
     set status='failed', error='Generation expired before completion', updated_at=now(), completed_at=now()
   where user_id=uid and status in ('queued','generating','ready') and expires_at<=now();

  select session_id into active_sid
  from english.sprint_sessions
  where user_id=uid and status in ('ready','in_progress','paused')
  order by created_at desc, session_id desc
  limit 1;

  if active_sid is not null then
    return jsonb_build_object('ok',true,'activeSprint',true,'sessionId',active_sid,'shouldStart',false);
  end if;

  select * into j
  from english.sprint_generation_jobs
  where user_id=uid and status in ('queued','generating','ready') and expires_at>now()
  order by created_at desc
  limit 1;

  if found then
    return jsonb_build_object(
      'ok',true,'active',true,'jobId',j.job_id,'mode',j.mode,'status',j.status,
      'sessionId',j.session_id,'shouldStart',false
    );
  end if;

  begin
    insert into english.sprint_generation_jobs(user_id,mode,status,expires_at)
    values(uid,m,'queued',now()+interval '5 minutes')
    returning * into j;
  exception when unique_violation then
    select * into j
    from english.sprint_generation_jobs
    where user_id=uid and status in ('queued','generating','ready')
    order by created_at desc
    limit 1;
  end;

  return jsonb_build_object(
    'ok',true,'active',true,'jobId',j.job_id,'mode',j.mode,'status',j.status,
    'sessionId',j.session_id,'shouldStart',(j.status='queued')
  );
end;
$$;

create or replace function public.english_begin_sprint_generation(p_job_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public, english, auth
as $$
declare
  uid uuid := auth.uid();
  j english.sprint_generation_jobs%rowtype;
begin
  if uid is null then raise exception 'Authentication required'; end if;
  select * into j from english.sprint_generation_jobs
   where job_id=p_job_id and user_id=uid for update;
  if not found then raise exception 'Sprint generation job not found'; end if;

  if j.status='queued' then
    update english.sprint_generation_jobs
       set status='generating',updated_at=now(),expires_at=now()+interval '5 minutes'
     where job_id=p_job_id and user_id=uid;
    return jsonb_build_object('ok',true,'shouldGenerate',true,'mode',j.mode);
  end if;

  return jsonb_build_object('ok',true,'shouldGenerate',false,'mode',j.mode,'status',j.status);
end;
$$;

create or replace function public.english_complete_sprint_generation(
  p_job_id uuid,
  p_session_id uuid,
  p_request_group uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public, english, auth
as $$
declare
  uid uuid := auth.uid();
  j english.sprint_generation_jobs%rowtype;
begin
  if uid is null then raise exception 'Authentication required'; end if;
  select * into j from english.sprint_generation_jobs
   where job_id=p_job_id and user_id=uid for update;
  if not found then raise exception 'Sprint generation job not found'; end if;
  if not exists(select 1 from english.sprint_sessions s where s.session_id=p_session_id and s.user_id=uid and s.status='ready') then
    raise exception 'Generated Sprint is not ready';
  end if;

  update english.sprint_generation_jobs
     set status='ready',session_id=p_session_id,request_group=p_request_group,error=null,
         updated_at=now(),completed_at=now(),expires_at=now()+interval '30 minutes'
   where job_id=p_job_id and user_id=uid;

  return jsonb_build_object('ok',true,'jobId',p_job_id,'status','ready','sessionId',p_session_id);
end;
$$;

create or replace function public.english_fail_sprint_generation(p_job_id uuid,p_error text)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public, english, auth
as $$
declare uid uuid := auth.uid();
begin
  if uid is null then raise exception 'Authentication required'; end if;
  update english.sprint_generation_jobs
     set status='failed',error=left(coalesce(nullif(btrim(p_error),''),'Sprint generation failed'),600),
         updated_at=now(),completed_at=now(),expires_at=now()+interval '10 minutes'
   where job_id=p_job_id and user_id=uid and status in ('queued','generating');
  return jsonb_build_object('ok',true);
end;
$$;

create or replace function public.english_get_sprint_generation()
returns jsonb
language sql
stable
security definer
set search_path = pg_catalog, public, english, auth
as $$
with j as (
  select *
  from english.sprint_generation_jobs
  where user_id=auth.uid()
    and (
      (status in ('queued','generating','ready') and expires_at>now())
      or (status='failed' and completed_at>=now()-interval '10 minutes')
    )
  order by case when status in ('queued','generating','ready') then 0 else 1 end, created_at desc
  limit 1
)
select case
  when auth.uid() is null then jsonb_build_object('ok',false,'error','Authentication required')
  when not exists(select 1 from j) then jsonb_build_object('ok',true,'active',false,'status','idle')
  else jsonb_build_object(
    'ok',true,
    'active',(select status in ('queued','generating','ready') from j),
    'jobId',(select job_id from j),
    'mode',(select mode from j),
    'status',(select status from j),
    'sessionId',(select session_id from j),
    'error',(select error from j),
    'createdAt',(select created_at from j),
    'updatedAt',(select updated_at from j)
  )
end;
$$;

create or replace function public.english_start_ready_sprint(p_session_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public, english, auth
as $$
declare
  uid uuid := auth.uid();
  s english.sprint_sessions%rowtype;
begin
  if uid is null then raise exception 'Authentication required'; end if;
  select * into s from english.sprint_sessions
   where session_id=p_session_id and user_id=uid for update;
  if not found then raise exception 'Sprint not found'; end if;

  if s.status='ready' then
    update english.sprint_sessions
       set status='in_progress',started_at=now(),runtime_updated_at=now(),remaining_seconds=900,
           paused_at=null,current_position=1
     where session_id=p_session_id and user_id=uid;
    update english.sprint_generation_jobs
       set status='claimed',updated_at=now()
     where user_id=uid and session_id=p_session_id and status='ready';
  end if;

  return public.english_get_sprint_session(p_session_id);
end;
$$;

create or replace function public.english_get_active_sprint()
returns jsonb
language sql
stable
security definer
set search_path = pg_catalog, public, english, auth
as $$
with latest as (
  select session_id
  from english.sprint_sessions
  where user_id=auth.uid() and status in ('ready','in_progress','paused')
  order by created_at desc,session_id desc
  limit 1
)
select case
 when auth.uid() is null then jsonb_build_object('ok',false,'error','Authentication required')
 when not exists(select 1 from latest) then jsonb_build_object('ok',true,'active',false)
 else public.english_get_sprint_session((select session_id from latest))||jsonb_build_object('active',true)
end;
$$;

revoke all on function public.english_start_sprint_generation(text) from public, anon;
revoke all on function public.english_begin_sprint_generation(uuid) from public, anon;
revoke all on function public.english_complete_sprint_generation(uuid,uuid,uuid) from public, anon;
revoke all on function public.english_fail_sprint_generation(uuid,text) from public, anon;
revoke all on function public.english_get_sprint_generation() from public, anon;
revoke all on function public.english_start_ready_sprint(uuid) from public, anon;
grant execute on function public.english_start_sprint_generation(text) to authenticated;
grant execute on function public.english_begin_sprint_generation(uuid) to authenticated;
grant execute on function public.english_complete_sprint_generation(uuid,uuid,uuid) to authenticated;
grant execute on function public.english_fail_sprint_generation(uuid,text) to authenticated;
grant execute on function public.english_get_sprint_generation() to authenticated;
grant execute on function public.english_start_ready_sprint(uuid) to authenticated;
