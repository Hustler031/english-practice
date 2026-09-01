-- Final English concept UX/runtime corrections.
-- Keeps concept tables private; browser receives only sanitized RPC results.

create table if not exists english.learner_context_notes (
  note_id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  question_id text not null references english.questions(question_id) on delete restrict,
  attempt_id text references english.attempts(attempt_id) on delete set null,
  note text not null check (char_length(trim(note)) between 1 and 600),
  context_snapshot jsonb not null default '{}'::jsonb,
  processing_status text not null default 'queued' check (processing_status in ('queued','processing','done','failed')),
  diagnosis jsonb,
  created_at timestamptz not null default now(),
  processed_at timestamptz
);
create index if not exists english_context_notes_user_idx on english.learner_context_notes(user_id,created_at desc);
alter table english.learner_context_notes enable row level security;
drop policy if exists english_context_notes_owner on english.learner_context_notes;
create policy english_context_notes_owner on english.learner_context_notes for select to authenticated using ((select auth.uid())=user_id);

create or replace function public.english_save_context_note(
  p_question_id text,p_note text,p_attempt_id text default null,p_context_snapshot jsonb default '{}'
) returns jsonb
language plpgsql security definer set search_path=pg_catalog,public,english,auth as $$
declare uid uuid:=(select auth.uid()); nid uuid; cid text;
begin
 if uid is null then raise exception 'Authentication required'; end if;
 if not exists(select 1 from english.questions where question_id=p_question_id and active) then raise exception 'Question not found'; end if;
 if char_length(trim(coalesce(p_note,''))) not between 1 and 600 then raise exception 'Context note must be 1 to 600 characters'; end if;
 select m.concept_id into cid from english.question_concept_mappings m where m.question_id=p_question_id;
 insert into english.learner_context_notes(user_id,question_id,attempt_id,note,context_snapshot)
 values(uid,p_question_id,nullif(trim(coalesce(p_attempt_id,'')),''),trim(p_note),
   jsonb_strip_nulls(coalesce(p_context_snapshot,'{}'::jsonb)||jsonb_build_object('concept_id',cid,'saved_at',now())))
 returning note_id into nid;
 return jsonb_build_object('ok',true,'saved',true,'note_id',nid,'concept_id',cid,'processing','queued');
end $$;
revoke all on function public.english_save_context_note(text,text,text,jsonb) from public,anon;
grant execute on function public.english_save_context_note(text,text,text,jsonb) to authenticated,service_role;

-- The public wrappers are the only browser boundary. They must execute with
-- owner privileges and never expose the underlying concept tables directly.
create or replace function public.english_get_concept_intelligence_summary()
returns jsonb language sql stable security definer
set search_path=pg_catalog,public,english,auth as $$
select english.english_get_concept_intelligence_summary();
$$;
revoke all on function public.english_get_concept_intelligence_summary() from public,anon;
grant execute on function public.english_get_concept_intelligence_summary() to authenticated,service_role;

create or replace function public.english_get_concept_intelligence_detail(p_kind text default 'all')
returns jsonb language sql stable security definer
set search_path=pg_catalog,public,english,auth as $$
select english.english_get_concept_intelligence_detail(p_kind);
$$;
revoke all on function public.english_get_concept_intelligence_detail(text) from public,anon;
grant execute on function public.english_get_concept_intelligence_detail(text) to authenticated,service_role;
