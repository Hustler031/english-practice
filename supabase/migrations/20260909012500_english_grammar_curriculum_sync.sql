-- ENGLISH V2 — Grammar Intelligence Stage 1 curriculum sync contract
-- Google Sheet is the human-curated curriculum workspace; production receives a validated
-- snapshot only during an explicit deployment/sync step. Daily runtime never calls Google.

create table if not exists english.grammar_curriculum_state(
  singleton boolean primary key default true check(singleton),
  curriculum_version text not null,
  rule_count integer not null check(rule_count between 20 and 500),
  key_checksum text not null,
  content_checksum text not null,
  source_spreadsheet_id text not null,
  source_sheet text not null default 'Grammar_Rules',
  synced_at timestamptz not null default now(),
  metadata jsonb not null default '{}'::jsonb
);
alter table english.grammar_curriculum_state enable row level security;
revoke all on english.grammar_curriculum_state from anon,authenticated;

create or replace function english.grammar_sync_curriculum(
  p_version text,
  p_expected_key_checksum text,
  p_rules jsonb,
  p_spreadsheet_id text default '1IgUGQZu6sp1STBCX6gyI5pHayLGVpmYYrkKGYdwkjak'
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','english','extensions'
set statement_timeout to '120s'
as $function$
declare
  v_count integer; v_distinct integer; v_key_checksum text; v_content_checksum text; v_bad integer;
begin
  if btrim(coalesce(p_version,''))='' then raise exception 'Grammar curriculum version is required'; end if;
  if jsonb_typeof(coalesce(p_rules,'null'::jsonb))<>'array' then raise exception 'Grammar curriculum must be a JSON array'; end if;
  v_count:=jsonb_array_length(p_rules);
  if v_count<200 or v_count>500 then raise exception 'Grammar curriculum must contain 200-500 verified atomic rules; got %',v_count; end if;

  create temp table grammar_sync_stage(
    rule_key text primary key,
    chapter text not null,
    rule_family text not null,
    rule_title text not null,
    canonical_rule text not null,
    common_trap text,
    contrast_with text,
    priority integer not null,
    difficulty text not null,
    supported_families text[] not null,
    source_name text not null,
    source_url text not null,
    verification_note text,
    sheet_status text
  ) on commit drop;

  insert into grammar_sync_stage(rule_key,chapter,rule_family,rule_title,canonical_rule,common_trap,contrast_with,priority,difficulty,supported_families,source_name,source_url,verification_note,sheet_status)
  select
    btrim(x->>'ruleKey'),btrim(x->>'chapter'),btrim(x->>'ruleFamily'),btrim(x->>'ruleTitle'),btrim(x->>'canonicalRule'),
    btrim(coalesce(x->>'commonTrap','')),btrim(coalesce(x->>'contrastWith','')),
    (x->>'priority')::integer,btrim(x->>'difficulty'),
    array(select lower(btrim(value)) from jsonb_array_elements_text(coalesce(x->'supportedFamilies','[]'::jsonb))),
    btrim(x->>'sourceName'),btrim(x->>'sourceUrl'),btrim(coalesce(x->>'verificationNote','')),upper(btrim(coalesce(x->>'sheetStatus','DORMANT')))
  from jsonb_array_elements(p_rules) x;

  get diagnostics v_distinct=row_count;
  if v_distinct<>v_count then raise exception 'Grammar curriculum Rule_Key values must be unique'; end if;

  select count(*) into v_bad from grammar_sync_stage
  where rule_key='' or chapter='' or rule_family='' or rule_title='' or canonical_rule='' or source_name='' or source_url=''
     or priority not between 0 and 100 or difficulty not in ('Basic','Moderate','Advanced')
     or cardinality(supported_families)=0
     or exists(select 1 from unnest(supported_families) f where f not in ('direct_fill','context_fill','sentence_improvement','error_detection','transformation','contrast','transfer'))
     or source_url!~* '^https://'
     or sheet_status not in ('DORMANT','INTRODUCED','ACTIVE');
  if v_bad>0 then raise exception 'Grammar curriculum contains % invalid/unverified-contract rows',v_bad; end if;

  select encode(extensions.digest(convert_to(string_agg(rule_key,'|' order by rule_key),'UTF8'),'sha256'),'hex')
  into v_key_checksum from grammar_sync_stage;
  if btrim(coalesce(p_expected_key_checksum,''))<>'' and lower(btrim(p_expected_key_checksum))<>v_key_checksum then
    raise exception 'Grammar curriculum key checksum mismatch: expected %, got %',p_expected_key_checksum,v_key_checksum;
  end if;

  select encode(extensions.digest(convert_to(string_agg(
    concat_ws(chr(31),rule_key,chapter,rule_family,rule_title,canonical_rule,coalesce(common_trap,''),coalesce(contrast_with,''),priority::text,difficulty,
      array_to_string(supported_families,','),source_name,source_url,coalesce(verification_note,''))
    ,chr(30) order by rule_key),'UTF8'),'sha256'),'hex')
  into v_content_checksum from grammar_sync_stage;

  insert into english.grammar_rules(rule_key,chapter,rule_family,rule_title,canonical_rule,common_trap,contrast_with,priority,difficulty,supported_families,source_name,source_url,verification_note,active,metadata,created_at,updated_at)
  select rule_key,chapter,rule_family,rule_title,canonical_rule,nullif(common_trap,''),nullif(contrast_with,''),priority,difficulty,supported_families,source_name,source_url,nullif(verification_note,''),true,
    jsonb_build_object('curriculumVersion',p_version,'sheetStatus',sheet_status,'sourceSpreadsheetId',p_spreadsheet_id),now(),now()
  from grammar_sync_stage
  on conflict(rule_key) do update set
    chapter=excluded.chapter,rule_family=excluded.rule_family,rule_title=excluded.rule_title,canonical_rule=excluded.canonical_rule,
    common_trap=excluded.common_trap,contrast_with=excluded.contrast_with,priority=excluded.priority,difficulty=excluded.difficulty,
    supported_families=excluded.supported_families,source_name=excluded.source_name,source_url=excluded.source_url,verification_note=excluded.verification_note,
    active=true,metadata=english.grammar_rules.metadata||excluded.metadata,updated_at=now();

  -- Preserve retired rule identity/evidence but keep it out of future selection.
  update english.grammar_rules as gr
  set active=false,updated_at=now(),metadata=gr.metadata||jsonb_build_object('retiredByCurriculum',p_version)
  where gr.active and not exists(select 1 from grammar_sync_stage s where s.rule_key=gr.rule_key);

  insert into english.grammar_curriculum_state(singleton,curriculum_version,rule_count,key_checksum,content_checksum,source_spreadsheet_id,source_sheet,synced_at,metadata)
  values(true,p_version,v_count,v_key_checksum,v_content_checksum,p_spreadsheet_id,'Grammar_Rules',now(),
    jsonb_build_object('verifiedSourcePolicy','SSC official scope + Cambridge/British Council/Merriam-Webster or equivalent authoritative English sources'))
  on conflict(singleton) do update set curriculum_version=excluded.curriculum_version,rule_count=excluded.rule_count,key_checksum=excluded.key_checksum,
    content_checksum=excluded.content_checksum,source_spreadsheet_id=excluded.source_spreadsheet_id,source_sheet=excluded.source_sheet,synced_at=now(),metadata=excluded.metadata;

  return jsonb_build_object('ok',true,'version',p_version,'ruleCount',v_count,'keyChecksum',v_key_checksum,'contentChecksum',v_content_checksum,'spreadsheetId',p_spreadsheet_id);
end
$function$;

create or replace function english.grammar_sync_sprint_aliases(p_alias_version text,p_aliases jsonb)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','english'
as $function$
declare v_count integer; v_distinct integer; v_bad integer;
begin
  if btrim(coalesce(p_alias_version,''))='' then raise exception 'Grammar alias version required'; end if;
  if jsonb_typeof(coalesce(p_aliases,'null'::jsonb))<>'array' then raise exception 'Grammar aliases must be a JSON array'; end if;
  v_count:=jsonb_array_length(p_aliases);
  create temp table grammar_alias_stage(alias_key text primary key,rule_key text not null,confidence numeric not null,notes text) on commit drop;
  insert into grammar_alias_stage(alias_key,rule_key,confidence,notes)
  select btrim(x->>'aliasKey'),btrim(x->>'ruleKey'),coalesce(nullif(x->>'confidence','')::numeric,1),btrim(coalesce(x->>'notes',''))
  from jsonb_array_elements(p_aliases) x;
  get diagnostics v_distinct=row_count;
  if v_distinct<>v_count then raise exception 'Grammar Sprint alias keys must be unique'; end if;
  select count(*) into v_bad from grammar_alias_stage a
  where alias_key='' or rule_key='' or confidence not between 0 and 1
     or not exists(select 1 from english.grammar_rules gr where gr.rule_key=a.rule_key and gr.active);
  if v_bad>0 then raise exception 'Grammar alias payload contains % invalid or unknown target rules',v_bad; end if;

  insert into english.grammar_rule_aliases(alias_key,rule_key,source,confidence,active,created_at)
  select alias_key,rule_key,'sprint_concept_key',confidence,true,now() from grammar_alias_stage
  on conflict(alias_key) do update set rule_key=excluded.rule_key,source=excluded.source,confidence=excluded.confidence,active=true;
  update english.grammar_rule_aliases as ga set active=false
  where ga.source='sprint_concept_key' and not exists(select 1 from grammar_alias_stage s where s.alias_key=ga.alias_key);

  return jsonb_build_object('ok',true,'version',p_alias_version,'aliasCount',v_count);
end
$function$;

create or replace function english.grammar_curriculum_status()
returns jsonb
language sql
stable
security definer
set search_path to 'pg_catalog','english'
as $function$
select coalesce((select jsonb_build_object(
  'ready',rule_count>=200 and rule_count=(select count(*) from english.grammar_rules where active),
  'version',curriculum_version,'ruleCount',rule_count,'activeRules',(select count(*) from english.grammar_rules where active),
  'keyChecksum',key_checksum,'contentChecksum',content_checksum,'syncedAt',synced_at,'spreadsheetId',source_spreadsheet_id)
  from english.grammar_curriculum_state where singleton),jsonb_build_object('ready',false,'ruleCount',0,'activeRules',0))
$function$;

revoke all on function english.grammar_sync_curriculum(text,text,jsonb,text) from public,anon,authenticated;
revoke all on function english.grammar_sync_sprint_aliases(text,jsonb) from public,anon,authenticated;
revoke all on function english.grammar_curriculum_status() from public,anon,authenticated;
grant execute on function english.grammar_sync_curriculum(text,text,jsonb,text) to service_role;
grant execute on function english.grammar_sync_sprint_aliases(text,jsonb) to service_role;
grant execute on function english.grammar_curriculum_status() to service_role;
