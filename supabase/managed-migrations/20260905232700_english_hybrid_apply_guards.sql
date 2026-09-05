-- Critic enforcement is feature-gated so the existing production paths remain unchanged until activation.

create or replace function public.english_hindu_task_apply(p_run_id uuid,p_items jsonb)
returns jsonb
language plpgsql security definer
set search_path='pg_catalog','public','english'
as $$
declare
  r english.chatgpt_content_task_runs%rowtype;
  v_apply jsonb;
  v_verify jsonb;
begin
  select * into r from english.chatgpt_content_task_runs where run_id=p_run_id and lane='hindu' for update;
  if not found then raise exception 'Unknown Hindu run'; end if;
  if r.status='applied' then return coalesce(r.result,jsonb_build_object('ok',true,'alreadyApplied',true)); end if;
  if r.status not in ('claimed','checked') then raise exception 'Hindu run is not applicable: %',r.status; end if;

  if english.ai_feature_enabled('groq_critic_v1') then
    perform english.assert_generated_items_quality(p_items,false);
  end if;

  v_apply:=english.maintenance_apply_hindu_daily(p_items);
  v_verify:=english.maintenance_verify_hindu_daily();
  if not coalesce((v_verify->>'ok')::boolean,false) then raise exception 'Hindu verification failed after apply'; end if;
  update english.chatgpt_content_task_runs
    set status='applied',result=jsonb_build_object('apply',v_apply,'verify',v_verify),applied_at=now(),updated_at=now()
    where run_id=p_run_id;
  return jsonb_build_object('ok',true,'apply',v_apply,'verify',v_verify);
end $$;

create or replace function public.english_saved_enrichment_worker_apply(p_token text,p_lease_id uuid,p_items jsonb)
returns jsonb
language plpgsql security definer
set search_path='pg_catalog','public','english'
as $$
begin
  if not english.context_worker_authorized(p_token) then
    raise exception 'saved enrichment worker unauthorized';
  end if;
  if not exists(
    select 1 from english.saved_enrichment_worker_state
    where singleton=true and lease_id=p_lease_id and lease_expires_at>now()
  ) then raise exception 'saved enrichment worker lease is missing or expired'; end if;

  if english.ai_feature_enabled('groq_critic_v1') then
    perform english.assert_generated_items_quality(p_items,true);
  end if;
  return english.maintenance_apply_saved_enrichment(p_items);
end $$;
