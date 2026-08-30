-- English V2 fresh-session selection gateway.
-- Forward-only: preserves attempts/question_state/history and adds served-session evidence.
-- Fixed/persisted/history lanes continue to use their existing RPCs and are intentionally
-- not routed through this gateway.

create table if not exists english.quiz_sessions (
  session_id uuid primary key,
  user_id uuid not null,
  lane text not null,
  requested_count integer not null,
  served_count integer not null,
  strict_unseen boolean not null default false,
  created_at timestamptz not null default now(),
  completed_at timestamptz,
  answered_count integer
);

create index if not exists quiz_sessions_user_created_idx
  on english.quiz_sessions(user_id, created_at desc, session_id);
create index if not exists quiz_sessions_user_lane_created_idx
  on english.quiz_sessions(user_id, lane, created_at desc, session_id);

alter table english.quiz_sessions enable row level security;
drop policy if exists quiz_sessions_select_own on english.quiz_sessions;
create policy quiz_sessions_select_own on english.quiz_sessions
  for select to authenticated using (auth.uid() = user_id);
revoke all on english.quiz_sessions from public, anon;
revoke insert, update, delete on english.quiz_sessions from authenticated;
grant select on english.quiz_sessions to authenticated;

create table if not exists english.quiz_session_exposures (
  exposure_id bigint generated always as identity primary key,
  user_id uuid not null,
  session_id uuid not null references english.quiz_sessions(session_id) on delete cascade,
  lane text not null,
  question_id text not null,
  strict_unseen boolean not null default false,
  served_at timestamptz not null default now(),
  unique(user_id, session_id, question_id)
);

create index if not exists quiz_session_exposures_user_question_idx
  on english.quiz_session_exposures(user_id, question_id, served_at desc);
create index if not exists quiz_session_exposures_user_lane_idx
  on english.quiz_session_exposures(user_id, lane, served_at desc, question_id);

alter table english.quiz_session_exposures enable row level security;
drop policy if exists quiz_session_exposures_select_own on english.quiz_session_exposures;
create policy quiz_session_exposures_select_own on english.quiz_session_exposures
  for select to authenticated using (auth.uid() = user_id);
revoke all on english.quiz_session_exposures from public, anon;
revoke insert, update, delete on english.quiz_session_exposures from authenticated;
grant select on english.quiz_session_exposures to authenticated;

create or replace function english.request_is_local_safe()
returns boolean
language sql stable security definer
set search_path='pg_catalog','english'
as $$
  select coalesce(
    (nullif(current_setting('request.headers', true),'')::jsonb ->> 'x-english-local-safe') = '1',
    false
  );
$$;

revoke all on function english.request_is_local_safe() from public, anon, authenticated;
grant execute on function english.request_is_local_safe() to service_role;

create or replace function english.rotate_fresh_session_batch(
  p_user_id uuid,
  p_lane text,
  p_rows jsonb,
  p_limit integer,
  p_strict_unseen boolean default false,
  p_client_exclude text[] default '{}'::text[],
  p_record boolean default true
) returns jsonb
language plpgsql volatile security definer
set search_path='pg_catalog','english','auth'
as $$
declare
  v_lane text:=lower(btrim(coalesce(p_lane,'fresh')));
  v_limit integer:=greatest(1,least(1000,coalesce(p_limit,20)));
  v_session uuid:=gen_random_uuid();
  out jsonb;
begin
  if p_user_id is null then raise exception 'Authentication required'; end if;
  if v_lane='' then v_lane:='fresh'; end if;

  with expanded as (
    select e.value j,e.ordinality::int ord,
      coalesce(nullif(e.value->>'id',''),nullif(e.value->>'question_id',''),nullif(e.value->>'questionId','')) qid
    from jsonb_array_elements(coalesce(p_rows,'[]'::jsonb)) with ordinality e(value,ordinality)
  ), dedup as (
    select distinct on (qid) qid,j,ord
    from expanded
    where qid is not null
    order by qid,ord
  ), last_exposure as (
    select x.question_id,max(x.served_at) last_served
    from english.quiz_session_exposures x
    where x.user_id=p_user_id and x.question_id in (select qid from dedup)
    group by x.question_id
  ), latest_global as (
    select s.session_id from english.quiz_sessions s
    where s.user_id=p_user_id
    order by s.created_at desc,s.session_id desc limit 1
  ), latest_lane as (
    select s.session_id from english.quiz_sessions s
    where s.user_id=p_user_id and s.lane=v_lane
    order by s.created_at desc,s.session_id desc limit 1
  ), hard_sessions as (
    select session_id from latest_global
    union
    select session_id from latest_lane
  ), hard_ids as (
    select distinct x.question_id
    from english.quiz_session_exposures x join hard_sessions h using(session_id)
    where x.user_id=p_user_id
  ), annotated as (
    select d.qid,d.j,d.ord,le.last_served,s.last_attempt,
      (h.question_id is not null
       or d.qid=any(coalesce(p_client_exclude,'{}'::text[]))
       or (le.last_served is null and s.last_attempt >= now()-interval '90 minutes')) hard_recent,
      (le.last_served is not null) ever_served,
      greatest(coalesce(le.last_served,'epoch'::timestamptz),coalesce(s.last_attempt,'epoch'::timestamptz)) last_activity,
      ((d.ord-1)/v_limit)::int priority_band
    from dedup d
    left join last_exposure le on le.question_id=d.qid
    left join english.question_state s on s.user_id=p_user_id and s.question_id=d.qid
    left join hard_ids h on h.question_id=d.qid
  ), eligible as (
    select * from annotated
    where not (p_strict_unseen and (ever_served or qid=any(coalesce(p_client_exclude,'{}'::text[]))))
  ), ordered as (
    select *,row_number() over(order by
      hard_recent asc,
      ever_served asc,
      priority_band asc,
      last_activity asc,
      ord asc,
      qid
    )::int pick_ord
    from eligible
  ), picked as (
    select * from ordered where pick_ord<=v_limit
  ), session_row as (
    insert into english.quiz_sessions(session_id,user_id,lane,requested_count,served_count,strict_unseen)
    select v_session,p_user_id,v_lane,v_limit,count(*)::int,p_strict_unseen
    from picked
    having p_record and count(*)>0
    returning session_id
  ), exposure_rows as (
    insert into english.quiz_session_exposures(user_id,session_id,lane,question_id,strict_unseen)
    select p_user_id,v_session,v_lane,p.qid,p_strict_unseen
    from picked p cross join session_row s
    on conflict (user_id,session_id,question_id) do nothing
    returning exposure_id
  ), marker as (
    select count(*) recorded from exposure_rows
  )
  select coalesce(jsonb_agg(
    p.j || case when p_record then jsonb_build_object('freshSessionId',v_session::text) else '{}'::jsonb end
    order by p.pick_ord
  ),'[]'::jsonb)
  into out
  from picked p cross join marker;

  return coalesce(out,'[]'::jsonb);
end $$;

revoke all on function english.rotate_fresh_session_batch(uuid,text,jsonb,integer,boolean,text[],boolean) from public,anon,authenticated;
grant execute on function english.rotate_fresh_session_batch(uuid,text,jsonb,integer,boolean,text[],boolean) to service_role;

-- Extra Practice candidates preserve the existing priority ladder but intentionally
-- return a wider candidate window so the session rotator can avoid the last set.
create or replace function english.extra_practice_candidates(p_user_id uuid,p_count integer default 60)
returns jsonb
language plpgsql stable security definer
set search_path='pg_catalog','english'
as $$
declare
  n integer:=greatest(1,least(100,coalesce(p_count,60)));
  d date:=(now() at time zone 'Asia/Kolkata')::date;
  out jsonb;
begin
  with base as (
    select q.question_id,
      coalesce(s.status,'New') status,coalesce(s.attempts,0) attempts,coalesce(s.wrong,0) wrong,
      coalesce(s.last_marked,false) starred,coalesce(ds.difficult,false) difficult,s.last_attempt,s.next_review,
      (s.next_review is not null and s.next_review <= ((d+1)::timestamp at time zone 'Asia/Kolkata')) due,
      exists(select 1 from english.attempts a where a.user_id=p_user_id and a.question_id=q.question_id and (a.attempted_at at time zone 'Asia/Kolkata')::date=d and not a.correct) today_wrong,
      (coalesce(ds.difficult,false) and (ds.updated_at at time zone 'Asia/Kolkata')::date=d) today_difficult,
      exists(
        select 1 from english.star_events se
        where se.user_id=p_user_id and se.question_id=q.question_id and se.starred_date=d and se.action='STAR'
          and not exists(select 1 from english.star_events later where later.user_id=se.user_id and later.question_id=se.question_id and later.event_at>se.event_at and later.action='UNSTAR')
      ) today_starred
    from english.questions q
    left join english.question_state s on s.user_id=p_user_id and s.question_id=q.question_id
    left join english.difficult_state ds on ds.user_id=p_user_id and ds.question_id=q.question_id
    where q.active and english.question_visible_to_user(p_user_id,q.question_id) and not coalesce(s.mastered,false)
  ), eligible as (
    select *,case
      when today_wrong and today_difficult then 120
      when today_wrong then 115
      when today_difficult then 110
      when today_starred then 105
      when status='Persistent Weak' and due then 95
      when status='Persistent Weak' then 90
      when status='Weak' and due then 85
      when status='Weak' then 80
      when status='Fragile' and due then 75
      when due then 70
      when status='Fragile' then 65
      when difficult then 60
      else 0 end priority
    from base
    where today_wrong or today_difficult or today_starred or status in ('Persistent Weak','Weak','Fragile') or due or difficult
  ), ranked as (
    select *,row_number() over(order by priority desc,wrong desc,coalesce(next_review,'infinity'::timestamptz),coalesce(last_attempt,'epoch'::timestamptz),question_id)::int ord
    from eligible
  ), chosen as (select * from ranked order by ord limit n)
  select coalesce(jsonb_agg(
    english.question_payload(p_user_id,c.question_id)||jsonb_build_object(
      'selectionReason',case
        when c.today_wrong then 'Today''s wrong answer'
        when c.today_difficult then 'Marked Difficult today'
        when c.today_starred then 'Marked for revision today'
        when c.status='Persistent Weak' then 'Persistent Weak'
        when c.status='Weak' then 'Weak'
        when c.status='Fragile' then 'Fragile'
        when c.due then 'Due spaced revision'
        when c.difficult then 'Difficult'
        else 'Smart extra practice' end,
      'extraPractice',true
    ) order by c.ord
  ),'[]'::jsonb) into out from chosen c;
  return out;
end $$;

revoke all on function english.extra_practice_candidates(uuid,integer) from public,anon,authenticated;
grant execute on function english.extra_practice_candidates(uuid,integer) to service_role;

create or replace function english.bank_unseen_candidates(p_user_id uuid,p_category text,p_count integer default 60)
returns jsonb
language plpgsql stable security definer
set search_path='pg_catalog','english'
as $$
declare
  v_cat text:=upper(btrim(coalesce(p_category,'ALL')));
  v_n integer:=greatest(1,least(300,coalesce(p_count,60)));
  out jsonb;
begin
  with base as (
    select q.question_id,english.learning_category(q.topic) cat,
      row_number() over(partition by english.learning_category(q.topic) order by q.question_id)::int cat_ord
    from english.questions q
    left join english.question_state s on s.user_id=p_user_id and s.question_id=q.question_id
    where english.is_genuine_bank_question(q)
      and (v_cat='ALL' or english.learning_category(q.topic)=v_cat)
      and coalesce(s.attempts,0)=0 and not coalesce(s.mastered,false)
  ), chosen as (
    select question_id,row_number() over(order by case when v_cat='ALL' then cat_ord else 0 end,cat,question_id)::int ord
    from base
    order by case when v_cat='ALL' then cat_ord else 0 end,cat,question_id
    limit v_n
  )
  select coalesce(jsonb_agg(english.question_payload(p_user_id,c.question_id) order by c.ord),'[]'::jsonb)
  into out from chosen c;
  return out;
end $$;

revoke all on function english.bank_unseen_candidates(uuid,text,integer) from public,anon,authenticated;
grant execute on function english.bank_unseen_candidates(uuid,text,integer) to service_role;

create or replace function public.english_start_fresh_session(
  p_rpc text,
  p_args jsonb default '{}'::jsonb,
  p_client_exclude text[] default '{}'::text[]
) returns jsonb
language plpgsql volatile security definer
set search_path='pg_catalog','public','english','auth'
as $$
declare
  uid uuid:=auth.uid();
  a jsonb:=coalesce(p_args,'{}'::jsonb);
  rpc_name text:=btrim(coalesce(p_rpc,''));
  m text:=lower(btrim(coalesce(a->>'p_mode','all')));
  n integer;
  candidate_n integer;
  raw jsonb;
  lane text;
  strict_unseen boolean:=false;
  cat text;
  source_key text;
  source_name text;
  set_id text;
  from_day integer;
  to_day integer;
  record_session boolean;
begin
  if uid is null then raise exception 'Authentication required'; end if;
  record_session:=not english.request_is_local_safe();

  case rpc_name
    when 'english_get_revision_batch' then
      n:=greatest(1,least(100,coalesce(nullif(a->>'p_count','')::integer,30)));
      m:=lower(btrim(coalesce(a->>'p_mode','smart')));
      candidate_n:=least(100,greatest(n,n*3));
      raw:=public.english_get_revision_batch_core_20260830(m,candidate_n);
      lane:='revision:'||m;

    when 'english_get_difficult_items' then
      n:=greatest(1,least(1000,coalesce(nullif(a->>'p_count','')::integer,100)));
      candidate_n:=least(1000,greatest(n,n*3));
      raw:=public.english_get_difficult_items_core_20260830(candidate_n);
      lane:='difficult';

    when 'english_get_saved_revision_batch' then
      n:=greatest(1,least(100,coalesce(nullif(a->>'p_count','')::integer,20)));
      m:=lower(btrim(coalesce(a->>'p_mode','smart')));
      candidate_n:=least(100,greatest(n,n*3));
      lane:='saved:'||m;
      if m='new' then
        strict_unseen:=true;
        select coalesce(jsonb_agg(j order by ord),'[]'::jsonb) into raw from (
          select row_number() over(order by c.created_at desc nulls last,c.question_id)::int ord,
            english.question_payload(uid,c.question_id)||jsonb_build_object(
              'smartMySaved',true,'smartMySavedLane','new','smartMySavedReason','Never Revised in My Saved'
            ) j
          from english.saved_revision_candidates(uid)c
          where not c.mastered and c.never_revised
          order by c.created_at desc nulls last,c.question_id
          limit candidate_n
        ) x;
      else
        raw:=public.english_get_saved_revision_batch_core_20260830(m,candidate_n);
      end if;

    when 'english_get_new_practice_batch' then
      n:=greatest(1,least(100,coalesce(nullif(a->>'p_count','')::integer,10)));
      m:=lower(btrim(coalesce(a->>'p_mode','all')));
      cat:=coalesce(a->>'p_category','ALL');
      source_name:=coalesce(a->>'p_source','ALL');
      candidate_n:=least(100,greatest(n,n*3));
      raw:=public.english_get_new_practice_batch_core_20260830(cat,m,candidate_n,source_name);
      strict_unseen:=m in ('new','newwords');
      lane:='new:'||lower(cat)||':'||m||':'||lower(source_name);

    when 'english_get_topic_batch' then
      n:=greatest(1,least(120,coalesce(nullif(a->>'p_count','')::integer,20)));
      m:=lower(btrim(coalesce(a->>'p_mode','all')));
      cat:=coalesce(a->>'p_category','ALL');
      candidate_n:=least(120,greatest(n,n*3));
      raw:=public.english_get_topic_batch_core_20260830(cat,m,candidate_n);
      strict_unseen:=m='new';
      lane:='topic:'||lower(cat)||':'||m;

    when 'english_get_source_batch' then
      n:=greatest(1,least(1000,coalesce(nullif(a->>'p_count','')::integer,20)));
      m:=lower(btrim(coalesce(a->>'p_mode','all')));
      source_key:=coalesce(a->>'p_source_key','');
      candidate_n:=least(1000,greatest(n,n*3));
      raw:=public.english_get_source_batch_core_20260830(source_key,m,candidate_n);
      strict_unseen:=m='new';
      lane:='source:'||lower(source_key)||':'||m;

    when 'english_get_demand_batch' then
      n:=greatest(1,least(1000,coalesce(nullif(a->>'p_count','')::integer,20)));
      m:=lower(btrim(coalesce(a->>'p_mode','all')));
      set_id:=coalesce(a->>'p_set_id','__ALL__');
      if m='all' then raise exception 'Demand Practice All is a fixed/resume lane'; end if;
      candidate_n:=least(1000,greatest(n,n*3));
      raw:=public.english_get_demand_batch_core_20260830(set_id,m,candidate_n);
      lane:='demand:'||lower(set_id)||':'||m;

    when 'english_get_starred_batch' then
      n:=greatest(1,least(50,coalesce(nullif(a->>'p_count','')::integer,20)));
      m:=lower(btrim(coalesce(a->>'p_mode','smart')));
      from_day:=nullif(a->>'p_from_day','')::integer;
      to_day:=nullif(a->>'p_to_day','')::integer;
      candidate_n:=least(50,greatest(n,n*3));
      raw:=public.english_get_starred_batch_core_20260830(m,candidate_n,from_day,to_day);
      lane:='starred:'||m||':'||coalesce(from_day::text,'any')||':'||coalesce(to_day::text,'any');

    when 'english_get_phrasal_batch' then
      n:=greatest(1,least(100,coalesce(nullif(a->>'p_count','')::integer,20)));
      m:=lower(btrim(coalesce(a->>'p_mode','smart')));
      candidate_n:=least(100,greatest(n,n*3));
      raw:=public.english_get_phrasal_batch_core_20260830(m,candidate_n);
      lane:='phrasal:'||m;

    when 'english_get_phrasal_maintenance_batch' then
      n:=greatest(1,least(100,coalesce(nullif(a->>'p_count','')::integer,20)));
      m:=lower(btrim(coalesce(a->>'p_mode','smart')));
      candidate_n:=least(100,greatest(n,n*3));
      raw:=public.english_get_phrasal_maintenance_batch(m,candidate_n);
      lane:='phrasal-maintenance:'||m;

    when 'english_get_today_extra_batch' then
      n:=greatest(1,least(30,coalesce(nullif(a->>'p_count','')::integer,20)));
      candidate_n:=least(100,greatest(n,n*3));
      raw:=english.extra_practice_candidates(uid,candidate_n);
      lane:='extra';

    when 'english_get_bank_coverage_batch' then
      n:=greatest(1,least(100,coalesce(nullif(a->>'p_count','')::integer,10)));
      cat:=coalesce(a->>'p_category','ALL');
      candidate_n:=least(300,greatest(n,n*3));
      raw:=english.bank_unseen_candidates(uid,cat,candidate_n);
      strict_unseen:=true;
      lane:='bank-unseen:'||lower(cat);

    else
      raise exception 'RPC is not a fresh-session lane: %',rpc_name;
  end case;

  return english.rotate_fresh_session_batch(
    uid,lane,raw,n,strict_unseen,coalesce(p_client_exclude,'{}'::text[]),record_session
  );
end $$;

revoke all on function public.english_start_fresh_session(text,jsonb,text[]) from public,anon;
grant execute on function public.english_start_fresh_session(text,jsonb,text[]) to authenticated,service_role;

create or replace function public.english_complete_fresh_session(
  p_session_id uuid,
  p_answered_count integer default null
) returns jsonb
language plpgsql volatile security definer
set search_path='pg_catalog','public','english','auth'
as $$
declare
  uid uuid:=auth.uid();
  changed integer:=0;
begin
  if uid is null then raise exception 'Authentication required'; end if;
  update english.quiz_sessions
  set completed_at=coalesce(completed_at,now()),
      answered_count=case when p_answered_count is null then answered_count else greatest(0,p_answered_count) end
  where session_id=p_session_id and user_id=uid;
  get diagnostics changed=row_count;
  return jsonb_build_object('ok',changed=1,'sessionId',p_session_id);
end $$;

revoke all on function public.english_complete_fresh_session(uuid,integer) from public,anon;
grant execute on function public.english_complete_fresh_session(uuid,integer) to authenticated,service_role;
