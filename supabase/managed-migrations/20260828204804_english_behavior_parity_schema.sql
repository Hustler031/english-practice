create table if not exists english.saved_item_types (
  user_id uuid not null references auth.users(id) on delete cascade,
  saved_id text not null references english.saved_items(saved_id) on delete cascade,
  capture_type text not null check (capture_type in ('AUTO','V','SM','OWS','PV','IP','CU')),
  resolved_type text not null check (resolved_type in ('V','SM','OWS','PV','IP','CU')),
  updated_at timestamptz,
  primary key (user_id, saved_id)
);

create table if not exists english.star_events (
  id bigint generated always as identity primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  question_id text not null references english.questions(question_id) on delete restrict,
  event_at timestamptz not null,
  starred_date date,
  day_no integer,
  action text not null check (action in ('STAR','UNSTAR')),
  source_row integer,
  unique (user_id, question_id, event_at, action)
);
create index if not exists english_star_events_current_idx on english.star_events(user_id, question_id, event_at desc);

create table if not exists english.difficult_state (
  user_id uuid not null references auth.users(id) on delete cascade,
  question_id text not null references english.questions(question_id) on delete restrict,
  difficult boolean not null default false,
  updated_at timestamptz,
  primary key (user_id, question_id)
);

create table if not exists english.mastery_events (
  id bigint generated always as identity primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  question_id text not null references english.questions(question_id) on delete restrict,
  mastered_on timestamptz,
  reason text,
  previous_status text,
  source text,
  category text,
  restored_on timestamptz,
  active boolean not null default true,
  source_row integer,
  unique (user_id, source_row)
);
create index if not exists english_mastery_events_current_idx on english.mastery_events(user_id, question_id, mastered_on desc, id desc);

create table if not exists english.daily_current (
  user_id uuid not null references auth.users(id) on delete cascade,
  question_id text not null references english.questions(question_id) on delete restrict,
  sequence integer not null,
  priority integer,
  reason text,
  quiz_date date not null,
  status text,
  topic text,
  concept_id text,
  primary key (user_id, question_id),
  unique (user_id, sequence)
);
create index if not exists english_daily_current_date_idx on english.daily_current(user_id, quiz_date, sequence);

create table if not exists english.hindu_words (
  hindu_id text primary key,
  word_date date,
  word text not null,
  part_of_speech text,
  meaning text,
  synonyms text,
  antonyms text,
  example_sentence text,
  word_family text,
  usage_note text,
  tip text,
  memory_aid text,
  article_title text,
  source_url text,
  source_name text,
  learning_status text,
  content_status text,
  first_practiced timestamptz,
  last_practiced timestamptz,
  active boolean not null default true
);

create table if not exists english.recall_checks (
  recall_id text primary key,
  existing_question_id text references english.questions(question_id) on delete set null,
  item_key text,
  category text,
  source_id text,
  source_name text,
  detected_on timestamptz,
  match_type text,
  existing_status text,
  times_seen integer,
  recall_result text,
  recall_on timestamptz,
  notes text,
  active boolean not null default true
);

alter table english.saved_item_types enable row level security;
alter table english.star_events enable row level security;
alter table english.difficult_state enable row level security;
alter table english.mastery_events enable row level security;
alter table english.daily_current enable row level security;
alter table english.hindu_words enable row level security;
alter table english.recall_checks enable row level security;

create policy english_saved_item_types_own on english.saved_item_types for all to authenticated using (auth.uid() = user_id) with check (auth.uid() = user_id);
create policy english_star_events_own on english.star_events for all to authenticated using (auth.uid() = user_id) with check (auth.uid() = user_id);
create policy english_difficult_state_own on english.difficult_state for all to authenticated using (auth.uid() = user_id) with check (auth.uid() = user_id);
create policy english_mastery_events_own on english.mastery_events for all to authenticated using (auth.uid() = user_id) with check (auth.uid() = user_id);
create policy english_daily_current_own on english.daily_current for all to authenticated using (auth.uid() = user_id) with check (auth.uid() = user_id);
create policy english_hindu_words_authenticated_read on english.hindu_words for select to authenticated using (true);
create policy english_recall_checks_authenticated_read on english.recall_checks for select to authenticated using (true);
