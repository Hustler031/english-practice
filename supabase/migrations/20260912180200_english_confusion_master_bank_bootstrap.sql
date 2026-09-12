-- Persist the Phase 1 Daily Confusion source bank so submitted items cannot invent CB ids.

create table if not exists english.confusion_master_bank (
  bank_id text primary key check (bank_id ~ '^CB[0-9]{4}$'),
  category text not null check (category in (
    'Confusable Words',
    'Phrasal Verb Contrast',
    'Look-alike / Spelling',
    'Homophone / Homonym',
    'Usage / Collocation'
  )),
  pair_cluster text not null,
  learning_objective text not null,
  priority_score integer not null default 80 check (priority_score between 0 and 100),
  source_note text not null default 'curated_phase1',
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

insert into english.confusion_master_bank(bank_id,category,pair_cluster,learning_objective,priority_score,source_note)
values
 ('CB0001','Confusable Words','discrete / discreet','Distinguish discrete (separate/distinct) from discreet (tactful/private).',95,'curated_phase1'),
 ('CB0002','Confusable Words','eminent / imminent','Distinguish eminent (distinguished) from imminent (about to happen).',95,'curated_phase1'),
 ('CB0003','Confusable Words','complement / compliment','Distinguish complement (complete/enhance) from compliment (praise).',95,'curated_phase1'),
 ('CB0004','Confusable Words','affect / effect','Distinguish the usual verb affect from the usual noun effect.',92,'curated_phase1'),
 ('CB0005','Phrasal Verb Contrast','bear with / bear up','Distinguish bear with (be patient with) from bear up (remain strong under difficulty).',95,'curated_phase1'),
 ('CB0006','Phrasal Verb Contrast','run over / run down','Distinguish run over (hit/review/exceed time) from run down (criticise/deplete/strike).',92,'curated_phase1'),
 ('CB0007','Phrasal Verb Contrast','put off / put out','Distinguish put off (postpone/discourage) from put out (extinguish/inconvenience).',92,'curated_phase1'),
 ('CB0008','Look-alike / Spelling','admonition / abomination','Distinguish admonition (warning/rebuke) from abomination (detestable thing).',90,'curated_phase1'),
 ('CB0009','Look-alike / Spelling','preclude / proclaim / protract','Distinguish preclude (prevent), proclaim (announce), and protract (prolong).',94,'curated_phase1'),
 ('CB0010','Look-alike / Spelling','adapt / adopt / adept','Distinguish adapt (adjust), adopt (take up), and adept (highly skilled).',94,'curated_phase1'),
 ('CB0011','Homophone / Homonym','stationary / stationery','Distinguish stationary (not moving) from stationery (writing materials).',95,'curated_phase1'),
 ('CB0012','Homophone / Homonym','council / counsel','Distinguish council (deliberative body) from counsel (advice/adviser).',92,'curated_phase1'),
 ('CB0013','Usage / Collocation','good at / good with / good for / good in','Choose the natural preposition after good according to skill, handling, benefit, or context.',95,'curated_phase1'),
 ('CB0014','Usage / Collocation','different from / different to / different than','Recognise standard and context-dependent constructions after different, prioritising SSC-safe usage.',90,'curated_phase1'),
 ('CB0015','Usage / Collocation','dispose of / disposed to','Distinguish dispose of (get rid of/deal with) from be disposed to (be inclined to).',94,'curated_phase1')
on conflict(bank_id) do update set
  category=excluded.category,
  pair_cluster=excluded.pair_cluster,
  learning_objective=excluded.learning_objective,
  priority_score=excluded.priority_score,
  source_note=excluded.source_note,
  active=true,
  updated_at=now();

alter table english.daily_confusion_items
  drop constraint if exists daily_confusion_items_bank_fk;
alter table english.daily_confusion_items
  add constraint daily_confusion_items_bank_fk
  foreign key(bank_id) references english.confusion_master_bank(bank_id);

create or replace function english.guard_daily_confusion_master_bank()
returns trigger
language plpgsql
set search_path = pg_catalog, english
as $$
declare
  b english.confusion_master_bank%rowtype;
begin
  select * into b
  from english.confusion_master_bank
  where bank_id=new.bank_id and active;
  if not found then
    raise exception 'Daily Confusion Bank_ID is not active in confusion_master_bank: %',new.bank_id;
  end if;
  if b.category is distinct from new.category then
    raise exception 'Daily Confusion category mismatch for %: expected %, got %',new.bank_id,b.category,new.category;
  end if;
  if lower(btrim(b.pair_cluster)) is distinct from lower(btrim(new.pair_cluster)) then
    raise exception 'Daily Confusion pair/cluster mismatch for %',new.bank_id;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_daily_confusion_master_bank on english.daily_confusion_items;
create trigger trg_daily_confusion_master_bank
before insert or update of bank_id,category,pair_cluster
on english.daily_confusion_items
for each row execute function english.guard_daily_confusion_master_bank();

comment on table english.confusion_master_bank is
  'Curated source-of-truth pair/cluster bank for Daily Confusion. Phase 1 starts with 15 vetted bootstrap clusters and can be expanded independently.';
