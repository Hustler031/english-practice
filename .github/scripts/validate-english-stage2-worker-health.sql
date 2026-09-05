\set ON_ERROR_STOP on

-- Reuse the Stage-1 Concept/Worker Health harness, then apply the Stage-2 queue
-- semantics override and prove retry_wait is not double-counted as runnable queued work.
\ir validate-english-concept-dashboard.sql
\ir ../../supabase/managed-migrations/20260905111000_english_worker_health_queue_semantics.sql

insert into english.semantic_queue(entity_type,entity_id,user_id,status,next_attempt_at,created_at,updated_at)
values('question','RETRY_Q','00000000-0000-0000-0000-000000000001','queued',now()+interval '10 minutes',now()-interval '5 minutes',now());
insert into english.question_revision_proposals(proposal_id,user_id,status,next_attempt_at,created_at,updated_at)
values(gen_random_uuid(),'00000000-0000-0000-0000-000000000001','queued',null,now(),now());

do $$ declare h jsonb; begin
  h:=public.english_get_ai_worker_health();
  if (h->>'queued')::int<>1 then
    raise exception 'Runnable queued count must exclude retry_wait rows: %',h;
  end if;
  if (h->>'retrying')::int<>1 then
    raise exception 'Retrying count mismatch: %',h;
  end if;
  if (h->>'processing')::int<>0 then
    raise exception 'Processing count mismatch: %',h;
  end if;
end $$;

select 'English Stage-2 Worker Health queue/retry semantics regression passed' result;
