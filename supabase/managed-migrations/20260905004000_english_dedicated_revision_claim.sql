-- Dedicated revision worker owns revision-only scheduling, so its authorized claim
-- must not depend on the mixed worker's active_lane fairness gate.

create or replace function public.english_question_revision_claim_dedicated(p_token text,p_limit integer default 1)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','public','english'
as $function$
begin
  if not english.context_worker_authorized(p_token) then
    raise exception 'context worker unauthorized';
  end if;
  return english.question_revision_claim(p_token,greatest(1,least(1,coalesce(p_limit,1))));
end
$function$;

revoke all on function public.english_question_revision_claim_dedicated(text,integer) from public,anon,authenticated;
grant execute on function public.english_question_revision_claim_dedicated(text,integer) to service_role;
