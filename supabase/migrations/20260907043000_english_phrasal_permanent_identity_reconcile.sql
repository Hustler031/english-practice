-- Separate Phrasal daily membership from permanent question identity.
-- Reconcile only exact duplicate daily snapshots; learner attempts are preserved.

create table if not exists english.phrasal_question_aliases (
  alias_question_id text primary key references english.questions(question_id) on delete cascade,
  canonical_question_id text not null references english.questions(question_id) on delete restrict,
  reason text not null default 'exact_daily_snapshot_duplicate',
  created_at timestamptz not null default now(),
  check (alias_question_id <> canonical_question_id)
);

create index if not exists english_phrasal_question_aliases_canonical_idx
  on english.phrasal_question_aliases(canonical_question_id);

create table if not exists english.phrasal_daily_items (
  batch_date date not null,
  slot_no integer not null check (slot_no between 1 and 100),
  source_id text not null,
  question_id text not null references english.questions(question_id) on delete restrict,
  original_question_id text references english.questions(question_id) on delete set null,
  concept_id text not null,
  requested_family text not null,
  question_family text not null,
  generator_provider text,
  is_new_variant boolean not null default false,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  primary key(batch_date,slot_no),
  unique(batch_date,question_id)
);

create index if not exists english_phrasal_daily_items_source_idx
  on english.phrasal_daily_items(source_id);
create index if not exists english_phrasal_daily_items_question_idx
  on english.phrasal_daily_items(question_id);
create index if not exists english_phrasal_daily_items_concept_idx
  on english.phrasal_daily_items(concept_id);

revoke all on table english.phrasal_question_aliases from public,anon,authenticated;
revoke all on table english.phrasal_daily_items from public,anon,authenticated;
grant select,insert,update,delete on table english.phrasal_question_aliases to service_role;
grant select,insert,update,delete on table english.phrasal_daily_items to service_role;

-- Build a durable alias map for exact duplicate Phrasal Daily snapshots only.
with sig as (
  select q.question_id,q.concept_id,q.source_id,q.created_at,
         md5(concat_ws(E'\x1f',
           coalesce(q.concept_id,''),coalesce(q.question,''),
           coalesce(q.option_a,''),coalesce(q.option_b,''),
           coalesce(q.option_c,''),coalesce(q.option_d,''),
           coalesce(q.correct,''),coalesce(q.explanation,''))) payload_sig
  from english.questions q
  where q.active
    and (english.canonical_category(q.topic)='PHRASAL'
         or lower(btrim(coalesce(q.topic,'')))='phrasal verb')
), ranked as (
  select s.*,
         first_value(question_id) over (
           partition by concept_id,payload_sig
           order by case when coalesce(source_id,'') ~ '^PHRASAL_DAILY_[0-9]{8}$' then 1 else 0 end,
                    created_at,question_id
         ) canonical_question_id,
         row_number() over (
           partition by concept_id,payload_sig
           order by case when coalesce(source_id,'') ~ '^PHRASAL_DAILY_[0-9]{8}$' then 1 else 0 end,
                    created_at,question_id
         ) rn
  from sig s
)
insert into english.phrasal_question_aliases(alias_question_id,canonical_question_id)
select question_id,canonical_question_id
from ranked
where rn>1
  and coalesce(source_id,'') ~ '^PHRASAL_DAILY_[0-9]{8}$'
on conflict(alias_question_id) do update
set canonical_question_id=excluded.canonical_question_id;

-- Backfill historical day membership before any snapshot row is retired.
with daily as (
  select q.*,
         to_date(substring(q.source_id from 'PHRASAL_DAILY_([0-9]{8})'),'YYYYMMDD') batch_date,
         row_number() over(
           partition by q.source_id
           order by
             case when q.question_id ~ '^PV[0-9]+$' then substring(q.question_id from '^PV([0-9]+)$')::int else 2147483647 end,
             q.question_id
         )::int slot_no
  from english.questions q
  where q.source_id ~ '^PHRASAL_DAILY_[0-9]{8}$'
    and (english.canonical_category(q.topic)='PHRASAL'
         or lower(btrim(coalesce(q.topic,'')))='phrasal verb')
)
insert into english.phrasal_daily_items(
  batch_date,slot_no,source_id,question_id,original_question_id,concept_id,
  requested_family,question_family,generator_provider,is_new_variant,metadata
)
select d.batch_date,d.slot_no,d.source_id,
       coalesce(a.canonical_question_id,d.question_id),
       d.question_id,
       coalesce(nullif(btrim(d.concept_id),''),'PVQ_'||d.question_id),
       coalesce(v.question_family,english.phrasal_question_family(d)),
       coalesce(v.question_family,english.phrasal_question_family(d)),
       coalesce(v.generator_provider,
                case when a.alias_question_id is not null then 'legacy_bank' else 'historical' end),
       a.alias_question_id is null,
       jsonb_build_object('backfilled',true,'originalSourceId',d.source_id)
from daily d
left join english.phrasal_question_aliases a on a.alias_question_id=d.question_id
left join english.phrasal_question_variants v on v.question_id=d.question_id
on conflict(batch_date,slot_no) do update set
  source_id=excluded.source_id,
  question_id=excluded.question_id,
  original_question_id=excluded.original_question_id,
  concept_id=excluded.concept_id,
  requested_family=excluded.requested_family,
  question_family=excluded.question_family,
  generator_provider=excluded.generator_provider,
  is_new_variant=excluded.is_new_variant,
  metadata=english.phrasal_daily_items.metadata||excluded.metadata;

-- Preserve learner evidence by moving attempts to the permanent identity.
update english.attempts a
set question_id=x.canonical_question_id
from english.phrasal_question_aliases x
where a.question_id=x.alias_question_id;

-- Preserve current Daily assignments; preflight established there are no collisions.
update english.daily_current d
set question_id=x.canonical_question_id
from english.phrasal_question_aliases x
where d.question_id=x.alias_question_id
  and not exists (
    select 1 from english.daily_current z
    where z.user_id=d.user_id and z.question_id=x.canonical_question_id
  );

-- Preserve explicit manual difficulty.
insert into english.difficult_state(user_id,question_id,difficult,updated_at)
select d.user_id,x.canonical_question_id,bool_or(d.difficult),max(d.updated_at)
from english.difficult_state d
join english.phrasal_question_aliases x on x.alias_question_id=d.question_id
group by d.user_id,x.canonical_question_id
on conflict(user_id,question_id) do update
set difficult=english.difficult_state.difficult or excluded.difficult,
    updated_at=greatest(english.difficult_state.updated_at,excluded.updated_at);

-- Preserve star history.
insert into english.star_events(user_id,question_id,event_at,starred_date,day_no,action,source_row)
select s.user_id,x.canonical_question_id,s.event_at,s.starred_date,s.day_no,s.action,s.source_row
from english.star_events s
join english.phrasal_question_aliases x on x.alias_question_id=s.question_id
on conflict(user_id,question_id,event_at,action) do nothing;

-- Preserve mastery events; source-row identity remains unchanged.
update english.mastery_events m
set question_id=x.canonical_question_id
from english.phrasal_question_aliases x
where m.question_id=x.alias_question_id;

-- Preserve route history.
update english.learning_route_events e
set question_id=x.canonical_question_id
from english.phrasal_question_aliases x
where e.question_id=x.alias_question_id;

-- Pick the strongest/latest route state across each exact identity group.
with candidates as (
  select r.*,coalesce(x.canonical_question_id,r.question_id) canonical_question_id
  from english.learning_route_state r
  left join english.phrasal_question_aliases x on x.alias_question_id=r.question_id
  where x.alias_question_id is not null
     or exists(select 1 from english.phrasal_question_aliases y where y.canonical_question_id=r.question_id)
), best as (
  select distinct on(user_id,canonical_question_id)
    user_id,canonical_question_id,route,fast_track_status,origins,baseline_wrong,
    entered_fast_track_at,next_fast_track_check,fast_track_mastered_at,
    pending_failure_decision,kept_failure_count,last_failure_at,targeted_at,
    targeted_recovered_at,starred_resolved_at,last_route_reason,metadata,updated_at
  from candidates
  order by user_id,canonical_question_id,
           case route when 'targeted' then 3 when 'fast_track' then 2 else 1 end desc,
           updated_at desc
)
insert into english.learning_route_state(
  user_id,question_id,route,fast_track_status,origins,baseline_wrong,
  entered_fast_track_at,next_fast_track_check,fast_track_mastered_at,
  pending_failure_decision,kept_failure_count,last_failure_at,targeted_at,
  targeted_recovered_at,starred_resolved_at,last_route_reason,metadata,updated_at
)
select user_id,canonical_question_id,route,fast_track_status,origins,baseline_wrong,
       entered_fast_track_at,next_fast_track_check,fast_track_mastered_at,
       pending_failure_decision,kept_failure_count,last_failure_at,targeted_at,
       targeted_recovered_at,starred_resolved_at,last_route_reason,
       coalesce(metadata,'{}'::jsonb)||jsonb_build_object('phrasalIdentityReconciled',true),
       updated_at
from best
on conflict(user_id,question_id) do update set
  route=excluded.route,
  fast_track_status=excluded.fast_track_status,
  origins=excluded.origins,
  baseline_wrong=greatest(english.learning_route_state.baseline_wrong,excluded.baseline_wrong),
  entered_fast_track_at=coalesce(english.learning_route_state.entered_fast_track_at,excluded.entered_fast_track_at),
  next_fast_track_check=coalesce(excluded.next_fast_track_check,english.learning_route_state.next_fast_track_check),
  fast_track_mastered_at=coalesce(excluded.fast_track_mastered_at,english.learning_route_state.fast_track_mastered_at),
  pending_failure_decision=english.learning_route_state.pending_failure_decision or excluded.pending_failure_decision,
  kept_failure_count=greatest(english.learning_route_state.kept_failure_count,excluded.kept_failure_count),
  last_failure_at=greatest(english.learning_route_state.last_failure_at,excluded.last_failure_at),
  targeted_at=coalesce(english.learning_route_state.targeted_at,excluded.targeted_at),
  targeted_recovered_at=greatest(english.learning_route_state.targeted_recovered_at,excluded.targeted_recovered_at),
  starred_resolved_at=greatest(english.learning_route_state.starred_resolved_at,excluded.starred_resolved_at),
  last_route_reason=coalesce(excluded.last_route_reason,english.learning_route_state.last_route_reason),
  metadata=english.learning_route_state.metadata||excluded.metadata,
  updated_at=greatest(english.learning_route_state.updated_at,excluded.updated_at);

-- Small direct references that have no identity-level uniqueness conflict.
update english.learner_confidence_signals s
set question_id=x.canonical_question_id
from english.phrasal_question_aliases x
where s.question_id=x.alias_question_id;

update english.learner_context_notes n
set question_id=x.canonical_question_id
from english.phrasal_question_aliases x
where n.question_id=x.alias_question_id;

update english.question_revision_proposals p
set question_id=x.canonical_question_id
from english.phrasal_question_aliases x
where p.question_id=x.alias_question_id
  and not exists (
    select 1 from english.question_revision_proposals z
    where z.user_id=p.user_id
      and z.question_id=x.canonical_question_id
      and z.proposal_version=p.proposal_version
  );

-- Ensure a canonical state row exists before merging manual-only fields.
do $do$
declare r record;
begin
  for r in
    select distinct a.user_id,x.canonical_question_id question_id
    from english.attempts a
    join english.phrasal_question_aliases x
      on x.canonical_question_id=a.question_id
  loop
    perform english.recompute_question_state(r.user_id,r.question_id);
  end loop;
end
$do$;

-- Merge manual state fields before the final attempt-derived recompute.
with agg as (
  select q.user_id,x.canonical_question_id,
         bool_or(coalesce(q.mastered,false)) mastered,
         max(q.mastered_on) mastered_on,
         max(q.repeat_suppressed_until) repeat_suppressed_until,
         sum(coalesce(q.recall_check_count,0))::int recall_check_count,
         bool_or(coalesce(q.last_marked,false)) last_marked
  from english.question_state q
  join english.phrasal_question_aliases x on x.alias_question_id=q.question_id
  group by q.user_id,x.canonical_question_id
)
update english.question_state c
set mastered=c.mastered or a.mastered,
    mastered_on=greatest(c.mastered_on,a.mastered_on),
    repeat_suppressed_until=greatest(c.repeat_suppressed_until,a.repeat_suppressed_until),
    recall_check_count=coalesce(c.recall_check_count,0)+a.recall_check_count,
    last_marked=c.last_marked or a.last_marked,
    updated_at=now()
from agg a
where c.user_id=a.user_id and c.question_id=a.canonical_question_id;

-- Recompute canonical question state from the now-consolidated attempts.
do $do$
declare r record;
begin
  for r in
    select distinct a.user_id,x.canonical_question_id question_id
    from english.attempts a
    join english.phrasal_question_aliases x
      on x.canonical_question_id=a.question_id
  loop
    perform english.recompute_question_state(r.user_id,r.question_id);
  end loop;
end
$do$;

-- Remove duplicate-only state rows after canonical state exists.
delete from english.question_state q
using english.phrasal_question_aliases x
where q.question_id=x.alias_question_id;

delete from english.difficult_state d
using english.phrasal_question_aliases x
where d.question_id=x.alias_question_id;

delete from english.learning_route_state r
using english.phrasal_question_aliases x
where r.question_id=x.alias_question_id;

delete from english.phrasal_question_variants v
using english.phrasal_question_aliases x
where v.question_id=x.alias_question_id;

-- Exact snapshot rows remain as immutable historical shells, but are no longer eligible bank variants.
update english.questions q
set active=false,
    content_status='Inactive',
    review_notes=concat_ws(' | ',nullif(q.review_notes,''),'Exact Phrasal snapshot alias -> '||x.canonical_question_id),
    updated_at=now()
from english.phrasal_question_aliases x
where q.question_id=x.alias_question_id;

-- Today/history now read membership, not question.source_id.
create or replace function public.english_get_phrasal_today()
returns jsonb
language sql stable security definer
set search_path to 'pg_catalog','public','english','auth'
as $function$
select case when auth.uid() is null then '[]'::jsonb
else coalesce(jsonb_agg(
  english.question_payload(auth.uid(),q.question_id)
  || jsonb_build_object(
       'phrasalQuestionFamily',d.question_family,
       'phrasalConceptId',d.concept_id
     )
  order by d.slot_no
),'[]'::jsonb) end
from english.phrasal_daily_items d
join english.questions q on q.question_id=d.question_id and q.active
left join english.question_state s on s.user_id=auth.uid() and s.question_id=q.question_id
where d.batch_date=(now() at time zone 'Asia/Kolkata')::date
  and not coalesce(s.mastered,false);
$function$;

create or replace function public.english_get_phrasal_history_batch(p_from_day integer,p_to_day integer)
returns jsonb
language plpgsql stable security definer
set search_path to 'pg_catalog','public','english','auth'
as $function$
declare
  uid uuid:=auth.uid();
  lo integer:=greatest(1,coalesce(p_from_day,1));
  hi integer:=greatest(greatest(1,coalesce(p_from_day,1)),coalesce(p_to_day,p_from_day,1));
  out jsonb;
begin
  if uid is null then raise exception 'Authentication required'; end if;
  with days as (
    select batch_date,row_number() over(order by batch_date)::int day_no
    from (select distinct batch_date from english.phrasal_daily_items) x
  ), picked as (
    select d.batch_date,d.slot_no,d.question_id,ds.day_no
    from english.phrasal_daily_items d
    join days ds using(batch_date)
    left join english.question_state s on s.user_id=uid and s.question_id=d.question_id
    where ds.day_no between lo and hi and not coalesce(s.mastered,false)
  )
  select coalesce(jsonb_agg(
    english.question_payload(uid,p.question_id)
    order by p.day_no,p.slot_no
  ),'[]'::jsonb)
  into out
  from picked p
  join english.questions q on q.question_id=p.question_id and q.active;
  return out;
end;
$function$;

create or replace function english.maintenance_verify_phrasal_daily()
returns jsonb
language plpgsql security definer
set search_path to 'pg_catalog','public','english','auth'
as $function$
declare
  v_owner uuid;
  v_owner_count integer;
  v_day date:=(now() at time zone 'Asia/Kolkata')::date;
  v_source_id text;
  v_hub jsonb;
  v_count integer;
  v_mapped integer;
begin
  select count(*),max(u.id::text)::uuid into v_owner_count,v_owner
  from auth.users u where u.deleted_at is null;
  if v_owner_count<>1 then raise exception 'Phrasal maintenance requires exactly one active auth owner'; end if;
  perform set_config('request.jwt.claim.sub',v_owner::text,true);
  v_source_id:='PHRASAL_DAILY_'||to_char(v_day,'YYYYMMDD');

  select count(*) into v_count
  from english.phrasal_daily_items d
  join english.questions q on q.question_id=d.question_id and q.active
  where d.batch_date=v_day;

  select count(*) into v_mapped
  from english.phrasal_daily_items d
  join english.questions q on q.question_id=d.question_id and q.active
  join english.question_concept_mappings m
    on m.question_id=q.question_id and m.concept_id=d.concept_id
  where d.batch_date=v_day;

  v_hub:=public.english_get_phrasal_hub();
  return jsonb_build_object(
    'ok',v_count=20 and v_mapped=20
      and exists(select 1 from english.sources s where s.source_id=v_source_id and s.active and s.question_count=20 and lower(coalesce(s.import_status,''))='complete'),
    'sourceId',v_source_id,
    'questionCount',v_count,
    'membershipCount',v_count,
    'mappedCount',v_mapped,
    'sourceComplete',exists(select 1 from english.sources s where s.source_id=v_source_id and s.active and s.question_count=20 and lower(coalesce(s.import_status,''))='complete'),
    'today',v_hub->'today',
    'questionIds',(select coalesce(jsonb_agg(d.question_id order by d.slot_no),'[]'::jsonb) from english.phrasal_daily_items d where d.batch_date=v_day)
  );
end;
$function$;

create or replace function english.maintenance_phrasal_batch(p_count integer default 20)
returns jsonb
language plpgsql security definer
set search_path to 'pg_catalog','public','english','auth'
as $function$
declare
  v_owner uuid; v_owner_count integer;
  v_count integer:=greatest(1,least(20,coalesce(p_count,20)));
  v_items jsonb; v_day date:=(now() at time zone 'Asia/Kolkata')::date; v_source_id text;
begin
  select count(*),max(u.id::text)::uuid into v_owner_count,v_owner from auth.users u where u.deleted_at is null;
  if v_owner_count<>1 then raise exception 'Phrasal maintenance requires exactly one active auth owner'; end if;
  perform set_config('request.jwt.claim.sub',v_owner::text,true);
  v_items:=case when english.ai_feature_enabled('phrasal_context_fill_v1')
    then public.english_get_phrasal_hybrid_maintenance_batch('smart',v_count)
    else public.english_get_phrasal_maintenance_batch('smart',v_count) end;
  v_source_id:='PHRASAL_DAILY_'||to_char(v_day,'YYYYMMDD');
  return jsonb_build_object(
    'ok',true,'date',v_day,'sourceId',v_source_id,
    'sourceFile','Phrasal Daily '||to_char(v_day,'YYYY-MM-DD'),
    'count',jsonb_array_length(coalesce(v_items,'[]'::jsonb)),
    'existingToday',(select count(*) from english.phrasal_daily_items where batch_date=v_day),
    'items',coalesce(v_items,'[]'::jsonb)
  );
end;
$function$;

-- Identity-aware hybrid publisher: reuse legacy bank IDs, create IDs only for genuinely new variants.
create or replace function english.maintenance_apply_phrasal_hybrid_core(p_items jsonb)
returns jsonb
language plpgsql security definer
set search_path to 'pg_catalog','public','english','auth'
as $function$
declare
  v_owner uuid;
  v_owner_count integer;
  v_day date:=(now() at time zone 'Asia/Kolkata')::date;
  v_source_id text;
  v_source_file text;
  v_expected jsonb;
  v_expected_ids text[];
  v_given_ids text[];
  v_existing integer;
  v_start integer;
  v_ord integer:=0;
  v_item jsonb;
  v_concept text;
  v_expected_requested_family text;
  v_expected_legacy_family text;
  v_requested_family text;
  v_family text;
  v_provider text;
  v_base_id text;
  v_qid text;
  v_question_type text;
  v_correct text;
  v_created text[]:='{}'::text[];
  v_new_count integer:=0;
  v_recall_count integer:=0;
  v_bad integer;
  v_is_new boolean;
begin
  if p_items is null or jsonb_typeof(p_items)<>'array' then raise exception 'p_items must be a JSON array'; end if;
  if jsonb_array_length(p_items)<>20 then raise exception 'Phrasal hybrid materialization requires exactly 20 finalized items'; end if;

  select count(*),max(u.id::text)::uuid into v_owner_count,v_owner
  from auth.users u where u.deleted_at is null;
  if v_owner_count<>1 then raise exception 'Phrasal maintenance requires exactly one active auth owner'; end if;
  perform set_config('request.jwt.claim.sub',v_owner::text,true);

  v_source_id:='PHRASAL_DAILY_'||to_char(v_day,'YYYYMMDD');
  v_source_file:='Phrasal Daily '||to_char(v_day,'YYYY-MM-DD');
  perform pg_advisory_xact_lock(hashtext('english.maintenance_phrasal_daily'));

  select count(*) into v_existing from english.phrasal_daily_items where batch_date=v_day;
  if v_existing=20
     and exists(select 1 from english.sources s where s.source_id=v_source_id and s.active and s.question_count=20 and lower(coalesce(s.import_status,''))='complete') then
    return jsonb_build_object(
      'ok',true,'alreadyComplete',true,'sourceId',v_source_id,'count',20,
      'questionIds',(select coalesce(jsonb_agg(d.question_id order by d.slot_no),'[]'::jsonb) from english.phrasal_daily_items d where d.batch_date=v_day)
    );
  end if;
  if v_existing>0 then
    raise exception 'Partial Phrasal daily membership exists; refusing destructive rebuild';
  end if;

  v_expected:=public.english_get_phrasal_hybrid_maintenance_batch('smart',20);
  if jsonb_array_length(coalesce(v_expected,'[]'::jsonb))<>20 then
    raise exception 'Central Phrasal hybrid selector did not return 20 slots';
  end if;

  select array_agg(x order by x) into v_expected_ids
  from (
    select distinct coalesce(nullif(e.value->>'phrasalConceptId',''),nullif(e.value->>'conceptId','')) x
    from jsonb_array_elements(v_expected) e(value)
  ) s where x is not null;
  select array_agg(x order by x) into v_given_ids
  from (
    select distinct nullif(btrim(e.value->>'conceptId'),'') x
    from jsonb_array_elements(p_items) e(value)
  ) s where x is not null;

  if cardinality(coalesce(v_given_ids,'{}'::text[]))<>20 or v_expected_ids is distinct from v_given_ids then
    raise exception 'Finalized Phrasal payload does not match the exact current 20 Central-selected concepts';
  end if;

  select coalesce(max((substring(q.question_id from '^PV([0-9]+)$'))::int),0)
  into v_start from english.questions q where q.question_id ~ '^PV[0-9]+$';

  for v_item in select value from jsonb_array_elements(p_items) loop
    v_ord:=v_ord+1;
    v_concept:=btrim(coalesce(v_item->>'conceptId',''));
    v_requested_family:=lower(btrim(coalesce(v_item->>'requestedQuestionFamily',v_item->>'questionFamily',v_item->>'family','')));
    v_family:=case when v_requested_family='context_fill' then 'recognition'
      else lower(btrim(coalesce(v_item->>'family',v_item->>'legacyFamily',v_requested_family,''))) end;
    v_provider:=lower(btrim(coalesce(v_item->>'generatorProvider','legacy_bank')));
    v_base_id:=nullif(btrim(coalesce(v_item->>'baseQuestionId','')),'');
    v_question_type:=btrim(coalesce(v_item->>'questionType',''));
    v_correct:=upper(btrim(coalesce(v_item->>'correctKey','')));

    select
      lower(coalesce(nullif(e.value->>'requestedQuestionFamily',''),nullif(e.value->>'missingFamily',''),nullif(e.value->>'phrasalQuestionFamily',''),'recognition')),
      lower(coalesce(nullif(e.value->>'legacyFamily',''),nullif(e.value->>'missingFamily',''),nullif(e.value->>'phrasalQuestionFamily',''),'recognition'))
    into v_expected_requested_family,v_expected_legacy_family
    from jsonb_array_elements(v_expected) e(value)
    where coalesce(nullif(e.value->>'phrasalConceptId',''),nullif(e.value->>'conceptId',''))=v_concept
    limit 1;

    if v_requested_family not in ('recognition','recall','confusion','context_fill') then
      raise exception 'Invalid requested Phrasal family for concept %',v_concept;
    end if;
    if v_family not in ('recognition','recall','confusion') then
      raise exception 'Invalid legacy Phrasal family for concept %',v_concept;
    end if;
    if v_expected_requested_family='context_fill' then
      if v_requested_family<>'context_fill' or v_family<>'recognition' then
        raise exception 'Context-fill family mismatch for concept %',v_concept;
      end if;
    elsif v_requested_family<>v_expected_requested_family or v_family<>v_expected_legacy_family then
      raise exception 'Phrasal family mismatch for concept %: expected requested % / legacy %, got % / %',
        v_concept,v_expected_requested_family,v_expected_legacy_family,v_requested_family,v_family;
    end if;

    if btrim(coalesce(v_item->>'question',''))='' or btrim(coalesce(v_item->>'explanation',''))='' then
      raise exception 'Question and explanation are required for concept %',v_concept;
    end if;
    if btrim(coalesce(v_item->>'optionA',''))='' or btrim(coalesce(v_item->>'optionB',''))='' or btrim(coalesce(v_item->>'optionC',''))='' then
      raise exception 'Options A-C are required for concept %',v_concept;
    end if;
    if v_family='recall' then
      if v_correct<>'A'
         or v_question_type<>'Reverse Recall Card'
         or coalesce(v_item->>'optionA','')<>'Yaad tha'
         or coalesce(v_item->>'optionB','')<>'Confused'
         or coalesce(v_item->>'optionC','')<>'Bhool gaya'
         or coalesce(v_item->>'optionD','')<>'' then
        raise exception 'Reverse Recall Card must preserve Yaad tha / Confused / Bhool gaya self-assessment semantics for concept %',v_concept;
      end if;
    else
      if btrim(coalesce(v_item->>'optionD',''))='' or v_correct not in ('A','B','C','D') then
        raise exception 'Recognition/confusion/context card requires four options and one A-D key for concept %',v_concept;
      end if;
    end if;

    v_is_new:=false;
    if v_provider='legacy_bank' then
      if v_base_id is null then raise exception 'Legacy-bank slot is missing baseQuestionId for concept %',v_concept; end if;
      select q.question_id into v_qid
      from english.questions q
      where q.question_id=v_base_id and q.active
        and coalesce(nullif(btrim(q.concept_id),''),'PVQ_'||q.question_id)=v_concept
        and btrim(coalesce(q.question,''))=btrim(coalesce(v_item->>'question',''))
        and btrim(coalesce(q.option_a,''))=btrim(coalesce(v_item->>'optionA',''))
        and btrim(coalesce(q.option_b,''))=btrim(coalesce(v_item->>'optionB',''))
        and btrim(coalesce(q.option_c,''))=btrim(coalesce(v_item->>'optionC',''))
        and btrim(coalesce(q.option_d,''))=btrim(coalesce(v_item->>'optionD',''))
        and upper(btrim(coalesce(q.correct,'')))=v_correct
        and btrim(coalesce(q.explanation,''))=btrim(coalesce(v_item->>'explanation',''));
      if v_qid is null then
        raise exception 'Legacy-bank base payload mismatch for concept % / base %',v_concept,v_base_id;
      end if;
    else
      select q.question_id into v_qid
      from english.questions q
      where q.active
        and coalesce(nullif(btrim(q.concept_id),''),'PVQ_'||q.question_id)=v_concept
        and btrim(coalesce(q.question,''))=btrim(coalesce(v_item->>'question',''))
        and btrim(coalesce(q.option_a,''))=btrim(coalesce(v_item->>'optionA',''))
        and btrim(coalesce(q.option_b,''))=btrim(coalesce(v_item->>'optionB',''))
        and btrim(coalesce(q.option_c,''))=btrim(coalesce(v_item->>'optionC',''))
        and btrim(coalesce(q.option_d,''))=btrim(coalesce(v_item->>'optionD',''))
        and upper(btrim(coalesce(q.correct,'')))=v_correct
        and btrim(coalesce(q.explanation,''))=btrim(coalesce(v_item->>'explanation',''))
      order by q.created_at,q.question_id
      limit 1;

      if v_qid is null then
        v_start:=v_start+1;
        v_qid:='PV'||lpad(v_start::text,4,'0');
        v_is_new:=true;
        insert into english.questions(
          question_id,topic,word,question,option_a,option_b,option_c,option_d,correct,explanation,
          subtopic,question_type,source_file,source_page,concept_id,difficulty,source_id,learning_status,content_status,
          exam_relevance,tip,usage_note,example_sentence,memory_aid,related_words,source_url,review_notes,active,created_at,updated_at
        ) values (
          v_qid,'Phrasal Verb',nullif(v_item->>'word',''),v_item->>'question',
          v_item->>'optionA',v_item->>'optionB',v_item->>'optionC',coalesce(v_item->>'optionD',''),
          v_correct,v_item->>'explanation','Phrasal Verbs',v_question_type,
          v_source_file,coalesce(v_item->>'sourcePage',''),v_concept,
          coalesce(nullif(v_item->>'difficulty',''),'Hard'),'PHRASAL_GENERATED_VARIANT','New','Active',
          'SSC CGL',coalesce(v_item->>'tip',''),coalesce(v_item->>'usageNote',''),
          coalesce(v_item->>'example',''),coalesce(v_item->>'memoryAid',''),coalesce(v_item->>'related',''),
          coalesce(v_item->>'sourceUrl',''),
          'Permanent Phrasal variant; first daily membership='||v_source_id||
          '; base='||coalesce(v_base_id,'none')||
          '; requested_family='||v_requested_family||'; legacy_family='||v_family,
          true,now(),now()
        );
        insert into english.question_origins(question_id,origin_kind,origin_ref,owner_user_id)
        values(v_qid,'core','PHRASAL_GENERATED_VARIANT',null)
        on conflict(question_id) do nothing;
      end if;
    end if;

    insert into english.phrasal_daily_items(
      batch_date,slot_no,source_id,question_id,original_question_id,concept_id,
      requested_family,question_family,generator_provider,is_new_variant,metadata
    ) values (
      v_day,v_ord,v_source_id,v_qid,v_qid,v_concept,
      v_requested_family,
      coalesce(nullif(v_item->>'questionFamily',''),v_requested_family),
      v_provider,v_is_new,
      jsonb_build_object('baseQuestionId',v_base_id,'variantKey',coalesce(v_item->>'variantKey',''))
    );

    v_created:=array_append(v_created,v_qid);
    if v_is_new then v_new_count:=v_new_count+1; end if;
    if v_family='recall' then v_recall_count:=v_recall_count+1; end if;
  end loop;

  insert into english.sources(
    source_id,source_type,source_name,source_file,source_date,active,imported_on,question_count,
    source_ref,notes,import_status,new_count,recall_count,duplicate_count,category_summary,processed_on
  ) values (
    v_source_id,'Generated Practice',v_source_file,v_source_file,v_day,true,now(),20,
    'Supabase Central Phrasal Intelligence',
    'Central-selected 20-slot adaptive Phrasal membership. Existing bank variants retain permanent Question_IDs; only genuinely new generated variants receive new IDs.',
    'Complete',v_new_count,v_recall_count,0,'Phrasal Verb: 20',now()
  )
  on conflict(source_id) do update set
    source_type=excluded.source_type,source_name=excluded.source_name,source_file=excluded.source_file,
    source_date=excluded.source_date,active=true,question_count=20,source_ref=excluded.source_ref,
    notes=excluded.notes,import_status='Complete',new_count=excluded.new_count,
    recall_count=excluded.recall_count,duplicate_count=0,category_summary=excluded.category_summary,processed_on=now();

  select count(*) into v_bad
  from english.phrasal_daily_items d
  join english.questions q on q.question_id=d.question_id
  where d.batch_date=v_day and (
    not q.active or q.concept_id is null or btrim(q.question)=''
    or upper(coalesce(q.correct,'')) not in ('A','B','C','D')
    or btrim(coalesce(q.explanation,''))=''
  );

  if (select count(*) from english.phrasal_daily_items where batch_date=v_day)<>20
     or v_bad<>0 then
    raise exception 'Phrasal hybrid post-materialization integrity validation failed';
  end if;

  return jsonb_build_object(
    'ok',true,'alreadyComplete',false,'sourceId',v_source_id,'count',20,
    'newCount',v_new_count,'recallCount',v_recall_count,'questionIds',to_jsonb(v_created)
  );
end;
$function$;

-- Map membership questions into Central Intelligence instead of filtering by source_id.
create or replace function public.english_phrasal_task_apply(p_run_id uuid,p_items jsonb)
returns jsonb
language plpgsql security definer
set search_path to 'pg_catalog','public','english'
as $function$
declare
  r english.chatgpt_content_task_runs%rowtype;
  v_apply jsonb;
  v_verify jsonb;
  v_day date:=(now() at time zone 'Asia/Kolkata')::date;
  v_total integer;
  v_mapped integer;
  v_antigravity integer;
  v_legacy integer;
  v_deterministic integer;
begin
  select * into r from english.chatgpt_content_task_runs where run_id=p_run_id and lane='phrasal' for update;
  if not found then raise exception 'Unknown Phrasal run'; end if;
  if r.status='applied' then return coalesce(r.result,jsonb_build_object('ok',true,'alreadyApplied',true)); end if;
  if r.status<>'claimed' then raise exception 'Phrasal run is not claimable: %',r.status; end if;

  v_apply:=english.maintenance_apply_phrasal_hybrid(p_items);

  insert into english.question_concept_mappings(
    question_id,concept_id,mapping_confidence,mapping_method,review_status,relation_type
  )
  select distinct q.question_id,d.concept_id,1,'deterministic_metadata','mapped','primary'
  from english.phrasal_daily_items d
  join english.questions q on q.question_id=d.question_id and q.active
  join english.concepts c on c.concept_id=d.concept_id and c.active
  where d.batch_date=v_day
  on conflict(question_id) do update set
    concept_id=excluded.concept_id,mapping_confidence=1,mapping_method='deterministic_metadata',
    review_status='mapped',relation_type='primary',updated_at=now();

  v_verify:=english.maintenance_verify_phrasal_daily();
  select count(*) into v_total from english.phrasal_daily_items where batch_date=v_day;
  select count(*) into v_mapped
  from english.phrasal_daily_items d
  join english.question_concept_mappings m on m.question_id=d.question_id and m.concept_id=d.concept_id
  where d.batch_date=v_day;

  select count(*) filter(where lower(coalesce(generator_provider,''))='antigravity'),
         count(*) filter(where lower(coalesce(generator_provider,''))='legacy_bank'),
         count(*) filter(where lower(coalesce(generator_provider,''))='deterministic_recall')
  into v_antigravity,v_legacy,v_deterministic
  from english.phrasal_daily_items where batch_date=v_day;

  update english.sources
  set notes='Central-selected adaptive Phrasal batch. Permanent identity reuse: '||
            v_legacy||' legacy-bank slots reused existing Question_IDs; '||
            v_antigravity||' Antigravity variants; '||
            v_deterministic||' deterministic recall fillers.'
  where source_id='PHRASAL_DAILY_'||to_char(v_day,'YYYYMMDD');

  if not coalesce((v_verify->>'ok')::boolean,false) or v_total<>20 or v_mapped<>20 then
    raise exception 'Phrasal verification/Central Intelligence mapping failed: memberships %, mapped %',v_total,v_mapped;
  end if;

  update english.chatgpt_content_task_runs
  set status='applied',
      result=jsonb_build_object('apply',v_apply,'verify',v_verify,'centralMapped',v_mapped),
      applied_at=now(),updated_at=now()
  where run_id=p_run_id;

  return jsonb_build_object('ok',true,'apply',v_apply,'verify',v_verify,'centralMapped',v_mapped);
end;
$function$;

create or replace function public.english_get_phrasal_hub()
returns jsonb
language plpgsql security definer
set search_path to 'pg_catalog','public','english','auth'
as $function$
declare
  uid uuid:=auth.uid();out jsonb;
  v_total int;v_exposed int;v_due int;v_weak int;v_recall_weak int;v_diff int;v_star int;
  v_mastered int;v_fresh int;v_eligible int;v_today int;v_history jsonb;
  v_current_day int;v_current_block_start int;v_current_month int;v_current_month_start int;
begin
  if uid is null then raise exception 'Authentication required'; end if;

  select count(*),count(*) filter(where attempts>0),
         count(*) filter(where active_variant_count>0 and (not proven_mastery or fresh_variant_count>0) and due),
         count(*) filter(where active_variant_count>0 and (not proven_mastery or fresh_variant_count>0) and (state in ('Persistent Weak','Weak','Fragile') or recall_weak)),
         count(*) filter(where active_variant_count>0 and (not proven_mastery or fresh_variant_count>0) and recall_weak),
         count(*) filter(where active_variant_count>0 and (not proven_mastery or fresh_variant_count>0) and difficult),
         count(*) filter(where active_variant_count>0 and (not proven_mastery or fresh_variant_count>0) and starred),
         count(*) filter(where proven_mastery),
         count(*) filter(where active_variant_count>0 and proven_mastery and fresh_variant_count>0),
         count(*) filter(where active_variant_count>0 and (not proven_mastery or fresh_variant_count>0))
  into v_total,v_exposed,v_due,v_weak,v_recall_weak,v_diff,v_star,v_mastered,v_fresh,v_eligible
  from english.phrasal_concepts(uid);

  select count(*) into v_today
  from english.phrasal_daily_items d
  join english.questions q on q.question_id=d.question_id and q.active
  where d.batch_date=(now() at time zone 'Asia/Kolkata')::date;

  create temporary table if not exists pg_temp.phrasal_days(day_no int,d date,generated int,practised int) on commit drop;
  truncate pg_temp.phrasal_days;
  insert into pg_temp.phrasal_days
  with dates as (
    select distinct batch_date d from english.phrasal_daily_items
  ), numbered as (
    select d,row_number() over(order by d)::int day_no from dates
  )
  select n.day_no,n.d,count(i.question_id)::int,
         count(i.question_id) filter(where exists(
           select 1 from english.attempts a
           where a.user_id=uid and a.question_id=i.question_id
             and lower(coalesce(a.module,'')) in ('phrasaldaily','phrasalrevision')
             and (a.attempted_at at time zone 'Asia/Kolkata')::date=n.d
         ))::int
  from numbered n
  join english.phrasal_daily_items i on i.batch_date=n.d
  group by n.day_no,n.d order by n.day_no;

  select coalesce(max(day_no),0) into v_current_day from pg_temp.phrasal_days;
  if v_current_day=0 then
    v_history:='[]'::jsonb;
  else
    v_current_block_start:=((v_current_day-1)/10)*10+1;
    v_current_month:=((v_current_day-1)/30)+1;
    v_current_month_start:=(v_current_month-1)*30+1;
    with day_entries as (
      select 1 grp,-day_no sk,jsonb_build_object(
        'type','day','label',case when d=(now() at time zone 'Asia/Kolkata')::date then 'Today' else 'Day '||day_no end,
        'fromDay',day_no,'toDay',day_no,'generated',generated,'practised',practised,'date',d
      ) j
      from pg_temp.phrasal_days where day_no between v_current_block_start and v_current_day
    ), block_starts as (
      select generate_series(v_current_block_start-10,v_current_month_start,-10)::int start_day
      where v_current_block_start-10>=v_current_month_start
    ), block_entries as (
      select 2 grp,-b.start_day sk,jsonb_build_object(
        'type','block','label','Days '||b.start_day||'–'||least(b.start_day+9,v_current_day),
        'fromDay',b.start_day,'toDay',least(b.start_day+9,v_current_day),
        'generated',sum(d.generated),'practised',sum(d.practised)
      ) j
      from block_starts b join pg_temp.phrasal_days d
        on d.day_no between b.start_day and least(b.start_day+9,v_current_day)
      group by b.start_day
    ), months as (
      select generate_series(v_current_month-1,1,-1)::int mon where v_current_month>1
    ), month_entries as (
      select 3 grp,-m.mon sk,jsonb_build_object(
        'type','month','label','Month '||m.mon,'fromDay',(m.mon-1)*30+1,'toDay',m.mon*30,
        'generated',sum(d.generated),'practised',sum(d.practised)
      ) j
      from months m join pg_temp.phrasal_days d
        on d.day_no between (m.mon-1)*30+1 and m.mon*30
      group by m.mon
    ), all_e as (
      select * from day_entries union all select * from block_entries union all select * from month_entries
    )
    select coalesce(jsonb_agg(j order by grp,sk),'[]'::jsonb) into v_history from all_e;
  end if;

  out:=jsonb_build_object(
    'version','V1.4','generatedAt',now(),'dailyTarget',20,
    'stats',jsonb_build_object(
      'totalConcepts',v_total,'exposed',v_exposed,
      'exposurePercent',case when v_total>0 then round(v_exposed*1000.0/v_total)/10 else 0 end,
      'due',v_due,'weak',v_weak,'recallWeak',v_recall_weak,'difficult',v_diff,'starred',v_star,
      'mastered',v_mastered,'freshVariantChecks',v_fresh,'eligible',v_eligible
    ),
    'today',jsonb_build_object(
      'date',(now() at time zone 'Asia/Kolkata')::date,'count',v_today,'target',20,
      'ready',v_today>0,'sourceId','PHRASAL_DAILY_'||to_char((now() at time zone 'Asia/Kolkata')::date,'YYYYMMDD')
    ),
    'available',jsonb_build_object('smart',v_eligible,'weak',v_weak,'difficult',v_diff,'starred',v_star,'random',v_eligible,'all',v_eligible),
    'sizes',jsonb_build_array(10,20,30,50),'history',v_history
  );
  return out;
end;
$function$;

create or replace function public.english_get_home_snapshot()
returns jsonb
language sql stable security definer
set search_path to 'pg_catalog','public','english','auth'
as $function$
with uid as(select auth.uid() id),
summary as(select public.english_dashboard_summary() value),
saved as(select count(*) filter(where not mastered)::int eligible,count(*) filter(where not mastered and due)::int due from uid cross join lateral english.saved_revision_candidates(uid.id)),
starred as(select count(*) filter(where starred and not mastered)::int focus,count(*) filter(where difficult and starred and not mastered)::int difficult from uid cross join lateral english.starred_manual_index(uid.id)),
bank as(select count(*)::int total,count(*) filter(where coalesce(s.attempts,0)>0)::int exposed from uid join english.questions q on uid.id is not null and english.is_genuine_bank_question(q) left join english.question_state s on s.user_id=uid.id and s.question_id=q.question_id),
phrasal as(select count(*)::int today_count from uid join english.phrasal_daily_items d on uid.id is not null and d.batch_date=(now() at time zone 'Asia/Kolkata')::date join english.questions q on q.question_id=d.question_id and q.active and english.question_visible_to_user(uid.id,q.question_id)),
hindu as(select coalesce(jsonb_agg(jsonb_build_object('id',h.hindu_id) order by h.hindu_id),'[]'::jsonb) rows from uid join english.hindu_words h on uid.id is not null and h.active and h.word_date=(now() at time zone 'Asia/Kolkata')::date),
targeted as(select count(*)::int active,count(*) filter(where coalesce(ce.next_review,now())<=now())::int due_now from uid join english.learning_route_state r on r.user_id=uid.id and r.route='targeted' left join english.question_concept_mappings m on m.question_id=r.question_id left join english.concept_evidence ce on ce.user_id=uid.id and ce.concept_id=m.concept_id)
select case when uid.id is null then jsonb_build_object('ok',false,'error','Authentication required') else
jsonb_build_object(
  'ok',true,
  'studyDay',greatest(1,((now() at time zone 'Asia/Kolkata')::date-date '2026-08-14')+1),
  'summary',summary.value,
  'intelligence',jsonb_build_object(
    'daily',jsonb_build_object('actionableRemaining',coalesce((summary.value->>'daily_remaining')::int,0),'suppressed',coalesce((summary.value->>'daily_suppressed')::int,0)),
    'coreCoverage',jsonb_build_object('percent',case when bank.total>0 then round(bank.exposed*100.0/bank.total,1) else 0 end)
  ),
  'phrasal',jsonb_build_object('today',jsonb_build_object('ready',phrasal.today_count>0,'count',phrasal.today_count),'stats',jsonb_build_object('due',0)),
  'bank',jsonb_build_object('total',bank.total,'exposed',bank.exposed,'coverage',case when bank.total>0 then round(bank.exposed*100.0/bank.total,1) else 0 end),
  'targeted',jsonb_build_object('active',targeted.active,'due',targeted.due_now),
  'saved',jsonb_build_object('stats',jsonb_build_object('saved',saved.eligible,'eligible',saved.eligible,'due',saved.due)),
  'starred',jsonb_build_object('stats',jsonb_build_object('focus',starred.focus,'manualDifficult',starred.difficult,'difficult',starred.difficult)),
  'hindu',hindu.rows
) end
from uid cross join summary cross join saved cross join starred cross join bank cross join phrasal cross join hindu cross join targeted;
$function$;

-- Keep audit focused on permanent active identities and the separate daily membership.
create or replace function public.english_get_phrasal_audit()
returns jsonb
language plpgsql stable security definer
set search_path to 'pg_catalog','public','english','auth'
as $function$
declare uid uuid:=auth.uid();out jsonb;
begin
  if uid is null then raise exception 'Authentication required'; end if;
  with qs as (
    select q.*,coalesce(nullif(btrim(q.concept_id),''),'PVQ_'||q.question_id) ckey
    from english.questions q
    where q.active and english.question_visible_to_user(auth.uid(),q.question_id)
      and (english.canonical_category(q.topic)='PHRASAL' or lower(btrim(coalesce(q.topic,'')))='phrasal verb')
  ), today as (
    select concept_id,count(*) n
    from english.phrasal_daily_items
    where batch_date=(now() at time zone 'Asia/Kolkata')::date
    group by concept_id having count(*)>1
  ), c as (select * from english.phrasal_concepts(uid))
  select jsonb_build_object(
    'ok',not exists(select 1 from today),
    'questions',(select count(*) from qs),
    'concepts',(select count(*) from c),
    'todayCount',(select count(*) from english.phrasal_daily_items where batch_date=(now() at time zone 'Asia/Kolkata')::date),
    'todayDuplicateConcepts',coalesce((select jsonb_agg(concept_id) from today),'[]'::jsonb),
    'stats',jsonb_build_object(
      'eligible',(select count(*) from c where active_variant_count>0 and (not proven_mastery or fresh_variant_count>0)),
      'recallWeak',(select count(*) from c where recall_weak),
      'recognitionStrongRecallWeak',(select count(*) from c where recall_weak and recognition_strong),
      'recallConfused',(select coalesce(sum(recall_confused),0) from c),
      'recallForgotten',(select coalesce(sum(recall_forgotten),0) from c)
    )
  ) into out;
  return out;
end;
$function$;

-- Protect future generated-variant metadata lookups from inactive aliases.
create or replace function public.english_get_phrasal_sense_evidence(p_concept_id text default null::text)
returns jsonb
language plpgsql stable security definer
set search_path to 'pg_catalog','public','english','auth'
as $function$
declare uid uuid:=auth.uid();result jsonb;
begin
  if uid is null then raise exception 'Authentication required'; end if;
  select coalesce(jsonb_agg(jsonb_build_object(
    'conceptId',e.concept_id,'senseKey',e.sense_key,'senseGloss',coalesce(s.gloss,''),
    'questionFamily',e.question_family,'attempts',e.attempts,'correct',e.correct_count,
    'accuracy',case when e.attempts>0 then round((e.correct_count::numeric/e.attempts::numeric)*100,1) else null end,
    'distinctVariants',e.distinct_variants,'lastAttempt',e.last_attempt
  ) order by e.last_attempt desc nulls last,e.concept_id,e.sense_key,e.question_family),'[]'::jsonb)
  into result
  from (
    select v.concept_id,coalesce(nullif(v.sense_key,''),'legacy_default') sense_key,v.question_family,
           count(a.*)::int attempts,count(a.*) filter(where a.correct)::int correct_count,
           count(distinct v.question_id)::int distinct_variants,max(a.attempted_at) last_attempt
    from english.phrasal_question_variants v
    join english.questions q on q.question_id=v.question_id and q.active
    join english.attempts a on a.question_id=v.question_id and a.user_id=uid
    where p_concept_id is null or v.concept_id=p_concept_id
    group by v.concept_id,coalesce(nullif(v.sense_key,''),'legacy_default'),v.question_family
  ) e
  left join english.phrasal_concept_senses s on s.concept_id=e.concept_id and s.sense_key=e.sense_key;
  return coalesce(result,'[]'::jsonb);
end;
$function$;

-- Recompute concept evidence after all attempts have been consolidated.
do $do$
declare r record;
begin
  for r in
    select distinct a.user_id,m.concept_id
    from english.attempts a
    join english.question_concept_mappings m on m.question_id=a.question_id
    where exists(
      select 1 from english.phrasal_question_aliases x
      where x.canonical_question_id=a.question_id
    )
  loop
    perform english.recompute_concept_evidence(r.user_id,r.concept_id);
  end loop;
end
$do$;
