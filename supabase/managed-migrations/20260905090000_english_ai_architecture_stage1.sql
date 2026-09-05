-- Stage 1: make the existing revision queue's lifecycle explicit without rewriting learner data.
-- `queued` + a future `next_attempt_at` is the physical representation of retry_wait.
alter table english.question_revision_proposals
  add column if not exists error_code text,
  add column if not exists lease_owner text,
  add column if not exists lease_expires_at timestamptz,
  add column if not exists model_version text,
  add column if not exists prompt_version text,
  add column if not exists input_version text,
  add column if not exists idempotency_key text;

create unique index if not exists english_revision_idempotency_key_unique
  on english.question_revision_proposals(user_id,idempotency_key)
  where idempotency_key is not null;
create index if not exists english_revision_retry_wait_idx
  on english.question_revision_proposals(next_attempt_at,created_at)
  where status='queued';

create or replace function english.revision_error_code(p_error text)
returns text language sql immutable set search_path to 'pg_catalog' as $$
  select case
    when lower(coalesce(p_error,'')) like '%timed out%' or lower(coalesce(p_error,'')) like '%abort%' then 'AI_TIMEOUT'
    when lower(coalesce(p_error,'')) like '%429%' or lower(coalesce(p_error,'')) like '%rate limit%' then 'RATE_LIMIT'
    when lower(coalesce(p_error,'')) like '%5xx%' or lower(coalesce(p_error,'')) like '% 500%' then 'PROVIDER_5XX'
    when lower(coalesce(p_error,'')) like '%network%' or lower(coalesce(p_error,'')) like '%fetch%' then 'NETWORK_TRANSIENT'
    when lower(coalesce(p_error,'')) like '%structured output%' or lower(coalesce(p_error,'')) like '%json%' then 'MALFORMED_OUTPUT'
    when lower(coalesce(p_error,'')) like '%critic rejected%' or lower(coalesce(p_error,'')) like '%toughness gate%' then 'QUALITY_REJECTED'
    when lower(coalesce(p_error,'')) like '%stale%' or lower(coalesce(p_error,'')) like '%supersed%' then 'STALE_INPUT'
    when lower(coalesce(p_error,'')) like '%unauthorized%' or lower(coalesce(p_error,'')) like '%not configured%' then 'AUTH_CONFIG'
    else 'NETWORK_TRANSIENT' end
$$;

create or replace function english.fail_question_revision(p_token text,p_proposal_id uuid,p_error text)
returns jsonb language plpgsql security definer set search_path to 'pg_catalog','english' as $$
declare r english.question_revision_proposals%rowtype; v_code text; v_final boolean;
begin
  if not english.context_worker_authorized(p_token) then raise exception 'context worker unauthorized'; end if;
  select * into r from english.question_revision_proposals where proposal_id=p_proposal_id for update;
  if not found then return jsonb_build_object('ok',false,'missing',true); end if;
  if r.status='superseded' then return jsonb_build_object('ok',true,'stale',true); end if;
  if r.status<>'processing' then return jsonb_build_object('ok',true,'ignored',true,'status',r.status); end if;
  v_code:=english.revision_error_code(p_error);
  v_final:=v_code in ('QUALITY_REJECTED','STALE_INPUT','AUTH_CONFIG') or r.attempts>=3;
  update english.question_revision_proposals set
    status=case when v_code='STALE_INPUT' then 'superseded' when v_final then 'failed' else 'queued' end,
    next_attempt_at=case when v_final then null else now()+case when r.attempts=1 then interval '2 minutes' when r.attempts=2 then interval '10 minutes' else interval '30 minutes' end end,
    error_code=case when v_final and v_code not in ('QUALITY_REJECTED','STALE_INPUT','AUTH_CONFIG') then 'RETRIES_EXHAUSTED' else v_code end,
    last_error=left((case when v_final and v_code not in ('QUALITY_REJECTED','STALE_INPUT','AUTH_CONFIG') then 'RETRIES_EXHAUSTED: ' else v_code||': ' end)||coalesce(nullif(trim(p_error),''),'background revision failed'),800),
    lease_owner=null,lease_expires_at=null,updated_at=now()
  where proposal_id=p_proposal_id;
  return jsonb_build_object('ok',true,'retry',not v_final,'errorCode',v_code,'attempts',r.attempts);
end $$;
revoke all on function english.fail_question_revision(text,uuid,text) from public,anon,authenticated;
grant execute on function english.fail_question_revision(text,uuid,text) to service_role;
create or replace function public.english_fail_question_revision(p_token text,p_proposal_id uuid,p_error text)
returns jsonb language sql security definer set search_path to 'pg_catalog','public','english' as $$ select english.fail_question_revision(p_token,p_proposal_id,p_error) $$;
revoke all on function public.english_fail_question_revision(text,uuid,text) from public,anon,authenticated;
grant execute on function public.english_fail_question_revision(text,uuid,text) to service_role;

-- Dedicated worker ownership bridge. The underlying claim retains row locking and
-- lease recovery; this named contract prevents the learning worker from claiming it.
create or replace function english.question_revision_claim_dedicated(p_token text,p_limit integer default 1)
returns jsonb language sql security definer set search_path to 'pg_catalog','english'
as $$ select english.question_revision_claim(p_token,least(greatest(coalesce(p_limit,1),1),1)) $$;
revoke all on function english.question_revision_claim_dedicated(text,integer) from public,anon,authenticated;
grant execute on function english.question_revision_claim_dedicated(text,integer) to service_role;
create or replace function public.english_question_revision_claim_dedicated(p_token text,p_limit integer default 1)
returns jsonb language sql security definer set search_path to 'pg_catalog','public','english'
as $$ select english.question_revision_claim_dedicated(p_token,p_limit) $$;
revoke all on function public.english_question_revision_claim_dedicated(text,integer) from public,anon,authenticated;
grant execute on function public.english_question_revision_claim_dedicated(text,integer) to service_role;
