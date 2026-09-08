-- English AI reliability hotfix:
-- 1) align Antigravity daily accounting with the provider's Pacific quota day;
-- 2) respect provider Retry-After style 429 cooldowns instead of blocking until IST midnight;
-- 3) distinguish temporary cooldowns (retry later, do not burn fallback quota) from daily exhaustion;
-- 4) remove hour-long retry slippage with lightweight 5-minute recovery checks.

create or replace function public.english_claim_antigravity_request_budget()
returns jsonb
language plpgsql
security definer
set search_path to pg_catalog, public, english, auth
as $function$
declare
  v_day date := (now() at time zone 'America/Los_Angeles')::date;
  v_day_start timestamptz := (v_day::timestamp at time zone 'America/Los_Angeles');
  v_next_reset timestamptz := (((v_day + 1)::timestamp) at time zone 'America/Los_Angeles');
  r english.ai_provider_daily_budget%rowtype;
  v_limit integer;
  v_used integer;
  v_route text;
begin
  if auth.role() <> 'service_role' then raise exception 'Service role required'; end if;

  insert into english.ai_provider_daily_budget(
    budget_date,provider,max_requests,reserve_requests,observed_used,internal_claims
  ) values(v_day,'antigravity',100,0,0,0)
  on conflict (budget_date,provider) do nothing;

  select * into r
  from english.ai_provider_daily_budget
  where budget_date=v_day and provider='antigravity'
  for update;

  -- One-time/self-healing bridge for rows created by the previous IST-day guard.
  -- If this calendar-date row was last touched before the current Pacific quota day
  -- began, none of those claims belong to the provider's current daily window.
  if coalesce(r.last_claimed_at,'-infinity'::timestamptz) < v_day_start
     and coalesce(r.updated_at,'-infinity'::timestamptz) < v_day_start then
    update english.ai_provider_daily_budget
    set observed_used=0,
        internal_claims=0,
        blocked_until=null,
        block_reason=null,
        last_claimed_at=null,
        updated_at=now()
    where budget_date=v_day and provider='antigravity';

    select * into r
    from english.ai_provider_daily_budget
    where budget_date=v_day and provider='antigravity'
    for update;
  end if;

  if r.blocked_until is not null and r.blocked_until > now() then
    v_route := case when coalesce(r.block_reason,'') like 'TEMPORARY:%' then 'retry' else 'gemini' end;
    return jsonb_build_object(
      'allowed',false,'route',v_route,
      'reason',coalesce(r.block_reason,'antigravity circuit open'),
      'blockedUntil',r.blocked_until,
      'providerDay',v_day,
      'providerResetAt',v_next_reset,
      'used',r.observed_used+r.internal_claims,
      'reserve',r.reserve_requests
    );
  end if;

  v_limit := greatest(0,r.max_requests-r.reserve_requests);
  v_used := r.observed_used+r.internal_claims;
  if v_used >= v_limit then
    return jsonb_build_object(
      'allowed',false,'route','gemini','reason','ANTIGRAVITY_BUDGET_RESERVED',
      'used',v_used,'limitBeforeReserve',v_limit,'reserve',r.reserve_requests,
      'providerDay',v_day,'providerResetAt',v_next_reset
    );
  end if;

  update english.ai_provider_daily_budget
  set internal_claims=internal_claims+1,last_claimed_at=now(),updated_at=now()
  where budget_date=v_day and provider='antigravity';

  return jsonb_build_object(
    'allowed',true,'route','antigravity','usedAfterClaim',v_used+1,
    'limitBeforeReserve',v_limit,
    'remainingBeforeReserve',greatest(0,v_limit-(v_used+1)),
    'reserve',r.reserve_requests,
    'providerDay',v_day,'providerResetAt',v_next_reset
  );
end
$function$;

create or replace function public.english_mark_antigravity_quota_exhausted(p_reason text default null)
returns jsonb
language plpgsql
security definer
set search_path to pg_catalog, public, english, auth
as $function$
declare
  v_day date := (now() at time zone 'America/Los_Angeles')::date;
  v_next_reset timestamptz := (((v_day + 1)::timestamp) at time zone 'America/Los_Angeles');
  v_reason text := left(coalesce(nullif(btrim(p_reason),''),'ANTIGRAVITY_429'),760);
  v_reason_lower text := lower(coalesce(p_reason,''));
  v_retry_text text;
  v_retry_seconds numeric;
  v_until timestamptz;
  v_kind text;
  v_route text;
begin
  if auth.role() <> 'service_role' then raise exception 'Service role required'; end if;

  -- Google commonly includes an exact `retry in 51.7s` hint. Respect it.
  v_retry_text := substring(v_reason_lower from 'retry in[[:space:]]+([0-9]+[.]?[0-9]*)[[:space:]]*s');
  if v_retry_text is not null then
    v_retry_seconds := greatest(0,v_retry_text::numeric);
    v_until := least(
      v_next_reset,
      now()+make_interval(secs => least(86400::numeric,greatest(15::numeric,v_retry_seconds+5))::double precision)
    );
    if v_until >= v_next_reset-interval '90 seconds' then
      v_kind:='DAILY'; v_route:='gemini';
    else
      v_kind:='TEMPORARY'; v_route:='retry';
    end if;
  elsif v_reason_lower like '%per day%'
     or v_reason_lower like '%requests per day%'
     or v_reason_lower like '%daily quota%'
     or v_reason_lower like '% rpd %' then
    v_until:=v_next_reset;
    v_kind:='DAILY'; v_route:='gemini';
  else
    -- Unknown 429: fail conservatively with a short circuit breaker, not an all-day block.
    v_until:=least(v_next_reset,now()+interval '5 minutes');
    v_kind:='TEMPORARY'; v_route:='retry';
  end if;

  insert into english.ai_provider_daily_budget(
    budget_date,provider,max_requests,reserve_requests,observed_used,internal_claims,
    blocked_until,block_reason,updated_at
  ) values(
    v_day,'antigravity',100,0,0,0,v_until,left(v_kind||': '||v_reason,800),now()
  )
  on conflict (budget_date,provider) do update
  set internal_claims=greatest(english.ai_provider_daily_budget.internal_claims-1,0),
      blocked_until=case
        when english.ai_provider_daily_budget.blocked_until>now()
         and coalesce(english.ai_provider_daily_budget.block_reason,'') like 'DAILY:%'
         and v_kind='TEMPORARY'
        then english.ai_provider_daily_budget.blocked_until
        else excluded.blocked_until
      end,
      block_reason=case
        when english.ai_provider_daily_budget.blocked_until>now()
         and coalesce(english.ai_provider_daily_budget.block_reason,'') like 'DAILY:%'
         and v_kind='TEMPORARY'
        then english.ai_provider_daily_budget.block_reason
        else excluded.block_reason
      end,
      updated_at=now();

  return jsonb_build_object(
    'ok',true,'kind',v_kind,'route',v_route,'blockedUntil',v_until,
    'providerDay',v_day,'providerResetAt',v_next_reset
  );
end
$function$;

-- Immediately heal the current legacy row only when every recorded claim predates
-- the provider's current Pacific quota window. This restores real quota without
-- fabricating capacity when any current-window request has already been claimed.
do $do$
declare
  v_day date := (now() at time zone 'America/Los_Angeles')::date;
  v_day_start timestamptz := (v_day::timestamp at time zone 'America/Los_Angeles');
begin
  update english.ai_provider_daily_budget
  set observed_used=0,
      internal_claims=0,
      blocked_until=null,
      block_reason=null,
      last_claimed_at=null,
      updated_at=now()
  where budget_date=v_day
    and provider='antigravity'
    and coalesce(last_claimed_at,'-infinity'::timestamptz)<v_day_start
    and coalesce(updated_at,'-infinity'::timestamptz)<v_day_start;
end
$do$;

create or replace function english.kick_saved_enrichment_recovery_if_needed()
returns bigint
language plpgsql
security definer
set search_path to pg_catalog, english
as $function$
declare
  v_busy boolean:=false;
  v_due boolean:=false;
begin
  perform english.reconcile_saved_enrichment_worker_http();

  select coalesce(lease_id is not null and lease_expires_at>now(),false)
  into v_busy
  from english.saved_enrichment_worker_state
  where singleton=true;

  if v_busy then return null; end if;

  select exists(
    select 1
    from english.saved_enrichment_item_state es
    join english.saved_items s on s.user_id=es.user_id and s.saved_id=es.saved_id and s.active
    where (es.state='retrying' and (es.next_attempt_at is null or es.next_attempt_at<=now()))
       or (es.state='processing' and es.updated_at<now()-interval '12 minutes')
  ) into v_due;

  if v_due then return english.kick_saved_enrichment_worker(3); end if;
  return null;
end
$function$;

revoke all on function english.kick_saved_enrichment_recovery_if_needed() from public;
grant execute on function english.kick_saved_enrichment_recovery_if_needed() to service_role;

-- Phrasal recovery is due-aware, so a 5-minute check does not spend AI quota unless
-- a slot is actually eligible. Preserve the existing job name for observability.
do $do$
declare r record;
begin
  for r in select jobid from cron.job where jobname='english-phrasal-hourly-recovery' loop
    perform cron.unschedule(r.jobid);
  end loop;
  perform cron.schedule(
    'english-phrasal-hourly-recovery','*/5 * * * *',
    $cmd$select english.kick_phrasal_recovery_if_needed();$cmd$
  );

  for r in select jobid from cron.job where jobname='english-saved-enrichment-recovery' loop
    perform cron.unschedule(r.jobid);
  end loop;
  perform cron.schedule(
    'english-saved-enrichment-recovery','*/5 * * * *',
    $cmd$select english.kick_saved_enrichment_recovery_if_needed();$cmd$
  );
end
$do$;
