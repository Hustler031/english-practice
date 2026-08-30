create table if not exists maths.exposures (
  exposure_id text primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  question_id text not null references maths.questions(question_id) on delete restrict,
  seen_at timestamptz not null,
  mode text,
  session_id text,
  source_attempt_id text,
  migration_run_id text not null references maths.migration_runs(migration_run_id) on delete restrict,
  source_row jsonb not null
);
alter table maths.exposures enable row level security;
drop policy if exists maths_exposures_own on maths.exposures;
create policy maths_exposures_own on maths.exposures for all to authenticated using (user_id=auth.uid()) with check (user_id=auth.uid());

insert into maths.exposures(exposure_id,user_id,question_id,seen_at,mode,session_id,source_attempt_id,migration_run_id,source_row)
select coalesce(nullif(h.source_attempt_id,''),h.evidence_key),h.user_id,h.question_id,
       coalesce(h.attempted_at,now()),h.mode,h.session_id,h.source_attempt_id,h.migration_run_id,h.source_row
from maths.historical_attempt_evidence h
join maths.questions q on q.question_id=h.question_id
where lower(coalesce(h.result,''))='seen'
on conflict (exposure_id) do nothing;


