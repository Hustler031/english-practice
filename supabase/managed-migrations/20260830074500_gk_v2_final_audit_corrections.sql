-- Final GK V2 audit corrections discovered while validating 20260830073000 against
-- the actual live catalog. Forward-only; no historical Attempt/Exposure/State rebuild.

-- The live function is seven-argument (p_response_ms is optional). Remove the draft
-- six-argument overload so PostgREST has one canonical mutation signature.
drop function if exists public.gk_submit_answer(text,text,boolean,text,text,text);

-- Raw-evidence learning authority. Retention requires >=18 hours AND, when both
-- session IDs are known, a different session. A long-lived same-session correction
-- therefore cannot prove retention.
create or replace function gk.learning_profiles_v2(p_user_id uuid)
returns table(
  question_id text,
  attempts integer,
  correct integer,
  wrong integer,
  accuracy numeric,
  first_attempt_correct boolean,
  retention_attempts integer,
  retention_correct integer,
  retention_wrong integer,
  retention_accuracy numeric,
  recent_spaced_failures integer,
  last_attempt timestamptz,
  last_spaced_attempt timestamptz,
  last_meaningful_result text,
  latest_result text,
  learning_state text,
  next_review timestamptz,
  due boolean,
  guessed_attempts integer,
  repeatedly_guessed boolean,
  unconfirmed_guess boolean,
  last_guess_at timestamptz,
  confirmed_unguessed_spaced_recalls integer,
  exposure_count integer,
  first_seen timestamptz,
  last_seen timestamptz
)
language sql
stable security definer
set search_path=pg_catalog,gk,auth
as $$
with ordered as (
  select a.*,
    lag(a.attempted_at) over(partition by a.question_id order by a.attempted_at,a.attempt_id) prev_attempted_at,
    lag(a.session_id) over(partition by a.question_id order by a.attempted_at,a.attempt_id) prev_session_id
  from gk.attempts a
  where a.user_id=p_user_id and a.is_correct is not null
), marked as (
  select o.*,
    (o.prev_attempted_at is not null
      and extract(epoch from(o.attempted_at-o.prev_attempted_at))/3600.0 >= 18
      and not (o.session_id is not null and o.prev_session_id is not null and o.session_id=o.prev_session_id)) spaced
  from ordered o
), spaced_ranked as (
  select m.*,row_number() over(partition by m.question_id order by m.attempted_at desc,m.attempt_id desc) spaced_desc
  from marked m where m.spaced
), agg as (
  select m.question_id,
    count(*)::int attempts,
    count(*) filter(where m.is_correct)::int correct,
    count(*) filter(where not m.is_correct)::int wrong,
    round(count(*) filter(where m.is_correct)*100.0/nullif(count(*),0),1) accuracy,
    (array_agg(m.is_correct order by m.attempted_at,m.attempt_id))[1] first_attempt_correct,
    count(*) filter(where m.spaced)::int retention_attempts,
    count(*) filter(where m.spaced and m.is_correct)::int retention_correct,
    count(*) filter(where m.spaced and not m.is_correct)::int retention_wrong,
    round(count(*) filter(where m.spaced and m.is_correct)*100.0/nullif(count(*) filter(where m.spaced),0),1) retention_accuracy,
    max(m.attempted_at) last_attempt,
    max(m.attempted_at) filter(where m.spaced) last_spaced_attempt,
    (array_agg(m.is_correct order by m.attempted_at desc,m.attempt_id desc))[1] latest_correct,
    (array_agg(m.is_correct order by m.attempted_at desc,m.attempt_id desc) filter(where m.spaced))[1] last_spaced_correct,
    (array_agg(coalesce(m.guessed,false) order by m.attempted_at desc,m.attempt_id desc) filter(where m.spaced))[1] last_spaced_guessed,
    count(*) filter(where coalesce(m.guessed,false))::int guessed_attempts,
    max(m.attempted_at) filter(where coalesce(m.guessed,false)) last_guess_at,
    count(*) filter(where m.spaced and m.is_correct and not coalesce(m.guessed,false))::int confirmed_unguessed_spaced_recalls,
    max(m.attempted_at) filter(where m.spaced and m.is_correct and not coalesce(m.guessed,false)) last_confirming_at
  from marked m group by m.question_id
), recent as (
  select question_id,count(*) filter(where not is_correct)::int recent_spaced_failures
  from spaced_ranked where spaced_desc<=3 group by question_id
), exposure as (
  select question_id,count(*)::int exposure_count,min(exposed_at) first_seen,max(exposed_at) last_seen
  from gk.exposures where user_id=p_user_id group by question_id
), raw as (
  select q.question_id,
    coalesce(a.attempts,0)::int attempts,coalesce(a.correct,0)::int correct,coalesce(a.wrong,0)::int wrong,
    coalesce(a.accuracy,0)::numeric accuracy,a.first_attempt_correct,
    coalesce(a.retention_attempts,0)::int retention_attempts,
    coalesce(a.retention_correct,0)::int retention_correct,
    coalesce(a.retention_wrong,0)::int retention_wrong,
    coalesce(a.retention_accuracy,0)::numeric retention_accuracy,
    coalesce(r.recent_spaced_failures,0)::int recent_spaced_failures,
    a.last_attempt,a.last_spaced_attempt,
    case when coalesce(a.retention_attempts,0)>0 then case when a.last_spaced_correct then 'Correct' else 'Wrong' end
      when a.attempts is not null then case when a.latest_correct then 'Correct' else 'Wrong' end else '' end last_meaningful_result,
    case when a.attempts is not null then case when a.latest_correct then 'Correct' else 'Wrong' end else '' end latest_result,
    coalesce(a.guessed_attempts,0)::int guessed_attempts,
    coalesce(a.guessed_attempts,0)>=2 repeatedly_guessed,
    (a.last_guess_at is not null and (a.last_confirming_at is null or a.last_confirming_at<=a.last_guess_at)) unconfirmed_guess,
    a.last_guess_at,coalesce(a.confirmed_unguessed_spaced_recalls,0)::int confirmed_unguessed_spaced_recalls,
    a.last_spaced_correct,a.last_spaced_guessed,
    coalesce(e.exposure_count,0)::int exposure_count,e.first_seen,e.last_seen
  from gk.questions q
  left join agg a on a.question_id=q.question_id
  left join recent r on r.question_id=q.question_id
  left join exposure e on e.question_id=q.question_id
  where q.active
), stated as (
  select r.*,
    case
      when r.attempts=0 then 'New'
      when r.recent_spaced_failures>=2 or (r.retention_wrong>=2 and r.retention_accuracy<60) then 'Persistent Weak'
      when (r.retention_wrong>=1 and coalesce(r.last_spaced_correct,false)=false)
        or (r.wrong>=2 and r.retention_correct=0) then 'Weak'
      when r.unconfirmed_guess or r.retention_attempts<2 then 'Fragile'
      when r.retention_correct>=3 and r.retention_accuracy>=85
        and r.last_spaced_correct is true and not coalesce(r.last_spaced_guessed,false)
        and r.recent_spaced_failures=0 and not r.unconfirmed_guess
        and r.confirmed_unguessed_spaced_recalls>=2 then 'Proven Mastered'
      when r.retention_correct>=2 and r.retention_accuracy>=75
        and r.last_spaced_correct is true and not r.unconfirmed_guess then 'Strong'
      when r.wrong>0 or r.retention_accuracy<70 then 'Weak'
      else 'Learning'
    end learning_state
  from raw r
), scheduled as (
  select s.*,
    case when s.last_attempt is null then null::timestamptz else
      (((coalesce(s.last_spaced_attempt,s.last_attempt) at time zone 'Asia/Kolkata')::date
        + case s.learning_state
            when 'Persistent Weak' then 1 when 'Weak' then 1 when 'Fragile' then 2
            when 'Learning' then 3 when 'Strong' then 7 when 'Proven Mastered' then 21 else 2 end
      )::timestamp at time zone 'Asia/Kolkata') end next_review
  from stated s
)
select s.question_id,s.attempts,s.correct,s.wrong,s.accuracy,s.first_attempt_correct,
  s.retention_attempts,s.retention_correct,s.retention_wrong,s.retention_accuracy,
  s.recent_spaced_failures,s.last_attempt,s.last_spaced_attempt,s.last_meaningful_result,s.latest_result,
  s.learning_state,s.next_review,coalesce(s.next_review<=now(),false) due,
  s.guessed_attempts,s.repeatedly_guessed,s.unconfirmed_guess,s.last_guess_at,
  s.confirmed_unguessed_spaced_recalls,s.exposure_count,s.first_seen,s.last_seen
from scheduled s
$$;
revoke execute on function gk.learning_profiles_v2(uuid) from public,anon,authenticated,service_role;

create or replace function public.gk_submit_answer(
  p_question_id text,
  p_selected_option text,
  p_marked_review boolean default false,
  p_attempt_id text default null,
  p_mode text default 'practice',
  p_session_id text default null,
  p_response_ms integer default null
) returns jsonb
language plpgsql
security definer
set search_path=pg_catalog,public,gk,auth
as $$
declare
  uid uuid:=auth.uid(); q gk.questions%rowtype;
  aid text:=coalesce(nullif(btrim(p_attempt_id),''),'gk-'||gen_random_uuid()::text);
  chosen text:=upper(btrim(coalesce(p_selected_option,''))); correct_key text; is_ok boolean;
  previous_at timestamptz; previous_session text; gap numeric; spaced boolean:=false;
  inserted boolean:=false; affected integer:=0; subkey text; profile record;
begin
  if uid is null then raise exception 'Authentication required'; end if;
  select * into q from gk.questions where question_id=btrim(p_question_id) and active;
  if not found then raise exception 'Question not found'; end if;
  correct_key:=upper(btrim(coalesce(q.correct_option,'')));
  if correct_key not in ('A','B','C','D') then raise exception 'Question has invalid canonical correct option'; end if;
  if chosen not in ('A','B','C','D') then raise exception 'Invalid option selected'; end if;

  select attempted_at,session_id into previous_at,previous_session
  from gk.attempts where user_id=uid and question_id=q.question_id and is_correct is not null
  order by attempted_at desc,attempt_id desc limit 1;
  if previous_at is not null then
    gap:=extract(epoch from(now()-previous_at))/3600.0;
    spaced:=gap>=18 and not (
      nullif(btrim(coalesce(p_session_id,'')),'') is not null
      and previous_session is not null
      and btrim(p_session_id)=previous_session
    );
  end if;

  is_ok:=chosen=correct_key;
  subkey:=case when nullif(btrim(coalesce(p_session_id,'')),'') is not null
    then uid::text||'|'||btrim(p_session_id)||'|'||q.question_id else aid end;

  insert into gk.attempts(
    attempt_id,user_id,attempted_at,question_id,selected_option,is_correct,marked_review,
    mode,session_id,response_ms,submission_key,learning_state,guessed,attempt_kind,
    canonical_selected_option,display_selected_option,is_spaced,gap_hours,confidence_confirmed,study_date
  ) values(
    aid,uid,now(),q.question_id,chosen,is_ok,coalesce(p_marked_review,false),
    p_mode,p_session_id,p_response_ms,subkey,'',false,'answer',chosen,chosen,spaced,gap,true,
    (now() at time zone 'Asia/Kolkata')::date
  ) on conflict do nothing;
  get diagnostics affected=row_count; inserted:=affected>0;

  if not inserted then
    select a.is_correct,upper(coalesce(a.selected_option,'')),a.attempt_id,coalesce(a.is_spaced,false),a.gap_hours
      into is_ok,chosen,aid,spaced,gap
    from gk.attempts a
    where a.user_id=uid and a.question_id=q.question_id and (a.attempt_id=aid or a.submission_key=subkey)
    order by case when a.attempt_id=aid then 0 else 1 end limit 1;
    if not found then raise exception 'Attempt id belongs to a different answer'; end if;
  else
    insert into gk.question_state(user_id,question_id,learning_status,last_selected,last_correct)
    values(uid,q.question_id,'New',chosen,is_ok)
    on conflict(user_id,question_id) do update
      set last_selected=excluded.last_selected,last_correct=excluded.last_correct;
    perform gk.refresh_question_state_v2(uid,q.question_id);
  end if;

  select * into profile from gk.learning_profiles_v2(uid) where question_id=q.question_id;
  return jsonb_build_object('ok',true,'attemptId',aid,'deduped',not inserted,'isCorrect',is_ok,
    'correctOption',correct_key,'learningState',coalesce(profile.learning_state,'New'),
    'retentionAttempt',coalesce(spaced,false),'unconfirmedGuess',coalesce(profile.unconfirmed_guess,false));
end
$$;

-- Exact position_index is the last deliberate pause/save location. current_index remains
-- monotonic progress evidence; FIFO outbox ordering prevents stale save inversion.
create or replace function public.gk_save_session(
  p_session_id text,p_title text,p_mode text,p_position integer,p_answers jsonb,
  p_option_orders jsonb,p_question_ids text[],p_completed boolean default false,
  p_params jsonb default '{}'::jsonb
) returns jsonb
language plpgsql security definer
set search_path=pg_catalog,public,gk,auth
as $$
declare uid uuid:=auth.uid(); sid text:=btrim(coalesce(p_session_id,'')); i integer; existing_owner uuid;
begin
  if uid is null then raise exception 'Authentication required'; end if;
  if sid='' then raise exception 'Session id required'; end if;
  select user_id into existing_owner from gk.sessions where session_id=sid;
  if existing_owner is not null and existing_owner<>uid then raise exception 'Session belongs to another user'; end if;

  insert into gk.sessions(
    session_id,user_id,mode,params,current_index,updated_at,completed,title,study_day,
    composition,option_orders,answers,position_index,paused_at,session_version,created_at,study_date
  ) values(
    sid,uid,p_mode,coalesce(p_params,'{}'::jsonb),greatest(0,coalesce(p_position,0)),now(),
    coalesce(p_completed,false),coalesce(nullif(p_title,''),'GK Practice'),null,'{}'::jsonb,
    coalesce(p_option_orders,'{}'::jsonb),coalesce(p_answers,'{}'::jsonb),
    greatest(0,coalesce(p_position,0)),case when p_completed then null else now() end,'2.1',now(),
    (now() at time zone 'Asia/Kolkata')::date
  ) on conflict(session_id) do update set
    mode=excluded.mode,params=excluded.params,
    current_index=greatest(gk.sessions.current_index,excluded.current_index),
    position_index=excluded.position_index,updated_at=now(),
    completed=gk.sessions.completed or excluded.completed,title=excluded.title,
    option_orders=case when jsonb_typeof(coalesce(gk.sessions.option_orders,'{}'::jsonb))='object'
      then coalesce(gk.sessions.option_orders,'{}'::jsonb)||coalesce(excluded.option_orders,'{}'::jsonb)
      else excluded.option_orders end,
    answers=case when jsonb_typeof(coalesce(gk.sessions.answers,'{}'::jsonb))='object'
      then coalesce(gk.sessions.answers,'{}'::jsonb)||coalesce(excluded.answers,'{}'::jsonb)
      else excluded.answers end,
    paused_at=case when gk.sessions.completed or excluded.completed then null else now() end,
    study_date=coalesce(gk.sessions.study_date,excluded.study_date)
  where gk.sessions.user_id=uid;

  delete from gk.session_questions sq where sq.session_id=sid
    and exists(select 1 from gk.sessions s where s.session_id=sid and s.user_id=uid);
  if coalesce(array_length(p_question_ids,1),0)>0 then
    for i in 1..array_length(p_question_ids,1) loop
      insert into gk.session_questions(session_id,question_id,position)
      select sid,p_question_ids[i],i-1
      where exists(select 1 from gk.questions q where q.question_id=p_question_ids[i] and q.active)
      on conflict do nothing;
    end loop;
  end if;
  return jsonb_build_object('ok',true,'sessionId',sid,'completed',coalesce(p_completed,false));
end
$$;

-- Manual learning tools are explicit idempotent RPCs. Star retries preserve the
-- original starred_at timestamp so age bands do not drift on network retry.
create or replace function public.gk_set_starred(p_question_id text,p_starred boolean)
returns jsonb language plpgsql security definer
set search_path=pg_catalog,public,gk,auth
as $$
declare uid uuid:=auth.uid(); qid text:=btrim(coalesce(p_question_id,''));
begin
 if uid is null then raise exception 'Authentication required'; end if;
 if not exists(select 1 from gk.questions where question_id=qid and active) then raise exception 'Question not found'; end if;
 insert into gk.question_state(user_id,question_id,marked_review,starred_at,learning_status)
 values(uid,qid,coalesce(p_starred,false),case when p_starred then now() else null end,'New')
 on conflict(user_id,question_id) do update set
   marked_review=excluded.marked_review,
   starred_at=case when excluded.marked_review then coalesce(gk.question_state.starred_at,excluded.starred_at) else null end;
 perform gk.refresh_question_state_v2(uid,qid);
 return jsonb_build_object('ok',true,'starred',coalesce(p_starred,false));
end
$$;

create or replace function public.gk_set_difficult(p_question_id text,p_difficult boolean)
returns jsonb language plpgsql security definer
set search_path=pg_catalog,public,gk,auth
as $$
declare uid uuid:=auth.uid(); qid text:=btrim(coalesce(p_question_id,''));
begin
 if uid is null then raise exception 'Authentication required'; end if;
 if not exists(select 1 from gk.questions where question_id=qid and active) then raise exception 'Question not found'; end if;
 insert into gk.question_state(user_id,question_id,difficult,learning_status)
 values(uid,qid,coalesce(p_difficult,false),'New')
 on conflict(user_id,question_id) do update set difficult=excluded.difficult;
 perform gk.refresh_question_state_v2(uid,qid);
 return jsonb_build_object('ok',true,'difficult',coalesce(p_difficult,false));
end
$$;

create or replace function public.gk_set_flag(
 p_question_id text,p_active boolean,p_reason text default null,p_note text default null
) returns jsonb language plpgsql security definer
set search_path=pg_catalog,public,gk,auth
as $$
declare uid uuid:=auth.uid(); qid text:=btrim(coalesce(p_question_id,''));
begin
 if uid is null then raise exception 'Authentication required'; end if;
 if not exists(select 1 from gk.questions where question_id=qid and active) then raise exception 'Question not found'; end if;
 insert into gk.question_state(user_id,question_id,flag_active,flag_reason,flag_note,flag_updated_at,learning_status)
 values(uid,qid,coalesce(p_active,false),p_reason,p_note,now(),'New')
 on conflict(user_id,question_id) do update set
   flag_active=excluded.flag_active,flag_reason=excluded.flag_reason,
   flag_note=excluded.flag_note,flag_updated_at=excluded.flag_updated_at;
 perform gk.refresh_question_state_v2(uid,qid);
 return jsonb_build_object('ok',true,'active',coalesce(p_active,false));
end
$$;

create or replace function public.gk_save_note(p_question_id text,p_note text)
returns jsonb language plpgsql security definer
set search_path=pg_catalog,public,gk,auth
as $$
declare uid uuid:=auth.uid(); qid text:=btrim(coalesce(p_question_id,''));
begin
 if uid is null then raise exception 'Authentication required'; end if;
 if not exists(select 1 from gk.questions where question_id=qid and active) then raise exception 'Question not found'; end if;
 if nullif(btrim(coalesce(p_note,'')),'') is null then
   delete from gk.user_notes where user_id=uid and question_id=qid;
 else
   insert into gk.user_notes(user_id,question_id,note,updated_at) values(uid,qid,p_note,now())
   on conflict(user_id,question_id) do update set note=excluded.note,updated_at=excluded.updated_at;
 end if;
 return jsonb_build_object('ok',true);
end
$$;

-- Daily uses explicit tiers, not an additive score that could let Due Learning jump
-- ahead of Fragile. Proven Mastered returns only when it is actually due.
create or replace function public.gk_get_batch(
 p_mode text default 'smart',p_count integer default 20,p_lane text default 'MIXED',
 p_subject text default null,p_topic text default null,p_lecture_key text default null,
 p_library_key text default null,p_demand_id text default null,p_ca_months integer default null,
 p_ca_category text default null
) returns jsonb
language plpgsql volatile security definer
set search_path=pg_catalog,public,gk,auth
as $$
declare uid uuid:=auth.uid(); mode_name text:=lower(btrim(coalesce(p_mode,'smart')));
 lane_name text:=upper(btrim(coalesce(p_lane,'MIXED'))); n int:=greatest(1,least(1000,coalesce(p_count,20)));
 age_from int:=null; age_to int:=null;
 group_kind text:=case when coalesce(p_count,20)=10 then 'random' when coalesce(p_count,20)=20 then 'smart' else 'all' end;
 out jsonb;
begin
 if uid is null then raise exception 'Authentication required'; end if;
 if lane_name not in ('MAIN','RAPID','MIXED','ALL') then raise exception 'Invalid GK question style'; end if;
 if mode_name ~ '^starred_age_[0-9]+_[0-9]+$' then
   age_from:=split_part(mode_name,'_',3)::int; age_to:=split_part(mode_name,'_',4)::int;
   return public.gk_get_starred_group_batch(age_from,age_to,false,group_kind,n);
 end if;
 if mode_name='starred_earlier' then return public.gk_get_starred_group_batch(null,null,true,group_kind,n); end if;

 with legacy_owner as (
   select case when count(distinct x.user_id)=1 then min(x.user_id) end uid
   from (select user_id from gk.attempts union all select user_id from gk.exposures
     union all select user_id from gk.question_state union all select user_id from gk.sessions) x
 ), profile as(select * from gk.learning_profiles_v2(uid)), base as (
   select q.*,p.learning_state st,p.wrong,p.due,p.next_review,p.last_attempt,p.last_guess_at,
     p.guessed_attempts,p.unconfirmed_guess,p.confirmed_unguessed_spaced_recalls,
     coalesce(s.difficult,false) difficult,coalesce(s.marked_review,false) starred,s.starred_at,
     p.exposure_count>0 exposed,p.last_seen last_seen_evidence,
     (select max(a.attempted_at) from gk.attempts a where a.user_id=uid and a.question_id=q.question_id
       and (a.mode like 'starred_%' or a.mode='review')) starred_last_revision,
     case p.learning_state when 'Persistent Weak' then 1000 when 'Weak' then 850 when 'Fragile' then 700
       when 'Learning' then 500 when 'New' then 300 when 'Strong' then 180 when 'Proven Mastered' then 20 else 0 end
       +case when p.due then 300 else 0 end+case when coalesce(s.difficult,false) then 180 else 0 end
       +case when p.unconfirmed_guess then 240 else 0 end+case when coalesce(s.marked_review,false) then 80 else 0 end
       +least(180,coalesce(floor(extract(epoch from(now()-p.last_attempt))/86400)::int*6,140))
       +case when q.subject='Current Affairs' and q.source_date is not null
         then greatest(0,120-(current_date-q.source_date)) else 0 end priority
   from gk.questions q join profile p on p.question_id=q.question_id
   left join gk.question_state s on s.user_id=uid and s.question_id=q.question_id
   where q.active and (lane_name in ('MIXED','ALL') or upper(q.content_lane)=lane_name)
     and (p_subject is null or q.subject=p_subject) and (p_topic is null or q.topic=p_topic)
     and (p_lecture_key is null or q.lecture_key=p_lecture_key)
     and (p_library_key is null or gk.derive_library_key(q.question_id,q.source_label,q.subject)=p_library_key)
     and (p_ca_category is null or q.topic=p_ca_category)
     and (p_ca_months is null or p_ca_months<=0 or q.source_date>=((current_date-make_interval(months=>p_ca_months))::date))
     and (p_demand_id is null or exists(
       select 1 from gk.demand_sets d,jsonb_array_elements_text(coalesce(d.question_ids,'[]'::jsonb)) j(question_id),legacy_owner lo
       where d.demand_id=p_demand_id and d.active and j.question_id=q.question_id
         and (d.user_id=uid or (d.user_id is null and lo.uid=uid))))
 ), eligible as (
   select * from base b where case
     when mode_name in ('new','unseen','new_v2','new_random') then not b.exposed
     when mode_name in ('weak','weak_practice') then b.st in ('Persistent Weak','Weak','Fragile')
     when mode_name='persistent_weak' then b.st='Persistent Weak'
     when mode_name='starred_persistent' then b.starred and b.st='Persistent Weak'
     when mode_name in ('due','due_recall') then b.due
     when mode_name='difficult' then b.difficult
     when mode_name in ('starred','starred_smart') then b.starred
     when mode_name='starred_weak' then b.starred and b.st in ('Persistent Weak','Weak','Fragile')
     when mode_name='starred_due' then b.starred and b.due
     when mode_name='starred_difficult' then b.starred and b.difficult
     when mode_name='starred_never' then b.starred and b.starred_last_revision is null
     when mode_name in ('starred_longest','starred_oldest','starred_random') then b.starred
     when mode_name in ('guessed','guessed_smart','guessed_random','guessed_oldest','guessed_longest') then b.unconfirmed_guess
     when mode_name='guessed_recent' then b.unconfirmed_guess and b.last_guess_at>=now()-interval '7 days'
     when mode_name='guessed_repeated' then b.unconfirmed_guess and b.guessed_attempts>=2
     when mode_name='guessed_weak' then b.unconfirmed_guess and b.st in ('Persistent Weak','Weak','Fragile')
     when mode_name='guessed_due' then b.unconfirmed_guess and b.due
     when mode_name='guessed_never_confirmed' then b.unconfirmed_guess and b.confirmed_unguessed_spaced_recalls=0
     when mode_name in ('recall','recall_check') then b.exposed and b.st<>'Proven Mastered'
     when mode_name='daily' then b.due or (b.st<>'Proven Mastered' and (
       b.st in ('Persistent Weak','Weak','Fragile') or b.unconfirmed_guess or b.difficult or not b.exposed))
     when mode_name='smart' then b.st<>'Proven Mastered' or b.due
     when mode_name like 'current_%' then b.subject='Current Affairs'
     else true end
 ), ranked as (
   select e.*,row_number() over(order by
     case when mode_name='daily' then case
       when e.st='Persistent Weak' then 7 when e.st='Weak' then 6 when e.st='Fragile' then 5
       when e.due then 4 when e.unconfirmed_guess then 3 when e.difficult then 2 when not e.exposed then 1 else 0 end
       else 0 end desc,
     case when mode_name in ('random','new_random','starred_random','guessed_random','current_random') then random() else 0 end,
     case when mode_name='long_unseen' then extract(epoch from coalesce(e.last_seen_evidence,to_timestamp(0))) else 0 end asc,
     case when mode_name in ('starred_longest','starred_oldest') then extract(epoch from coalesce(e.starred_last_revision,to_timestamp(0))) else 0 end asc,
     case when mode_name in ('guessed_oldest','guessed_longest') then extract(epoch from coalesce(e.last_guess_at,to_timestamp(0))) else 0 end asc,
     case when mode_name='guessed_recent' then extract(epoch from coalesce(e.last_guess_at,to_timestamp(0))) else 0 end desc,
     case when mode_name='starred_smart' then e.priority+least(320,greatest(0,floor(extract(epoch from(
       now()-coalesce(e.starred_last_revision,e.starred_at,to_timestamp(0))))/86400)::int)*10) else e.priority end desc,
     e.priority desc,e.question_id
   ) ord from eligible e
 ), chosen as(select * from ranked order by ord limit n)
 select coalesce(jsonb_agg(gk.question_payload_v2_read(uid,c.question_id) order by c.ord),'[]'::jsonb)
 into out from chosen c; return out;
end
$$;

create or replace function public.gk_get_home_snapshot()
returns jsonb language sql stable security definer
set search_path=pg_catalog,public,gk,auth
as $$
with u as(select auth.uid() uid),p as(select * from gk.learning_profiles_v2((select uid from u))),
state as (
 select p.*,coalesce(s.marked_review,false) starred,coalesce(s.difficult,false) difficult
 from p left join gk.question_state s on s.user_id=(select uid from u) and s.question_id=p.question_id
),top as (
 select count(*)::int total,count(*) filter(where exposure_count>0)::int exposed,
   count(*) filter(where learning_state='Persistent Weak')::int persistent_weak,
   count(*) filter(where learning_state='Weak')::int weak,count(*) filter(where learning_state='Fragile')::int fragile,
   count(*) filter(where learning_state='Strong')::int strong,count(*) filter(where learning_state='Proven Mastered')::int proven_mastered,
   count(*) filter(where due)::int due,count(*) filter(where starred)::int starred,count(*) filter(where difficult)::int difficult,
   count(*) filter(where unconfirmed_guess)::int guessed,count(*) filter(where exposure_count=0)::int new_questions,
   count(*) filter(where learning_state<>'Proven Mastered' or due)::int eligible_total,
   coalesce(round(count(*) filter(where first_attempt_correct is true)*100.0/nullif(count(*) filter(where first_attempt_correct is not null),0),1),0) first_accuracy,
   coalesce(round(sum(retention_correct)*100.0/nullif(sum(retention_attempts),0),1),0) retention_accuracy
 from state
),resume as (
 select s.* from gk.sessions s cross join u where s.user_id=u.uid and not s.completed
 order by case when s.mode like 'daily%' and coalesce(s.study_date,(s.created_at at time zone 'Asia/Kolkata')::date)
   =(now() at time zone 'Asia/Kolkata')::date then 0 else 1 end,s.updated_at desc nulls last,s.created_at desc limit 1
)
select case when (select uid from u) is null then jsonb_build_object('ok',false,'error','Authentication required') else
 jsonb_build_object('ok',true,'summary',jsonb_build_object(
   'total',total,'eligibleTotal',eligible_total,
   'eligibleMain',(select count(*) from gk.questions q join state s on s.question_id=q.question_id
     where q.active and upper(q.content_lane)='MAIN' and (s.learning_state<>'Proven Mastered' or s.due)),
   'eligibleRapidRecall',(select count(*) from gk.questions q join state s on s.question_id=q.question_id
     where q.active and upper(q.content_lane)='RAPID' and (s.learning_state<>'Proven Mastered' or s.due)),
   'exposed',exposed,'bankExposure',case when total>0 then round(exposed*100.0/total,1) else 0 end,
   'persistentWeak',persistent_weak,'weak',weak,'fragile',fragile,'strong',strong,'provenMastered',proven_mastered,
   'due',due,'starred',starred,'difficult',difficult,'guessed',guessed,
   'firstAttemptAccuracy',first_accuracy,'retentionAccuracy',retention_accuracy,'newQuestions',new_questions
 ),'resume',(select to_jsonb(resume) from resume)) end from top
$$;

-- Demand sets are private for newly created rows. Legacy NULL-owner rows are reachable
-- only through the compatibility RPC logic in the single-user legacy case.
drop policy if exists gk_demand_sets_own on gk.demand_sets;
create policy gk_demand_sets_own on gk.demand_sets for all to authenticated
  using(user_id=auth.uid()) with check(user_id=auth.uid());

-- The two malformed legacy canonical answer values were already guarded in 73000.
-- Enforce the invariant for every future active question without touching attempts.
alter table gk.questions drop constraint if exists gk_questions_active_correct_option_check;
alter table gk.questions add constraint gk_questions_active_correct_option_check
  check(not active or upper(btrim(coalesce(correct_option,''))) in ('A','B','C','D')) not valid;
alter table gk.questions validate constraint gk_questions_active_correct_option_check;

-- Browser mutation path is RPC-only. RLS remains defense-in-depth even though direct
-- private-table privileges are revoked.
revoke all on gk.attempts,gk.exposures,gk.question_state,gk.sessions,gk.session_questions,
  gk.user_notes,gk.flags,gk.demand_sets from anon,authenticated;
grant select on gk.questions,gk.lectures to authenticated;

revoke execute on function public.gk_submit_answer(text,text,boolean,text,text,text,integer) from public,anon;
revoke execute on function public.gk_record_exposure(text,text,text,text) from public,anon;
revoke execute on function public.gk_mark_guessed(text,text,boolean,text) from public,anon;
revoke execute on function public.gk_save_session(text,text,text,integer,jsonb,jsonb,text[],boolean,jsonb) from public,anon;
revoke execute on function public.gk_set_starred(text,boolean) from public,anon;
revoke execute on function public.gk_set_difficult(text,boolean) from public,anon;
revoke execute on function public.gk_set_flag(text,boolean,text,text) from public,anon;
revoke execute on function public.gk_save_note(text,text) from public,anon;
revoke execute on function public.gk_get_batch(text,integer,text,text,text,text,text,text,integer,text) from public,anon;
revoke execute on function public.gk_get_home_snapshot() from public,anon;

grant execute on function public.gk_submit_answer(text,text,boolean,text,text,text,integer) to authenticated;
grant execute on function public.gk_record_exposure(text,text,text,text) to authenticated;
grant execute on function public.gk_mark_guessed(text,text,boolean,text) to authenticated;
grant execute on function public.gk_save_session(text,text,text,integer,jsonb,jsonb,text[],boolean,jsonb) to authenticated;
grant execute on function public.gk_set_starred(text,boolean) to authenticated;
grant execute on function public.gk_set_difficult(text,boolean) to authenticated;
grant execute on function public.gk_set_flag(text,boolean,text,text) to authenticated;
grant execute on function public.gk_save_note(text,text) to authenticated;
grant execute on function public.gk_get_batch(text,integer,text,text,text,text,text,text,integer,text) to authenticated;
grant execute on function public.gk_get_home_snapshot() to authenticated;
