\set ON_ERROR_STOP on
create schema if not exists english;

create table english.questions(question_id text primary key,active boolean,topic text,source_id text,source_file text,question_type text);
create table english.fast_track_failure_decision_intent(user_id uuid,question_id text);
create table english.sprint_bank_items(user_id uuid,source_session_id uuid,source_position integer);
create table english.user_question_revisions(proposal_id uuid,user_id uuid,question_id text,proposal_version integer);

create function english.canonical_category(text) returns text language sql immutable as $$ select $1 $$;
create function english.resolve_saved_type(text,text,text,text,text,text,text) returns text language sql immutable as $$ select $1 $$;
create function english.daily_reason_code(text) returns text language sql immutable as $$ select $1 $$;
create function english.daily_signal_codes(text,text,boolean,boolean,boolean,boolean) returns text[] language sql immutable as $$ select array[$1] $$;
create function english.recent_content_date(english.questions) returns date language sql immutable as $$ select null::date $$;
create function english.source_descriptor_key(english.questions) returns text language sql immutable as $$ select null::text $$;
create function english.phrasal_question_family(english.questions) returns text language sql immutable as $$ select 'recognition'::text $$;
create function english.daily_day_no(date) returns integer language sql immutable as $$ select 1 $$;
create function english.starred_selection_signals(text,boolean,boolean,boolean,integer) returns text[] language sql immutable as $$ select '{}'::text[] $$;
create function english.learning_category(text) returns text language sql immutable as $$ select $1 $$;
create function english.is_genuine_bank_question(english.questions) returns boolean language sql immutable as $$ select true $$;
create function english.daily_reason_base_score(text) returns integer language sql immutable as $$ select 0 $$;
create function english.daily_quota(text,integer) returns integer language sql immutable as $$ select 1 $$;
create function english.source_descriptor_name(english.questions) returns text language sql immutable as $$ select null::text $$;
create function english.daily_cap(text,integer) returns integer language sql immutable as $$ select 1 $$;
create function english.phrasal_selection_reason(text,boolean,boolean,boolean,boolean,boolean,boolean,integer,boolean,integer,text) returns text language sql immutable as $$ select $1 $$;
create function english.central_revision_signals(text,boolean,boolean,boolean,integer,timestamptz) returns text[] language sql stable as $$ select '{}'::text[] $$;

\ir ../../supabase/managed-migrations/20260905113000_english_helper_search_path_and_fk_indexes.sql

do $$
declare bad integer; begin
  select count(*) into bad
  from pg_proc p join pg_namespace n on n.oid=p.pronamespace
  where n.nspname='english'
    and p.proname in (
      'canonical_category','resolve_saved_type','daily_reason_code','daily_signal_codes','recent_content_date',
      'source_descriptor_key','phrasal_question_family','daily_day_no','starred_selection_signals','learning_category',
      'is_genuine_bank_question','daily_reason_base_score','daily_quota','source_descriptor_name','daily_cap',
      'phrasal_selection_reason','central_revision_signals'
    )
    and not coalesce(p.proconfig,'{}'::text[]) @> array['search_path=pg_catalog, english']::text[];
  if bad<>0 then raise exception '% English helper functions still have mutable search_path',bad; end if;

  if not exists(select 1 from pg_indexes where schemaname='english' and indexname='english_fast_track_failure_question_idx' and indexdef like '%(question_id)%') then
    raise exception 'fast-track question FK index missing';
  end if;
  if not exists(select 1 from pg_indexes where schemaname='english' and indexname='english_sprint_bank_source_item_idx' and indexdef like '%(source_session_id, source_position)%') then
    raise exception 'sprint-bank composite FK index missing';
  end if;
  if not exists(select 1 from pg_indexes where schemaname='english' and indexname='english_user_revisions_proposal_identity_idx' and indexdef like '%(proposal_id, user_id, question_id, proposal_version)%') then
    raise exception 'revision identity FK index missing';
  end if;
end $$;

select 'English Stage-2 DB hardening regression passed' result;
