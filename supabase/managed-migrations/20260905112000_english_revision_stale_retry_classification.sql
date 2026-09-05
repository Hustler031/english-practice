-- Stage 2 audit remediation: dedicated Revision ownership must also own stale-processing
-- recovery semantics. The legacy generic claim recovers stale rows but does not populate
-- the typed error_code added in Stage 1. Normalize stale rows before delegating, then
-- clear transient error state once a retry is actively claimed again.

create or replace function english.question_revision_claim_dedicated(p_token text,p_limit integer default 1)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','english'
as $function$
declare
  outv jsonb;
begin
  if not english.context_worker_authorized(p_token) then
    raise exception 'context worker unauthorized';
  end if;

  update english.question_revision_proposals
  set status='queued',
      next_attempt_at=now(),
      error_code='NETWORK_TRANSIENT',
      last_error='NETWORK_TRANSIENT: stale background processing recovered',
      lease_owner=null,
      lease_expires_at=null,
      updated_at=now()
  where status='processing'
    and claimed_at<now()-interval '5 minutes'
    and attempts<3;

  update english.question_revision_proposals
  set status='failed',
      next_attempt_at=null,
      error_code='RETRIES_EXHAUSTED',
      last_error='RETRIES_EXHAUSTED: background processing exhausted retries after stale worker recovery',
      lease_owner=null,
      lease_expires_at=null,
      updated_at=now()
  where status='processing'
    and claimed_at<now()-interval '5 minutes'
    and attempts>=3;

  outv:=english.question_revision_claim(
    p_token,
    greatest(1,least(1,coalesce(p_limit,1)))
  );

  -- A retry that is actively processing again no longer presents its prior transient
  -- failure code as the current state. New failures will set a fresh typed code.
  update english.question_revision_proposals p
  set error_code=null,updated_at=now()
  where p.proposal_id in (
    select nullif(x->>'proposalId','')::uuid
    from jsonb_array_elements(coalesce(outv->'items','[]'::jsonb)) x
    where nullif(x->>'proposalId','') is not null
  ) and p.status='processing';

  return coalesce(outv,jsonb_build_object('items','[]'::jsonb));
end
$function$;

revoke all on function english.question_revision_claim_dedicated(text,integer) from public,anon,authenticated;
grant execute on function english.question_revision_claim_dedicated(text,integer) to service_role;

create or replace function public.english_question_revision_claim_dedicated(p_token text,p_limit integer default 1)
returns jsonb
language sql
security definer
set search_path to 'pg_catalog','public','english'
as $$ select english.question_revision_claim_dedicated(p_token,p_limit) $$;

revoke all on function public.english_question_revision_claim_dedicated(text,integer) from public,anon,authenticated;
grant execute on function public.english_question_revision_claim_dedicated(text,integer) to service_role;
