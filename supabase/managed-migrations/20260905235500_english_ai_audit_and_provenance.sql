-- Service-only audit/provenance helpers for hybrid AI publication.

create or replace function public.english_record_content_generation_audits(p_items jsonb)
returns jsonb
language plpgsql security definer
set search_path='pg_catalog','public','english'
as $$
declare x jsonb; n integer:=0;
begin
  if jsonb_typeof(coalesce(p_items,'null'::jsonb))<>'array' then
    raise exception 'Audit payload must be an array';
  end if;
  for x in select value from jsonb_array_elements(p_items) loop
    if lower(coalesce(x->>'lane','')) not in ('phrasal','hindu','saved','tone','sprint') then
      raise exception 'Invalid content-generation audit lane';
    end if;
    insert into english.content_generation_audits(
      lane,entity_key,generator_provider,generator_model,critic_provider,critic_model,
      quality_score,critic_decision,repair_count,question_family,sense_key,variant_key,
      variant_fingerprint,publication_result,metadata
    ) values(
      lower(x->>'lane'),nullif(x->>'entityKey',''),coalesce(nullif(x->>'generatorProvider',''),'unknown'),
      nullif(x->>'generatorModel',''),nullif(x->>'criticProvider',''),nullif(x->>'criticModel',''),
      nullif(x->>'qualityScore','')::numeric,nullif(x->>'criticDecision',''),
      greatest(0,least(2,coalesce((x->>'repairCount')::int,0))),nullif(x->>'questionFamily',''),
      nullif(x->>'senseKey',''),nullif(x->>'variantKey',''),nullif(x->>'variantFingerprint',''),
      nullif(x->>'publicationResult',''),coalesce(x->'metadata','{}'::jsonb)
    );
    n:=n+1;
  end loop;
  return jsonb_build_object('ok',true,'inserted',n);
end $$;
revoke all on function public.english_record_content_generation_audits(jsonb) from public,anon,authenticated;
grant execute on function public.english_record_content_generation_audits(jsonb) to service_role;

create or replace function public.english_hindu_task_apply(p_run_id uuid,p_items jsonb)
returns jsonb
language plpgsql security definer
set search_path='pg_catalog','public','english'
as $$
declare
  r english.chatgpt_content_task_runs%rowtype;
  v_apply jsonb;
  v_verify jsonb;
  v_source_id text:='HINDU_'||to_char((now() at time zone 'Asia/Kolkata')::date,'YYYYMMDD');
begin
  select * into r from english.chatgpt_content_task_runs where run_id=p_run_id and lane='hindu' for update;
  if not found then raise exception 'Unknown Hindu run'; end if;
  if r.status='applied' then return coalesce(r.result,jsonb_build_object('ok',true,'alreadyApplied',true)); end if;
  if r.status not in ('claimed','checked') then raise exception 'Hindu run is not applicable: %',r.status; end if;

  if english.ai_feature_enabled('groq_critic_v1') then
    perform english.assert_generated_items_quality(p_items,false);
  end if;

  v_apply:=english.maintenance_apply_hindu_daily(p_items);

  if english.ai_feature_enabled('gemini_content_v1') then
    update english.sources set
      source_ref='Gemini grounded current-news generation + Groq independent critic',
      notes='Current-news vocabulary generated from grounded source evidence by Gemini and independently quality-gated by Groq. The Hindu is named only when the grounded source is actually The Hindu; otherwise the stored source metadata identifies the real publisher.'
    where source_id=v_source_id;
  end if;

  v_verify:=english.maintenance_verify_hindu_daily();
  if not coalesce((v_verify->>'ok')::boolean,false) then raise exception 'Hindu verification failed after apply'; end if;
  update english.chatgpt_content_task_runs
    set status='applied',result=jsonb_build_object('apply',v_apply,'verify',v_verify),applied_at=now(),updated_at=now()
    where run_id=p_run_id;
  return jsonb_build_object('ok',true,'apply',v_apply,'verify',v_verify);
end $$;
