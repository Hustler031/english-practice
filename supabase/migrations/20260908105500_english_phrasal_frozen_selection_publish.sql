-- Phrasal atomic publication must validate against the selection frozen when the
-- daily generation batch was created. Re-running the adaptive selector hours later
-- can legitimately return a different concept after learning-state changes and must
-- not invalidate an already-generated 20/20 batch.

do $do$
declare
  v_oid oid;
  v_def text;
  v_old text := 'v_expected:=public.english_get_phrasal_hybrid_maintenance_batch(''smart'',20);';
  v_new text := $patch$
 select gb.selection into v_expected
 from english.phrasal_generation_batches gb
 where gb.batch_date=v_day and gb.status in ('building','ready')
 order by gb.created_at desc
 limit 1;
 if v_expected is null then
   v_expected:=public.english_get_phrasal_hybrid_maintenance_batch('smart',20);
 end if;$patch$;
begin
  select p.oid into v_oid
  from pg_proc p
  join pg_namespace n on n.oid=p.pronamespace
  where n.nspname='english'
    and p.proname='maintenance_apply_phrasal_hybrid_core'
    and pg_get_function_identity_arguments(p.oid)='p_items jsonb';

  if v_oid is null then
    raise exception 'maintenance_apply_phrasal_hybrid_core(jsonb) not found';
  end if;

  v_def:=pg_get_functiondef(v_oid);
  if strpos(v_def,v_old)=0 then
    raise exception 'Expected dynamic-selector statement not found; refusing unsafe Phrasal patch';
  end if;

  v_def:=replace(v_def,v_old,v_new);
  execute v_def;
end
$do$;

-- Contract assertion: the patched function must now read the frozen generation batch.
do $do$
declare v_def text;
begin
  select pg_get_functiondef(p.oid) into v_def
  from pg_proc p join pg_namespace n on n.oid=p.pronamespace
  where n.nspname='english' and p.proname='maintenance_apply_phrasal_hybrid_core'
  limit 1;

  if position('phrasal_generation_batches' in coalesce(v_def,''))=0
     or position('gb.selection' in coalesce(v_def,''))=0 then
    raise exception 'Frozen Phrasal selection publish guard was not installed';
  end if;
end
$do$;
