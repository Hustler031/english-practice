-- Preserve legacy frozen-batch display contracts while v3 uses Repair 70 / total 190.
create or replace function english.daily_focus_summary(p_user_id uuid)
returns jsonb
language plpgsql
security definer
set search_path='pg_catalog','english','auth'
as $function$
declare
  v_today date:=(now() at time zone 'Asia/Kolkata')::date;
  v_batch english.daily_focus_batches%rowtype;
  v_done integer:=0; v_total integer:=0;
  v_repair_done integer:=0; v_repair_total integer:=0;
  v_coverage_done integer:=0; v_coverage_total integer:=0;
  v_fast_done integer:=0; v_fast_total integer:=0;
  v_is_v3 boolean:=false;
begin
  select * into v_batch
  from english.daily_focus_batches
  where user_id=p_user_id
  order by batch_date desc limit 1;

  if not found then return jsonb_build_object('ok',false,'reason','no-batch'); end if;

  select count(*),count(*) filter(where status='Completed'),
         count(*) filter(where lane='repair'),count(*) filter(where lane='repair' and status='Completed'),
         count(*) filter(where lane='coverage'),count(*) filter(where lane='coverage' and status='Completed'),
         count(*) filter(where lane='fast_track'),count(*) filter(where lane='fast_track' and status='Completed')
    into v_total,v_done,v_repair_total,v_repair_done,v_coverage_total,v_coverage_done,v_fast_total,v_fast_done
  from english.daily_focus_items
  where user_id=p_user_id and batch_date=v_batch.batch_date;

  select exists(
    select 1 from english.daily_focus_items f
    where f.user_id=p_user_id and f.batch_date=v_batch.batch_date and f.lane='repair'
      and f.selection_snapshot->>'source'='learning_need_engine'
      and f.selection_snapshot->>'buildVersion'='v3'
  ) into v_is_v3;

  return jsonb_build_object(
    'ok',true,'today',v_today,'batchDate',v_batch.batch_date,
    'carryover',(v_batch.batch_date<v_today and v_batch.status='active'),'status',v_batch.status,
    'total',v_total,'completed',v_done,'remaining',greatest(0,v_total-v_done),
    'nominalTarget',case when v_is_v3 then 190 else 170 end,
    'buildVersion',case when v_is_v3 then 'v3' else 'legacy' end,
    'lanes',jsonb_build_object(
      'repair',jsonb_build_object('target',v_repair_total,'nominalTarget',case when v_is_v3 then 70 else 50 end,'completed',v_repair_done,
        'remaining',greatest(0,v_repair_total-v_repair_done),'done',(v_repair_total>0 and v_repair_done=v_repair_total)),
      'coverage',jsonb_build_object('target',v_coverage_total,'nominalTarget',70,'completed',v_coverage_done,
        'remaining',greatest(0,v_coverage_total-v_coverage_done),'done',(v_coverage_total>0 and v_coverage_done=v_coverage_total)),
      'fastTrack',jsonb_build_object('target',v_fast_total,'nominalTarget',50,'completed',v_fast_done,
        'remaining',greatest(0,v_fast_total-v_fast_done),'done',(v_fast_total>0 and v_fast_done=v_fast_total))
    )
  );
end;
$function$;
