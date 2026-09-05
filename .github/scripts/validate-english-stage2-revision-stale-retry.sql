\set ON_ERROR_STOP on
create extension if not exists pgcrypto;
create schema if not exists auth;
create schema if not exists english;
do $$ begin
  if not exists(select 1 from pg_roles where rolname='anon') then create role anon nologin; end if;
  if not exists(select 1 from pg_roles where rolname='authenticated') then create role authenticated nologin; end if;
  if not exists(select 1 from pg_roles where rolname='service_role') then create role service_role nologin; end if;
end $$;

create table english.question_revision_proposals(
  proposal_id uuid primary key default gen_random_uuid(),
  status text not null,
  claimed_at timestamptz,
  attempts integer not null default 0,
  next_attempt_at timestamptz,
  last_error text,
  error_code text,
  lease_owner text,
  lease_expires_at timestamptz,
  updated_at timestamptz not null default now()
);

create or replace function english.context_worker_authorized(text)
returns boolean language sql stable as $$ select true $$;

create or replace function english.question_revision_claim(p_token text,p_limit integer default 1)
returns jsonb language plpgsql security definer set search_path to 'pg_catalog','english' as $$
declare outv jsonb;
begin
  with pick as (
    select proposal_id from english.question_revision_proposals
    where status='queued' and attempts<3 and (next_attempt_at is null or next_attempt_at<=now())
    order by updated_at,proposal_id for update skip locked limit greatest(1,least(1,coalesce(p_limit,1)))
  ), upd as (
    update english.question_revision_proposals p
    set status='processing',attempts=p.attempts+1,claimed_at=now(),last_error=null,updated_at=now()
    from pick where p.proposal_id=pick.proposal_id returning p.proposal_id
  )
  select jsonb_build_object('items',coalesce(jsonb_agg(jsonb_build_object('proposalId',proposal_id)),'[]'::jsonb))
  into outv from upd;
  return outv;
end $$;

\ir ../../supabase/managed-migrations/20260905112000_english_revision_stale_retry_classification.sql

insert into english.question_revision_proposals(proposal_id,status,claimed_at,attempts,last_error,error_code,updated_at)
values
 ('11111111-1111-1111-1111-111111111111','processing',now()-interval '10 minutes',2,'old timeout','AI_TIMEOUT',now()-interval '10 minutes'),
 ('22222222-2222-2222-2222-222222222222','processing',now()-interval '10 minutes',3,'old timeout','AI_TIMEOUT',now()-interval '10 minutes');

do $$ declare outv jsonb; retry_status text; retry_code text; retry_attempts int; final_status text; final_code text; begin
  outv:=english.question_revision_claim_dedicated('token',1);
  select status,error_code,attempts into retry_status,retry_code,retry_attempts
  from english.question_revision_proposals where proposal_id='11111111-1111-1111-1111-111111111111';
  select status,error_code into final_status,final_code
  from english.question_revision_proposals where proposal_id='22222222-2222-2222-2222-222222222222';

  if retry_status<>'processing' or retry_attempts<>3 then
    raise exception 'stale retry was not actively reclaimed: status %, attempts %, out %',retry_status,retry_attempts,outv;
  end if;
  if retry_code is not null then
    raise exception 'active retry retained stale transient code: %',retry_code;
  end if;
  if final_status<>'failed' or final_code<>'RETRIES_EXHAUSTED' then
    raise exception 'third stale attempt was not typed terminal failure: status %, code %',final_status,final_code;
  end if;
end $$;

select 'English Stage-2 revision stale/retry classification regression passed' result;
