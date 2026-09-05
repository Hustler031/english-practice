\set ON_ERROR_STOP on
create schema if not exists english;
do $$ begin
  if not exists(select 1 from pg_roles where rolname='anon') then create role anon nologin; end if;
  if not exists(select 1 from pg_roles where rolname='authenticated') then create role authenticated nologin; end if;
  if not exists(select 1 from pg_roles where rolname='service_role') then create role service_role nologin; end if;
end $$;

create function english.context_claim(text,integer) returns jsonb language sql as $$ select '{}'::jsonb $$;
create function english.apply_context_ai_diagnosis(text,uuid,jsonb,text,jsonb) returns void language sql as $$ select $$;
create function english.fail_context_ai(text,uuid,text) returns void language sql as $$ select $$;
create function english.transfer_claim(text,integer) returns jsonb language sql as $$ select '{}'::jsonb $$;
create function english.apply_generated_transfer(text,uuid,jsonb,text,jsonb) returns void language sql as $$ select $$;
create function english.fail_transfer_generation(text,uuid,text) returns void language sql as $$ select $$;
create function english.question_quality_review_claim(text,integer) returns jsonb language sql as $$ select '{}'::jsonb $$;
create function english.apply_question_quality_review_result(text,uuid,jsonb,text,jsonb) returns void language sql as $$ select $$;
create function english.reconcile_context_worker_http() returns void language sql as $$ select $$;
create function english.worker_lane_allowed(text) returns boolean language sql as $$ select true $$;

\ir ../../supabase/managed-migrations/20260905114000_english_inner_worker_acl_hardening.sql

do $$
declare r record; begin
  for r in select * from (values
    ('english.context_claim(text,integer)'),
    ('english.apply_context_ai_diagnosis(text,uuid,jsonb,text,jsonb)'),
    ('english.fail_context_ai(text,uuid,text)'),
    ('english.transfer_claim(text,integer)'),
    ('english.apply_generated_transfer(text,uuid,jsonb,text,jsonb)'),
    ('english.fail_transfer_generation(text,uuid,text)'),
    ('english.question_quality_review_claim(text,integer)'),
    ('english.apply_question_quality_review_result(text,uuid,jsonb,text,jsonb)'),
    ('english.reconcile_context_worker_http()'),
    ('english.worker_lane_allowed(text)')
  ) v(sig) loop
    if has_function_privilege('anon',r.sig,'EXECUTE') then raise exception 'anon can execute %',r.sig; end if;
    if has_function_privilege('authenticated',r.sig,'EXECUTE') then raise exception 'authenticated can execute %',r.sig; end if;
    if not has_function_privilege('service_role',r.sig,'EXECUTE') then raise exception 'service_role cannot execute %',r.sig; end if;
  end loop;
end $$;

select 'English Stage-2 inner worker ACL regression passed' result;
