\set ON_ERROR_STOP on
create schema if not exists auth;
create schema if not exists english;
do $$ begin
  if not exists(select 1 from pg_roles where rolname='anon') then create role anon nologin; end if;
  if not exists(select 1 from pg_roles where rolname='authenticated') then create role authenticated nologin; end if;
  if not exists(select 1 from pg_roles where rolname='service_role') then create role service_role nologin; end if;
end $$;

create table auth.users(id uuid primary key);
create table english.questions(
  question_id text primary key,
  topic text,
  source_id text,
  active boolean not null default true
);
create table english.hindu_vocab_registry(
  user_id uuid not null,
  question_id text not null,
  active boolean not null default true,
  marked boolean not null default false,
  in_vocab boolean not null default false,
  primary key(user_id,question_id)
);

create or replace function english.hindu_daily_eligible(p_user_id uuid,p_question_id text)
returns boolean
language sql
stable
security definer
set search_path to 'pg_catalog','english','auth'
as $$
select case
  when not exists(
    select 1 from english.questions q
    where q.question_id=p_question_id
      and (
        lower(coalesce(q.topic,''))='the hindu vocabulary'
        or upper(coalesce(q.source_id,'')) like 'HINDU_%'
      )
  ) then true
  else exists(
    select 1 from english.hindu_vocab_registry r
    where r.user_id=p_user_id
      and r.question_id=p_question_id
      and r.active
      and (coalesce(r.marked,false) or coalesce(r.in_vocab,false))
  )
end;
$$;

-- A compact selector with the same candidate predicate anchor as the production
-- create_daily_core_20260905. The Stage-1 migration rewrites this exact predicate.
create or replace function english.create_daily_core_20260905(p_user_id uuid,p_batch_date date,p_target integer)
returns integer
language plpgsql
security definer
set search_path to 'pg_catalog','english','auth'
as $function$
declare v_count integer;
begin
  with r as (
    select q.question_id,'Weak'::text reason
    from english.questions q
    where q.active
  )
  select count(*) into v_count
  from r
  join english.questions q using(question_id)
  where q.active
    and r.reason<>''
    and not exists(
      select 1 where false
    );
  return least(greatest(1,least(120,coalesce(p_target,120))),v_count);
end;
$function$;

\ir ../../supabase/managed-migrations/20260905101500_english_daily_hindu_proactive_eligibility.sql

insert into auth.users values('00000000-0000-0000-0000-000000000001');
insert into english.questions(question_id,topic,source_id)
select 'Q'||lpad(g::text,3,'0'),'Vocabulary',null from generate_series(1,119) g;
insert into english.questions(question_id,topic,source_id)
values('H001','The Hindu Vocabulary','HINDU_20260905');

-- Exposure-only Hindu must not contribute to Daily capacity.
do $$ declare n integer; def text; begin
  select pg_get_functiondef(p.oid) into def
  from pg_proc p join pg_namespace ns on ns.oid=p.pronamespace
  where ns.nspname='english' and p.proname='create_daily_core_20260905';
  if position('english.hindu_daily_eligible(p_user_id,q.question_id)' in def)=0 then
    raise exception 'Daily selector was not patched with proactive Hindu eligibility';
  end if;
  n:=english.create_daily_core_20260905('00000000-0000-0000-0000-000000000001',current_date,120);
  if n<>119 then raise exception 'Exposure-only Hindu leaked into Daily capacity: expected 119 got %',n; end if;
end $$;

-- Explicit learner retention makes that same Hindu item Daily-eligible.
insert into english.hindu_vocab_registry(user_id,question_id,active,marked,in_vocab)
values('00000000-0000-0000-0000-000000000001','H001',true,true,false);
do $$ declare n integer; begin
  n:=english.create_daily_core_20260905('00000000-0000-0000-0000-000000000001',current_date,120);
  if n<>120 then raise exception 'Marked Hindu did not become Daily-eligible: expected 120 got %',n; end if;
end $$;

-- in_vocab is independently sufficient, and inactive registry rows are not.
update english.hindu_vocab_registry set marked=false,in_vocab=true where question_id='H001';
do $$ begin
  if not english.hindu_daily_eligible('00000000-0000-0000-0000-000000000001','H001') then
    raise exception 'in_vocab Hindu should be eligible';
  end if;
end $$;
update english.hindu_vocab_registry set active=false where question_id='H001';
do $$ begin
  if english.hindu_daily_eligible('00000000-0000-0000-0000-000000000001','H001') then
    raise exception 'inactive Hindu registry row should not be eligible';
  end if;
end $$;

select 'English Hindu proactive Daily eligibility contracts passed' result;
