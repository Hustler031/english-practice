begin;

-- One-time deployment recovery for abandoned provider-failure claims. A genuinely
-- active content run is far shorter than this threshold; newer claims are left alone.
update english.chatgpt_content_task_runs
set status='superseded',
    result=jsonb_build_object(
      'released',true,
      'reason','stale unfinished content task recovered during failure-release rollout',
      'releasedAt',now()
    ),
    updated_at=now()
where lane in ('hindu','phrasal')
  and status in ('claimed','checked')
  and updated_at < now()-interval '20 minutes';

create or replace function public.english_release_content_task_claim(
  p_run_id uuid,
  p_lane text,
  p_reason text default null
)
returns jsonb
language plpgsql
security definer
set search_path='pg_catalog','public','english','auth'
as $function$
declare
  v_lane text:=lower(btrim(coalesce(p_lane,'')));
  v_changed integer:=0;
begin
  if auth.role() <> 'service_role' then
    raise exception 'Service role required';
  end if;
  if p_run_id is null or v_lane not in ('hindu','phrasal') then
    raise exception 'Valid content task run and lane are required';
  end if;

  update english.chatgpt_content_task_runs
  set status='superseded',
      result=jsonb_build_object(
        'released',true,
        'reason',left(coalesce(p_reason,'generation failed'),800),
        'releasedAt',now()
      ),
      updated_at=now()
  where run_id=p_run_id
    and lane=v_lane
    and status in ('claimed','checked');
  get diagnostics v_changed=row_count;

  return jsonb_build_object('ok',true,'released',v_changed=1,'runId',p_run_id,'lane',v_lane);
end
$function$;

revoke all on function public.english_release_content_task_claim(uuid,text,text) from public,anon,authenticated;
grant execute on function public.english_release_content_task_claim(uuid,text,text) to service_role;

commit;
