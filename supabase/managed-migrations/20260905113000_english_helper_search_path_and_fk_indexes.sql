-- Stage 2 release hardening.
-- Behavior-neutral security hardening for the exact English helper functions flagged by
-- the Supabase linter, plus covering indexes for the four remaining English FK advisories.

alter function english.canonical_category(text) set search_path = pg_catalog, english;
alter function english.resolve_saved_type(text,text,text,text,text,text,text) set search_path = pg_catalog, english;
alter function english.daily_reason_code(text) set search_path = pg_catalog, english;
alter function english.daily_signal_codes(text,text,boolean,boolean,boolean,boolean) set search_path = pg_catalog, english;
alter function english.recent_content_date(english.questions) set search_path = pg_catalog, english;
alter function english.source_descriptor_key(english.questions) set search_path = pg_catalog, english;
alter function english.phrasal_question_family(english.questions) set search_path = pg_catalog, english;
alter function english.daily_day_no(date) set search_path = pg_catalog, english;
alter function english.starred_selection_signals(text,boolean,boolean,boolean,integer) set search_path = pg_catalog, english;
alter function english.learning_category(text) set search_path = pg_catalog, english;
alter function english.is_genuine_bank_question(english.questions) set search_path = pg_catalog, english;
alter function english.daily_reason_base_score(text) set search_path = pg_catalog, english;
alter function english.daily_quota(text,integer) set search_path = pg_catalog, english;
alter function english.source_descriptor_name(english.questions) set search_path = pg_catalog, english;
alter function english.daily_cap(text,integer) set search_path = pg_catalog, english;
alter function english.phrasal_selection_reason(text,boolean,boolean,boolean,boolean,boolean,boolean,integer,boolean,integer,text) set search_path = pg_catalog, english;
alter function english.central_revision_signals(text,boolean,boolean,boolean,integer,timestamptz) set search_path = pg_catalog, english;

create index if not exists english_fast_track_failure_question_idx
  on english.fast_track_failure_decision_intent(question_id);

create index if not exists english_sprint_bank_source_item_idx
  on english.sprint_bank_items(source_session_id, source_position);

-- proposal_id is the leading column so this one index covers both the single-column
-- proposal FK and the composite proposal/user/question/version identity FK.
create index if not exists english_user_revisions_proposal_identity_idx
  on english.user_question_revisions(proposal_id, user_id, question_id, proposal_version);
