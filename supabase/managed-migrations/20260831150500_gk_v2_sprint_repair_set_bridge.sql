-- Bridge Sprint diagnostics into the existing demand-set selector so Smart Repair
-- reuses the one canonical /gk/quiz engine and its normal adaptive mutation path.

create or replace function public.gk_create_sprint_repair_set(
  p_exam_session_id text,
  p_concept_key text default null,
  p_count integer default 12
)
returns jsonb
language plpgsql
security definer
set search_path=pg_catalog,public,gk,auth
as $$
declare
  uid uuid:=auth.uid();
  qs jsonb;
  ids jsonb;
  did text;
  title_name text;
  concept_title text;
begin
  if uid is null then raise exception 'Authentication required'; end if;
  if not exists(
    select 1 from gk.exam_sessions
    where session_id=p_exam_session_id and user_id=uid and completed
  ) then raise exception 'Completed Sprint not found'; end if;

  qs:=public.gk_get_sprint_repair_batch(
    p_exam_session_id,nullif(btrim(coalesce(p_concept_key,'')),''),
    greatest(1,least(40,coalesce(p_count,12)))
  );
  if jsonb_array_length(coalesce(qs,'[]'::jsonb))=0 then
    return jsonb_build_object('ok',false,'message','No canonical repair questions are available for this recommendation.');
  end if;

  ids:=(select jsonb_agg(value->>'id' order by ord)
    from jsonb_array_elements(qs) with ordinality x(value,ord));
  select coalesce(nullif(topic,''),nullif(subject,''),'Concept') into concept_title
  from gk.exam_diagnostics
  where session_id=p_exam_session_id and user_id=uid
    and concept_key=nullif(btrim(coalesce(p_concept_key,'')),'')
  limit 1;
  title_name:=case when nullif(btrim(coalesce(p_concept_key,'')),'') is null
    then 'Sprint Smart Repair' else coalesce(concept_title,'Concept')||' · Sprint Repair' end;
  did:='SPR-'||gen_random_uuid()::text;

  insert into gk.demand_sets(demand_id,user_id,title,kind,criteria,question_ids,created_at,active)
  values(
    did,uid,title_name,'sprint_repair',
    jsonb_build_object('examSessionId',p_exam_session_id,'conceptKey',nullif(btrim(coalesce(p_concept_key,'')),''),'count',jsonb_array_length(ids)),
    ids,now(),true
  );

  update gk.exam_diagnostics
  set repair_started_at=coalesce(repair_started_at,now())
  where session_id=p_exam_session_id and user_id=uid
    and (nullif(btrim(coalesce(p_concept_key,'')),'') is null or concept_key=p_concept_key);

  return jsonb_build_object('ok',true,'setId',did,'title',title_name,'count',jsonb_array_length(ids));
end;
$$;

revoke all on function public.gk_create_sprint_repair_set(text,text,integer) from public,anon;
grant execute on function public.gk_create_sprint_repair_set(text,text,integer) to authenticated;
