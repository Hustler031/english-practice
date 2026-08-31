-- Capture immutable pre-routing evidence so the historical bootstrap can be reconciled later.
-- This migration intentionally sorts before the route bootstrap migration.

create table if not exists english.learning_route_bootstrap_baseline (
  user_id uuid primary key references auth.users(id) on delete cascade,
  captured_at timestamptz not null default now(),
  attempts_count bigint not null,
  daily_rows bigint not null,
  star_events_count bigint not null,
  saved_rows bigint not null,
  question_state_rows bigint not null,
  active_questions bigint not null,
  active_question_ids bigint not null
);

alter table english.learning_route_bootstrap_baseline enable row level security;
revoke all on english.learning_route_bootstrap_baseline from public,anon,authenticated;
grant all on english.learning_route_bootstrap_baseline to service_role;

insert into english.learning_route_bootstrap_baseline(
  user_id,attempts_count,daily_rows,star_events_count,saved_rows,question_state_rows,active_questions,active_question_ids
)
select u.id,
  (select count(*) from english.attempts a where a.user_id=u.id),
  (select count(*) from english.daily_current d where d.user_id=u.id),
  (select count(*) from english.star_events s where s.user_id=u.id),
  (select count(*) from english.saved_items s where s.user_id=u.id),
  (select count(*) from english.question_state s where s.user_id=u.id),
  (select count(*) from english.questions q where q.active),
  (select count(distinct q.question_id) from english.questions q where q.active)
from auth.users u
on conflict(user_id) do nothing;
