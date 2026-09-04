-- English V2 P1 reliability hardening.
-- Scope: Targeted freshness/cooldown, Hindu Daily exposure boundary,
-- context-worker fair scheduling/recovery, and failure-safe scheduler telemetry.

-- ================================================================
-- Targeted exact-question cooldown and fresh-session delivery
-- ================================================================

create or replace function english.targeted_question_in_cooldown(
  p_user_id uuid,
  p_question_id text,
  p_concept_next_review timestamptz default null
) returns boolean
language sql
stable
security definer
set search_path to 'pg_catalog','english','auth'
as $$
with last_attempt as (
  select a.correct,a.attempted_at
  from english.attempts a
  where a.user_id=p_user_id and a.question_id=p_question_id
  order by a.attempted_at desc,a.attempt_id desc
  limit 1
)
select coalesce((
  select case
    when l.correct then
      case
        when p_concept_next_review is not null then now()<p_concept_next_review
        else now()<l.attempted_at+interval '8 hours'
      end
    else now()<l.attempted_at+interval '90 minutes'
  end
  from last_attempt l
),false);
$$;

create or replace function english.targeted_recent_session_excludes(p_user_id uuid)
returns text[]
language sql
stable
security definer
set search_path to 'pg_catalog','english','auth'
as $$
with s as (
  select session_id
  from english.quiz_sessions
  where user_id=p_user_id
    and lane like 'targeted:%'
    and created_at>=now()-interval '90 minutes'
  order by created_at desc,session_id desc
  limit 1
)
select coalesce(array_agg(e.question_id order by e.question_id),'{}'::text[])
from english.quiz_session_exposures e
join s on s.session_id=e.session_id
where e.user_id=p_user_id;
$$;

create or replace function english.targeted_filter_batch(
  p_user_id uuid,
  p_rows jsonb,
  p_count integer,
  p_exclude text[] default '{}'::text[]
) returns jsonb
language plpgsql
stable
security definer
set search_path to 'pg_catalog','english','auth'
as $$
declare
  item jsonb;
  qid text;
  cid text;
  kind text;
  next_review timestamptz;
  alt text;
  meta jsonb;
  outv jsonb:='[]'::jsonb;
  n integer:=greatest(1,least(30,coalesce(p_count,15)));
  excludes text[]:=coalesce(p_exclude,'{}'::text[]);
begin
  if p_user_id is null then raise exception 'Authentication required'; end if;

  for item in select value from jsonb_array_elements(coalesce(p_rows,'[]'::jsonb)) loop
    exit when jsonb_array_length(outv)>=n;
    qid:=coalesce(nullif(item->>'id',''),nullif(item->>'question_id',''),nullif(item->>'questionId',''));
    cid:=nullif(item->>'conceptId','');
    kind:=lower(coalesce(item->>'targetedKind','need_learning'));
    begin
      next_review:=nullif(item->>'conceptNextReview','')::timestamptz;
    exception when others then
      next_review:=null;
    end;
    if qid is null then continue; end if;

    alt:=null;
    if qid=any(excludes) or english.targeted_question_in_cooldown(p_user_id,qid,next_review) then
      if cid is not null and kind in('confusion','transfer_check','need_learning') then
        select q2.question_id into alt
        from english.questions q2
        join english.question_concept_mappings m2 on m2.question_id=q2.question_id
        left join english.question_state s2 on s2.user_id=p_user_id and s2.question_id=q2.question_id
        left join english.question_quality_metrics qm2 on qm2.user_id=p_user_id and qm2.question_id=q2.question_id
        where m2.concept_id=cid
          and q2.active
          and english.question_visible_to_user(p_user_id,q2.question_id)
          and q2.question_id<>qid
          and not(q2.question_id=any(excludes))
          and not coalesce(s2.mastered,false)
          and not english.targeted_question_in_cooldown(p_user_id,q2.question_id,next_review)
          and not exists(
            select 1 from jsonb_array_elements(outv) z
            where coalesce(z->>'id',z->>'question_id',z->>'questionId')=q2.question_id
          )
        order by
          coalesce(qm2.too_easy,false),
          coalesce(qm2.observed_difficulty,0.5) desc,
          coalesce(s2.last_attempt,'epoch'::timestamptz),
          q2.question_id
        limit 1;
      end if;

      -- Never force-fill by replaying the same exact item. Underfill is safer.
      if alt is null then continue; end if;
      meta:=item-array[
        'id','question_id','questionId','category','topic','word','question','options',
        'correctKey','correct_key','explanation','questionType','question_type','subtopic','difficulty'
      ]::text[];
      item:=english.question_payload(p_user_id,alt)||meta||jsonb_build_object('deliveryAlternate',true);
      qid:=alt;
    end if;

    if not(qid=any(excludes))
       and not exists(
         select 1 from jsonb_array_elements(outv) z
         where coalesce(z->>'id',z->>'question_id',z->>'questionId')=qid
       ) then
      outv:=outv||jsonb_build_array(item);
    end if;
  end loop;
  return outv;
end $$;

create or replace function public.english_start_targeted_fresh_session(
  p_count integer default 15,
  p_kind text default null,
  p_confusion_id uuid default null,
  p_session_nonce text default null,
  p_client_exclude text[] default '{}'::text[],
  p_due_only boolean default false
) returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','public','english','auth'
as $$
declare
  uid uuid:=auth.uid();
  n integer:=greatest(1,least(30,coalesce(p_count,15)));
  base jsonb;
  cooled jsonb;
  lane text;
  recent text[];
  excludes text[];
  record_session boolean;
begin
  if uid is null then raise exception 'Authentication required'; end if;

  perform set_config(
    'english.targeted_session_nonce',
    coalesce(nullif(trim(coalesce(p_session_nonce,'')),''),md5(clock_timestamp()::text||uid::text)),
    true
  );
  record_session:=not english.request_is_local_safe();
  base:=public.english_get_targeted_batch(30,p_kind,p_confusion_id);

  if coalesce(p_due_only,false) then
    select coalesce(jsonb_agg(e.item order by e.ord),'[]'::jsonb) into base
    from jsonb_array_elements(coalesce(base,'[]'::jsonb)) with ordinality e(item,ord)
    where e.item->>'targetedKind'='confusion'
       or nullif(e.item->>'conceptNextReview','') is null
       or (e.item->>'conceptNextReview')::timestamptz<=now();
  end if;

  recent:=english.targeted_recent_session_excludes(uid);
  select coalesce(array_agg(distinct x),'{}'::text[]) into excludes
  from unnest(coalesce(p_client_exclude,'{}'::text[])||coalesce(recent,'{}'::text[])) x
  where btrim(coalesce(x,''))<>'';

  cooled:=english.targeted_filter_batch(uid,base,30,excludes);
  lane:='targeted:'||case
    when coalesce(p_due_only,false) then 'due'
    else coalesce(lower(nullif(trim(p_kind),'')),'all')
  end||':'||coalesce(p_confusion_id::text,'all');

  return english.rotate_fresh_session_batch(uid,lane,cooled,n,false,'{}'::text[],record_session);
end $$;

create or replace function public.english_get_targeted_due_session(
  p_count integer default 15,
  p_session_nonce text default null
) returns jsonb
language sql
security definer
set search_path to 'pg_catalog','public','english','auth'
as $$
  select public.english_start_targeted_fresh_session(p_count,null,null,p_session_nonce,'{}'::text[],true);
$$;

create or replace function public.english_get_targeted_session(
  p_count integer default 15,
  p_kind text default null,
  p_confusion_id uuid default null,
  p_session_nonce text default null
) returns jsonb
language sql
security definer
set search_path to 'pg_catalog','public','english','auth'
as $$
  select public.english_start_targeted_fresh_session(p_count,p_kind,p_confusion_id,p_session_nonce,'{}'::text[],false);
$$;

create or replace function public.english_get_targeted_question(p_question_id text)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'pg_catalog','public','english','auth'
as $$
declare
  uid uuid:=auth.uid();
  qid text:=btrim(coalesce(p_question_id,''));
  base jsonb;
  cid text;
  nr timestamptz;
  kind text;
  reason text;
begin
  if uid is null then raise exception 'Authentication required'; end if;
  if qid='' then return '[]'::jsonb; end if;

  select m.concept_id,ce.next_review,english.targeted_route_kind(r.metadata,r.origins),r.last_route_reason
    into cid,nr,kind,reason
  from english.learning_route_state r
  join english.questions q on q.question_id=r.question_id
    and q.active and english.question_visible_to_user(uid,q.question_id)
  left join english.question_concept_mappings m on m.question_id=r.question_id
  left join english.concept_evidence ce on ce.user_id=uid and ce.concept_id=m.concept_id
  where r.user_id=uid and r.route='targeted' and r.question_id=qid
  limit 1;

  if not found then return '[]'::jsonb; end if;
  base:=jsonb_build_array(
    english.question_payload(uid,qid)||jsonb_build_object(
      'learningRoute','targeted','targetedKind',kind,'targetedReason',reason,
      'sourceQuestionId',qid,'conceptId',cid,'conceptNextReview',nr
    )
  );
  return english.targeted_filter_batch(uid,base,1,'{}'::text[]);
end $$;

-- ================================================================
-- Hindu is exposure-only for Daily until explicit retain action
-- ================================================================

create or replace function english.hindu_daily_eligible(p_user_id uuid,p_question_id text)
returns boolean
language sql
stable
security definer
set search_path to 'pg_catalog','english','auth'
as $$
select case
  when not exists(
    select 1
    from english.questions q
    where q.question_id=p_question_id
      and (
        lower(coalesce(q.topic,''))='the hindu vocabulary'
        or upper(coalesce(q.source_id,'')) like 'HINDU_%'
      )
  ) then true
  else exists(
    select 1
    from english.hindu_vocab_registry r
    where r.user_id=p_user_id
      and r.question_id=p_question_id
      and r.active
      and (coalesce(r.marked,false) or coalesce(r.in_vocab,false))
  )
end;
$$;

create or replace function english.guard_hindu_daily_exposure()
returns trigger
language plpgsql
security definer
set search_path to 'pg_catalog','english','auth'
as $$
begin
  if not english.hindu_daily_eligible(new.user_id,new.question_id) then
    if tg_op='UPDATE' then return old; end if;
    return null;
  end if;
  return new;
end $$;

drop trigger if exists daily_hindu_exposure_guard on english.daily_current;
create trigger daily_hindu_exposure_guard
before insert or update of user_id,question_id on english.daily_current
for each row execute function english.guard_hindu_daily_exposure();

create or replace function english.prune_hindu_daily_if_exposure_only()
returns trigger
language plpgsql
security definer
set search_path to 'pg_catalog','english','auth'
as $$
begin
  if new.question_id is not null
     and (not coalesce(new.active,false) or (not coalesce(new.marked,false) and not coalesce(new.in_vocab,false))) then
    delete from english.daily_current d
    where d.user_id=new.user_id
      and d.question_id=new.question_id
      and d.quiz_date >= (now() at time zone 'Asia/Kolkata')::date
      and not exists(
        select 1 from english.attempts a
        where a.user_id=d.user_id and a.question_id=d.question_id
          and lower(coalesce(a.module,''))='daily'
          and (a.attempted_at at time zone 'Asia/Kolkata')::date=d.quiz_date
      );
  end if;
  return new;
end $$;

drop trigger if exists hindu_daily_exposure_guard on english.hindu_vocab_registry;
create trigger hindu_daily_exposure_guard
after insert or update of marked,in_vocab,active,question_id on english.hindu_vocab_registry
for each row execute function english.prune_hindu_daily_if_exposure_only();

-- Reconcile only current/future unattempted leakage; never rewrite history.
delete from english.daily_current d
where d.quiz_date >= (now() at time zone 'Asia/Kolkata')::date
  and not english.hindu_daily_eligible(d.user_id,d.question_id)
  and not exists(
    select 1 from english.attempts a
    where a.user_id=d.user_id and a.question_id=d.question_id
      and lower(coalesce(a.module,''))='daily'
      and (a.attempted_at at time zone 'Asia/Kolkata')::date=d.quiz_date
  );

create index if not exists english_hindu_daily_eligibility_idx
  on english.hindu_vocab_registry(user_id,question_id,active,marked,in_vocab);

-- ================================================================
-- Fair context-worker scheduling, bounded recovery, and HTTP telemetry
-- ================================================================

create table if not exists english.worker_scheduler_state(
  singleton boolean primary key default true check(singleton),
  last_lane text,
  active_lane text,
  active_until timestamptz,
  updated_at timestamptz not null default now()
);
insert into english.worker_scheduler_state(singleton,last_lane,active_lane,active_until)
values(true,null,null,null)
on conflict(singleton) do nothing;

create table if not exists english.context_worker_requests(
  request_id bigint primary key,
  lane text not null,
  requested_at timestamptz not null default now(),
  reconciled_at timestamptz
);

create or replace function english.worker_lane_allowed(p_lane text)
returns boolean
language sql
stable
security definer
set search_path to 'pg_catalog','english'
as $$
select coalesce((
  select s.active_lane=lower(btrim(coalesce(p_lane,''))) and s.active_until>now()
  from english.worker_scheduler_state s
  where s.singleton=true
),false);
$$;

-- Gate the existing worker's fixed Transfer -> Revision -> Quality claim order.
-- The scheduler picks one non-context lane, so each queue gets a fair turn.
create or replace function public.english_transfer_claim(p_token text,p_limit integer default 1)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','public','english'
as $$
begin
  if not english.context_worker_authorized(p_token) then raise exception 'context worker unauthorized'; end if;
  if not english.worker_lane_allowed('transfer') then return jsonb_build_object('items','[]'::jsonb); end if;
  return english.transfer_claim(p_token,p_limit);
end $$;

create or replace function public.english_question_revision_claim(p_token text,p_limit integer default 1)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','public','english'
as $$
begin
  if not english.context_worker_authorized(p_token) then raise exception 'context worker unauthorized'; end if;
  if not english.worker_lane_allowed('revision') then return jsonb_build_object('items','[]'::jsonb); end if;
  return english.question_revision_claim(p_token,p_limit);
end $$;

create or replace function public.english_question_quality_review_claim(p_token text,p_limit integer default 1)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','public','english'
as $$
begin
  if not english.context_worker_authorized(p_token) then raise exception 'context worker unauthorized'; end if;
  if not english.worker_lane_allowed('quality_review') then return jsonb_build_object('items','[]'::jsonb); end if;
  return english.question_quality_review_claim(p_token,p_limit);
end $$;

create or replace function english.reconcile_context_worker_http()
returns integer
language plpgsql
security definer
set search_path to 'pg_catalog','english','net'
as $$
declare n integer:=0;
begin
  with ready as (
    update english.context_worker_requests r
    set reconciled_at=now()
    from net._http_response h
    where r.reconciled_at is null and h.id=r.request_id
    returning r.request_id,r.lane,r.requested_at,h.status_code,h.timed_out,h.error_msg,h.created
  ), ins as (
    insert into english.worker_observability(worker,metrics,elapsed_ms)
    select
      'english-context-worker',
      jsonb_strip_nulls(jsonb_build_object(
        'source','scheduler_http',
        'requestId',request_id,
        'lane',lane,
        'statusCode',status_code,
        'timedOut',coalesce(timed_out,false),
        'error',nullif(left(coalesce(error_msg,''),500),'')
      )),
      greatest(0,least(2147483647,(extract(epoch from (created-requested_at))*1000)::bigint))::integer
    from ready
    returning event_id
  )
  select count(*) into n from ins;

  delete from english.context_worker_requests where requested_at<now()-interval '45 days';
  return n;
end $$;

create or replace function english.kick_context_worker(
  p_context_limit integer default 6,
  p_transfer_limit integer default 1
) returns bigint
language plpgsql
security definer
set search_path to 'pg_catalog','english','vault','net'
as $$
declare
  base text;
  token text;
  req bigint;
  has_context boolean:=false;
  has_transfer boolean:=false;
  has_revision boolean:=false;
  has_quality boolean:=false;
  prev_lane text;
  chosen_lane text;
begin
  perform english.reconcile_context_worker_http();

  -- Recover abandoned leases; terminate exhausted retries instead of churning forever.
  update english.learner_context_notes
  set ai_status='queued',ai_next_attempt_at=now(),ai_error='stale background processing recovered'
  where ai_status='processing' and ai_attempted_at<now()-interval '5 minutes' and ai_attempts<3;
  update english.learner_context_notes
  set ai_status='failed',ai_next_attempt_at=null,ai_error=coalesce(ai_error,'background processing retries exhausted')
  where ai_status='processing' and ai_attempted_at<now()-interval '5 minutes' and ai_attempts>=3;

  update english.targeted_transfer_jobs
  set status='queued',next_attempt_at=now(),last_error='stale generation recovered',updated_at=now()
  where status='processing' and updated_at<now()-interval '5 minutes' and attempts<3;
  update english.targeted_transfer_jobs
  set status='failed',next_attempt_at=null,last_error=coalesce(last_error,'transfer generation retries exhausted'),updated_at=now()
  where status='processing' and updated_at<now()-interval '5 minutes' and attempts>=3;

  update english.question_revision_proposals
  set status='queued',next_attempt_at=now(),last_error='stale background processing recovered',updated_at=now()
  where status='processing' and claimed_at<now()-interval '5 minutes' and attempts<3;
  update english.question_revision_proposals
  set status='failed',next_attempt_at=null,last_error=coalesce(last_error,'background processing exhausted retries'),updated_at=now()
  where status='processing' and claimed_at<now()-interval '5 minutes' and attempts>=3;

  update english.question_quality_reviews
  set status='queued',next_attempt_at=now(),last_error='stale review recovered',updated_at=now()
  where status='processing' and claimed_at<now()-interval '5 minutes' and attempts<3;
  update english.question_quality_reviews
  set status='failed',next_attempt_at=null,last_error=coalesce(last_error,'review retries exhausted'),updated_at=now()
  where status='processing' and claimed_at<now()-interval '5 minutes' and attempts>=3;

  select exists(
    select 1 from english.learner_context_notes
    where processing_status='done' and ai_status='queued' and ai_attempts<3
      and (ai_next_attempt_at is null or ai_next_attempt_at<=now())
  ) into has_context;
  select exists(
    select 1 from english.targeted_transfer_jobs
    where status='queued' and attempts<3 and (next_attempt_at is null or next_attempt_at<=now())
  ) into has_transfer;
  select exists(
    select 1 from english.question_revision_proposals
    where status='queued' and attempts<3 and (next_attempt_at is null or next_attempt_at<=now())
  ) into has_revision;
  select exists(
    select 1 from english.question_quality_reviews
    where status='queued' and attempts<3 and (next_attempt_at is null or next_attempt_at<=now())
  ) into has_quality;

  select s.last_lane into prev_lane
  from english.worker_scheduler_state s
  where s.singleton=true
  for update;

  if prev_lane='transfer' then
    if has_revision then chosen_lane:='revision';
    elsif has_quality then chosen_lane:='quality_review';
    elsif has_transfer then chosen_lane:='transfer'; end if;
  elsif prev_lane='revision' then
    if has_quality then chosen_lane:='quality_review';
    elsif has_transfer then chosen_lane:='transfer';
    elsif has_revision then chosen_lane:='revision'; end if;
  elsif prev_lane='quality_review' then
    if has_transfer then chosen_lane:='transfer';
    elsif has_revision then chosen_lane:='revision';
    elsif has_quality then chosen_lane:='quality_review'; end if;
  else
    if has_transfer then chosen_lane:='transfer';
    elsif has_revision then chosen_lane:='revision';
    elsif has_quality then chosen_lane:='quality_review'; end if;
  end if;

  if not has_context and chosen_lane is null then
    update english.worker_scheduler_state
    set active_lane=null,active_until=null,updated_at=now()
    where singleton=true;
    return null;
  end if;

  update english.worker_scheduler_state
  set last_lane=coalesce(chosen_lane,last_lane),
      active_lane=coalesce(chosen_lane,'none'),
      active_until=now()+interval '2 minutes',
      updated_at=now()
  where singleton=true;

  select decrypted_secret into base
  from vault.decrypted_secrets
  where name='english_project_url'
  order by created_at desc limit 1;
  select decrypted_secret into token
  from vault.decrypted_secrets
  where name='english_context_worker_token'
  order by created_at desc limit 1;
  if nullif(base,'') is null or nullif(token,'') is null then
    raise exception 'context worker secrets are not configured';
  end if;

  select net.http_post(
    url:=rtrim(base,'/')||'/functions/v1/english-context-worker',
    headers:=jsonb_build_object('Content-Type','application/json','x-english-context-token',token),
    body:=jsonb_build_object(
      'contextLimit',greatest(1,least(8,coalesce(p_context_limit,6))),
      'transferLimit',greatest(1,least(2,coalesce(p_transfer_limit,1))),
      'revisionLimit',1,
      'reviewLimit',1
    ),
    timeout_milliseconds:=28000
  ) into req;

  insert into english.context_worker_requests(request_id,lane,requested_at)
  values(req,coalesce(chosen_lane,'context'),now())
  on conflict(request_id) do nothing;
  return req;
end $$;

create index if not exists english_context_ai_queue_idx
  on english.learner_context_notes(ai_status,ai_next_attempt_at,created_at)
  where ai_status in ('queued','processing');
create index if not exists english_context_worker_requests_pending_idx
  on english.context_worker_requests(reconciled_at,requested_at)
  where reconciled_at is null;
