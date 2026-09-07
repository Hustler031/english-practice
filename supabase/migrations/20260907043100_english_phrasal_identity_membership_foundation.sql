create table if not exists english.phrasal_question_aliases (
  alias_question_id text primary key references english.questions(question_id) on delete cascade,
  canonical_question_id text not null references english.questions(question_id) on delete restrict,
  reason text not null default 'exact_daily_snapshot_duplicate',
  created_at timestamptz not null default now(),
  check (alias_question_id <> canonical_question_id)
);
create index if not exists english_phrasal_question_aliases_canonical_idx on english.phrasal_question_aliases(canonical_question_id);

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
create index if not exists english_phrasal_daily_items_source_idx on english.phrasal_daily_items(source_id);
create index if not exists english_phrasal_daily_items_question_idx on english.phrasal_daily_items(question_id);
create index if not exists english_phrasal_daily_items_concept_idx on english.phrasal_daily_items(concept_id);
revoke all on table english.phrasal_question_aliases from public,anon,authenticated;
revoke all on table english.phrasal_daily_items from public,anon,authenticated;
grant select,insert,update,delete on table english.phrasal_question_aliases to service_role;
grant select,insert,update,delete on table english.phrasal_daily_items to service_role;

with sig as (
  select q.question_id,q.concept_id,q.source_id,q.created_at,
         md5(concat_ws(E'\x1f',coalesce(q.concept_id,''),coalesce(q.question,''),coalesce(q.option_a,''),coalesce(q.option_b,''),coalesce(q.option_c,''),coalesce(q.option_d,''),coalesce(q.correct,''),coalesce(q.explanation,''))) payload_sig
  from english.questions q
  where q.active and (english.canonical_category(q.topic)='PHRASAL' or lower(btrim(coalesce(q.topic,'')))='phrasal verb')
), ranked as (
  select s.*,
         first_value(question_id) over(partition by concept_id,payload_sig order by case when coalesce(source_id,'') ~ '^PHRASAL_DAILY_[0-9]{8}$' then 1 else 0 end,created_at,question_id) canonical_question_id,
         row_number() over(partition by concept_id,payload_sig order by case when coalesce(source_id,'') ~ '^PHRASAL_DAILY_[0-9]{8}$' then 1 else 0 end,created_at,question_id) rn
  from sig s
)
insert into english.phrasal_question_aliases(alias_question_id,canonical_question_id)
select question_id,canonical_question_id from ranked
where rn>1 and coalesce(source_id,'') ~ '^PHRASAL_DAILY_[0-9]{8}$'
on conflict(alias_question_id) do update set canonical_question_id=excluded.canonical_question_id;

with daily as (
  select q.*,
         to_date(substring(q.source_id from 'PHRASAL_DAILY_([0-9]{8})'),'YYYYMMDD') batch_date,
         row_number() over(partition by q.source_id order by case when q.question_id ~ '^PV[0-9]+$' then substring(q.question_id from '^PV([0-9]+)$')::int else 2147483647 end,q.question_id)::int slot_no
  from english.questions q
  where q.source_id ~ '^PHRASAL_DAILY_[0-9]{8}$'
    and (english.canonical_category(q.topic)='PHRASAL' or lower(btrim(coalesce(q.topic,'')))='phrasal verb')
)
insert into english.phrasal_daily_items(batch_date,slot_no,source_id,question_id,original_question_id,concept_id,requested_family,question_family,generator_provider,is_new_variant,metadata)
select d.batch_date,d.slot_no,d.source_id,coalesce(a.canonical_question_id,d.question_id),d.question_id,
       coalesce(nullif(btrim(d.concept_id),''),'PVQ_'||d.question_id),
       coalesce(v.question_family,case when lower(coalesce(d.question_type,'')) ~ 'reverse\s+recall\s+card' then 'recall' when lower(coalesce(d.question_type,'')) ~ 'incorrect|confus|discrimin' then 'confusion' else 'recognition' end),
       coalesce(v.question_family,case when lower(coalesce(d.question_type,'')) ~ 'reverse\s+recall\s+card' then 'recall' when lower(coalesce(d.question_type,'')) ~ 'incorrect|confus|discrimin' then 'confusion' else 'recognition' end),
       coalesce(v.generator_provider,case when a.alias_question_id is not null then 'legacy_bank' else 'historical' end),
       a.alias_question_id is null,
       jsonb_build_object('backfilled',true,'originalSourceId',d.source_id)
from daily d
left join english.phrasal_question_aliases a on a.alias_question_id=d.question_id
left join english.phrasal_question_variants v on v.question_id=d.question_id
on conflict(batch_date,slot_no) do update set source_id=excluded.source_id,question_id=excluded.question_id,original_question_id=excluded.original_question_id,concept_id=excluded.concept_id,requested_family=excluded.requested_family,question_family=excluded.question_family,generator_provider=excluded.generator_provider,is_new_variant=excluded.is_new_variant,metadata=english.phrasal_daily_items.metadata||excluded.metadata;
