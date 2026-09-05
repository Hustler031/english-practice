-- Ensure the private ChatGPT Phrasal delivery is immediately represented in
-- Concept Intelligence, independent of asynchronous semantic refinement timing.

create or replace function public.english_phrasal_task_apply(p_run_id uuid,p_items jsonb)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','public','english'
as $function$
declare
  r english.chatgpt_content_task_runs%rowtype;
  v_apply jsonb;
  v_verify jsonb;
  v_source_id text:='PHRASAL_DAILY_'||to_char((now() at time zone 'Asia/Kolkata')::date,'YYYYMMDD');
  v_total integer;
  v_mapped integer;
begin
  select * into r from english.chatgpt_content_task_runs where run_id=p_run_id and lane='phrasal' for update;
  if not found then raise exception 'Unknown Phrasal run'; end if;
  if r.status='applied' then return coalesce(r.result,jsonb_build_object('ok',true,'alreadyApplied',true)); end if;
  if r.status<>'claimed' then raise exception 'Phrasal run is not claimable: %',r.status; end if;

  v_apply:=english.maintenance_apply_phrasal_daily(p_items);

  -- Central-selected Phrasal concepts already exist. Reconcile the deterministic
  -- question->concept mapping immediately; semantic triggers continue refinement.
  insert into english.question_concept_mappings(question_id,concept_id,mapping_confidence,mapping_method,review_status,relation_type)
  select q.question_id,q.concept_id,1,'deterministic_metadata','mapped','primary'
  from english.questions q
  join english.concepts c on c.concept_id=q.concept_id and c.active
  where q.active and q.source_id=v_source_id and q.concept_id is not null
  on conflict(question_id) do update set
    concept_id=excluded.concept_id,
    mapping_confidence=1,
    mapping_method='deterministic_metadata',
    review_status='mapped',
    relation_type='primary',
    updated_at=now();

  v_verify:=english.maintenance_verify_phrasal_daily();
  select count(*) into v_total from english.questions q where q.active and q.source_id=v_source_id;
  select count(*) into v_mapped
  from english.questions q
  join english.question_concept_mappings m on m.question_id=q.question_id and m.concept_id=q.concept_id
  join english.concepts c on c.concept_id=q.concept_id and c.active
  where q.active and q.source_id=v_source_id;

  if not coalesce((v_verify->>'ok')::boolean,false) or v_total<>20 or v_mapped<>20 then
    raise exception 'Phrasal verification/Central Intelligence mapping failed: questions %, mapped %',v_total,v_mapped;
  end if;

  update english.chatgpt_content_task_runs
  set status='applied',
      result=jsonb_build_object('apply',v_apply,'verify',v_verify,'centralMapped',v_mapped),
      applied_at=now(),updated_at=now()
  where run_id=p_run_id;

  return jsonb_build_object('ok',true,'apply',v_apply,'verify',v_verify,'centralMapped',v_mapped);
end
$function$;

revoke all on function public.english_phrasal_task_apply(uuid,jsonb) from public,anon,authenticated;
grant execute on function public.english_phrasal_task_apply(uuid,jsonb) to service_role;
