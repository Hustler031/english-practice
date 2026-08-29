create extension if not exists pgcrypto;

-- ENGLISH
create table if not exists english.questions (
  question_id text primary key,
  topic text, word text, question text not null,
  option_a text, option_b text, option_c text, option_d text,
  correct text, explanation text, subtopic text, question_type text,
  source_file text, source_page text, concept_id text, difficulty text, source_id text,
  learning_status text, content_status text,
  first_seen_date timestamptz, last_seen_date timestamptz, seen_count integer,
  duplicate_group_id text, exam_relevance text, tip text, usage_note text,
  example_sentence text, memory_aid text, related_words text, source_url text,
  review_notes text, active boolean not null default true,
  created_at timestamptz not null default now(), updated_at timestamptz not null default now()
);
create index if not exists english_questions_topic_idx on english.questions(topic);
create index if not exists english_questions_concept_idx on english.questions(concept_id);
create index if not exists english_questions_learning_idx on english.questions(learning_status) where active;
create index if not exists english_questions_source_idx on english.questions(source_id);

create table if not exists english.question_state (
  user_id uuid not null references auth.users(id) on delete cascade,
  question_id text not null references english.questions(question_id) on delete cascade,
  attempts integer not null default 0, correct integer not null default 0, wrong integer not null default 0,
  accuracy numeric(7,4), marked_count integer not null default 0, avg_time numeric,
  last_attempt timestamptz, last_result boolean, last_time numeric, last_marked boolean,
  correct_streak integer not null default 0, status text, next_review timestamptz,
  mastered boolean not null default false, mastered_on timestamptz,
  repeat_suppressed_until timestamptz, recall_check_count integer not null default 0,
  updated_at timestamptz not null default now(),
  primary key(user_id,question_id)
);
create index if not exists english_state_due_idx on english.question_state(user_id,next_review) where not mastered;

create table if not exists english.attempts (
  attempt_id text primary key, user_id uuid not null references auth.users(id) on delete cascade,
  question_id text not null references english.questions(question_id) on delete restrict,
  attempted_at timestamptz not null, selected_answer text, correct boolean,
  time_seconds numeric, marked_revision boolean, topic text, concept_id text, module text,
  submission_key text unique, created_at timestamptz not null default now()
);
create index if not exists english_attempts_user_time_idx on english.attempts(user_id,attempted_at desc);
create index if not exists english_attempts_question_idx on english.attempts(user_id,question_id,attempted_at desc);

create table if not exists english.daily_history (
  id bigint generated always as identity primary key, user_id uuid not null references auth.users(id) on delete cascade,
  quiz_date date, day_no integer, question_id text not null references english.questions(question_id) on delete restrict,
  priority integer, reason text, status text, topic text, concept_id text, archived_at timestamptz,
  unique(user_id,quiz_date,question_id)
);

create table if not exists english.saved_items (
  saved_id text primary key, user_id uuid not null references auth.users(id) on delete cascade,
  word text, meaning text, context text, origin_question_id text, origin_module text, source text,
  created_at timestamptz, updated_at timestamptz, status text, practice_question_id text,
  active boolean not null default true, part_of_speech text, synonyms text, antonyms text,
  example text, explanation text, question text, option_a text, option_b text, option_c text, option_d text,
  correct_option text, gpt_status text, gpt_updated_at timestamptz, gpt_source text
);
create index if not exists english_saved_user_active_idx on english.saved_items(user_id,active);

create table if not exists english.sources (
  source_id text primary key, source_type text, source_name text, source_file text, source_date date,
  active boolean not null default true, imported_on timestamptz, question_count integer, source_ref text,
  notes text, import_status text, new_count integer, recall_count integer, duplicate_count integer,
  category_summary text, processed_on timestamptz
);

create table if not exists english.practice_sets (
  set_id text primary key, name text not null, description text, active boolean not null default true,
  created_at timestamptz not null default now()
);
create table if not exists english.practice_set_items (
  set_id text not null references english.practice_sets(set_id) on delete cascade,
  question_id text not null references english.questions(question_id) on delete cascade,
  sequence integer not null,
  primary key(set_id,question_id), unique(set_id,sequence)
);

-- GK
create table if not exists gk.questions (
  question_id text primary key, content_type text, lecture_no integer, source_label text, source_date date,
  subject text, topic text, concept_id text, source_page text, question text not null,
  option_a text, option_b text, option_c text, option_d text, correct_option text,
  explanation text, trick text, related_fact text, exam_trap text, difficulty text, status text,
  created_at timestamptz, active boolean not null default true
);
create index if not exists gk_questions_subject_topic_idx on gk.questions(subject,topic);
create index if not exists gk_questions_concept_idx on gk.questions(concept_id);
create index if not exists gk_questions_lecture_idx on gk.questions(lecture_no);

create table if not exists gk.question_state (
  user_id uuid not null references auth.users(id) on delete cascade,
  question_id text not null references gk.questions(question_id) on delete cascade,
  attempts integer not null default 0, correct integer not null default 0, wrong integer not null default 0,
  streak integer not null default 0, accuracy numeric, mastery_score numeric, last_attempt timestamptz,
  next_review timestamptz, marked_review boolean not null default false, learning_status text,
  last_selected text, last_correct boolean, difficult boolean not null default false, starred_at timestamptz,
  first_attempt_correct boolean, retention_attempts integer not null default 0,
  retention_correct integer not null default 0, retention_wrong integer not null default 0,
  last_spaced_attempt timestamptz, exposure_count integer not null default 0,
  first_seen timestamptz, last_seen timestamptz, guessed_attempts integer not null default 0,
  unconfirmed_guess boolean not null default false, last_guess_at timestamptz,
  confirmed_unguessed_spaced_recalls integer not null default 0, last_meaningful_result text,
  latest_result text, flag_active boolean not null default false, flag_reason text, flag_note text,
  flag_updated_at timestamptz, learning_updated_at timestamptz,
  primary key(user_id,question_id)
);
create index if not exists gk_state_due_idx on gk.question_state(user_id,next_review);

create table if not exists gk.attempts (
  attempt_id text primary key, user_id uuid not null references auth.users(id) on delete cascade,
  attempted_at timestamptz not null, question_id text not null references gk.questions(question_id) on delete restrict,
  selected_option text, is_correct boolean, marked_review boolean, mode text, session_id text,
  response_ms integer, submission_key text unique, study_day integer, learning_state text,
  guessed boolean, guessed_at timestamptz, attempt_kind text, canonical_selected_option text,
  display_selected_option text, is_spaced boolean, gap_hours numeric, confidence_confirmed boolean
);
create index if not exists gk_attempts_user_time_idx on gk.attempts(user_id,attempted_at desc);

create table if not exists gk.sessions (
  session_id text primary key, user_id uuid not null references auth.users(id) on delete cascade,
  mode text, params jsonb, current_index integer not null default 0, updated_at timestamptz,
  completed boolean not null default false, title text, study_day integer, composition jsonb,
  option_orders jsonb, answers jsonb, position_index integer, paused_at timestamptz,
  session_version text, result jsonb, created_at timestamptz not null default now()
);
create table if not exists gk.session_questions (
  session_id text not null references gk.sessions(session_id) on delete cascade,
  question_id text not null references gk.questions(question_id) on delete restrict,
  position integer not null,
  primary key(session_id,question_id), unique(session_id,position)
);

create table if not exists gk.exposures (
  exposure_id text primary key, user_id uuid not null references auth.users(id) on delete cascade,
  exposed_at timestamptz not null, question_id text not null references gk.questions(question_id) on delete restrict,
  session_id text, mode text, study_day integer, exposure_key text unique
);
create table if not exists gk.lectures (
  lecture_no integer primary key, content_type text, title text, date_added date, source_file_name text,
  total_pages integer, facts_count integer, questions_count integer, status text
);
create table if not exists gk.user_notes (
  user_id uuid not null references auth.users(id) on delete cascade,
  question_id text not null references gk.questions(question_id) on delete cascade,
  note text, updated_at timestamptz not null default now(), primary key(user_id,question_id)
);
create table if not exists gk.flags (
  flag_id text primary key, user_id uuid not null references auth.users(id) on delete cascade,
  question_id text not null references gk.questions(question_id) on delete cascade,
  reason text, note text, created_at timestamptz, resolved boolean not null default false,
  resolved_at timestamptz, updated_at timestamptz
);

-- MATHS
create table if not exists maths.questions (
  question_id text primary key, chapter text, topic text, subtopic text, card_type text,
  prompt text not null, answer text, explanation text, memory_cue text, difficulty text,
  marked_default boolean not null default false, mastered_default boolean not null default false,
  diagram_type text, diagram_json jsonb, source_file text, source_page text, source_url text,
  status text, answer_mode text, option_a text, option_b text, option_c text, option_d text,
  correct_option text, template_group text, variant_types text, rotation_tier text,
  practice_bank text, added_at timestamptz, generated boolean not null default false
);
create index if not exists maths_questions_chapter_topic_idx on maths.questions(chapter,topic,subtopic);
create index if not exists maths_questions_bank_idx on maths.questions(practice_bank);

create table if not exists maths.question_state (
  user_id uuid not null references auth.users(id) on delete cascade,
  question_id text not null references maths.questions(question_id) on delete cascade,
  attempts integer not null default 0, mastered boolean not null default false,
  marked boolean not null default false, last_attempt timestamptz, last_result text,
  last_response_sec numeric, chapter text, topic text, subtopic text, last_variant text,
  last_correct_option text, difficult boolean not null default false,
  primary key(user_id,question_id)
);

create table if not exists maths.attempts (
  attempt_id text primary key, user_id uuid not null references auth.users(id) on delete cascade,
  attempted_at timestamptz not null, question_id text not null references maths.questions(question_id) on delete restrict,
  result text, response_sec numeric, mode text, session_id text, mastered_after boolean,
  marked_after boolean, variant_type text, selected_option text, question_index integer,
  client_attempt_key text unique
);
create index if not exists maths_attempts_user_time_idx on maths.attempts(user_id,attempted_at desc);

create table if not exists maths.sessions (
  session_id text primary key, user_id uuid not null references auth.users(id) on delete cascade,
  mode text, title text, current_index integer not null default 0, updated_at timestamptz,
  completed boolean not null default false, params jsonb, rendered_questions jsonb,
  created_at timestamptz not null default now()
);
create table if not exists maths.session_questions (
  session_id text not null references maths.sessions(session_id) on delete cascade,
  question_id text not null references maths.questions(question_id) on delete restrict,
  position integer not null, primary key(session_id,question_id), unique(session_id,position)
);

create table if not exists maths.concept_membership (
  question_id text primary key references maths.questions(question_id) on delete cascade,
  added_at timestamptz, study_day integer, chapter text, topic text, session_id text, active boolean not null default true
);
create table if not exists maths.practice_sets (
  set_id text primary key, set_name text not null, description text, status text,
  created_at timestamptz not null default now()
);
create table if not exists maths.practice_set_items (
  set_id text not null references maths.practice_sets(set_id) on delete cascade,
  question_id text not null references maths.questions(question_id) on delete cascade,
  sequence integer not null, primary key(set_id,question_id), unique(set_id,sequence)
);
create table if not exists maths.star_events (
  id bigint generated always as identity primary key, user_id uuid not null references auth.users(id) on delete cascade,
  question_id text not null references maths.questions(question_id) on delete cascade,
  event_at timestamptz not null, study_day integer, chapter text, type text, action text, session_id text
);

-- Keep internal schemas private by default.
revoke all on schema english from anon, authenticated;
revoke all on schema gk from anon, authenticated;
revoke all on schema maths from anon, authenticated;
revoke all on all tables in schema english from anon, authenticated;
revoke all on all tables in schema gk from anon, authenticated;
revoke all on all tables in schema maths from anon, authenticated;