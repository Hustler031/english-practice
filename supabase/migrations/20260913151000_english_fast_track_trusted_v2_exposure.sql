-- Fast Track must verify concepts the learner has actually encountered in the current V2 system.
-- Legacy imported attempts remain historical evidence, but cannot by themselves qualify a concept for Fast Track.

create index if not exists english_attempts_user_concept_idx
  on english.attempts(user_id, concept_id, attempted_at desc)
  where concept_id is not null;

create or replace function english.fast_track_has_trusted_v2_exposure(
  p_user_id uuid,
  p_question_id text
)
returns boolean
language sql
stable
security definer
set search_path = pg_catalog, english, auth
as $$
  select exists (
    select 1
    from english.attempts a
    where a.user_id = p_user_id
      and a.concept_id = english.focus_concept_key(p_question_id)
      and coalesce(a.submission_key, '') like 'v2-%'
      and lower(coalesce(a.module, '')) <> 'fasttrack'
  );
$$;

comment on function english.fast_track_has_trusted_v2_exposure(uuid,text) is
  'True only when the concept has a real V2 exposure outside Fast Track; legacy/imported attempts alone do not qualify.';

create or replace function english.enforce_fast_track_trusted_v2_exposure()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, english, auth
as $$
begin
  if new.route = 'fast_track'
     and not english.fast_track_has_trusted_v2_exposure(new.user_id, new.question_id) then
    new.route := 'unclassified';
    new.fast_track_status := null;
    new.entered_fast_track_at := null;
    new.next_fast_track_check := null;
    new.fast_track_mastered_at := null;
    new.pending_failure_decision := false;
    new.last_route_reason := 'Fast Track blocked — no trusted V2 concept exposure';
    new.updated_at := now();
  end if;
  return new;
end;
$$;

drop trigger if exists english_fast_track_trusted_v2_guard on english.learning_route_state;
create trigger english_fast_track_trusted_v2_guard
before insert or update of route, fast_track_status, question_id, user_id
on english.learning_route_state
for each row
execute function english.enforce_fast_track_trusted_v2_exposure();

-- Clean already-bootstrapped legacy-only Fast Track routes. This preserves attempts/history;
-- it only removes an invalid Fast Track classification so the concept can flow through normal CI again.
update english.learning_route_state r
set route = 'unclassified',
    fast_track_status = null,
    entered_fast_track_at = null,
    next_fast_track_check = null,
    fast_track_mastered_at = null,
    pending_failure_decision = false,
    last_route_reason = 'Fast Track blocked — no trusted V2 concept exposure',
    updated_at = now()
where r.route = 'fast_track'
  and not english.fast_track_has_trusted_v2_exposure(r.user_id, r.question_id);
