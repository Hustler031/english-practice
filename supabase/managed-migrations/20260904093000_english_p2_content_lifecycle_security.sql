-- English V2 P2 audit hardening.
-- Scope: Fixed Preposition explanation backfill, quiz/Sprint lifecycle hygiene,
-- security/RLS tightening, and high-value FK indexes.

-- ================================================================
-- Fixed Preposition explanation backfill
-- ================================================================

create or replace function english.fixed_preposition_explanation(p_question text,p_answer text)
returns text
language plpgsql
immutable
set search_path to 'pg_catalog','english'
as $$
declare
  q text:=regexp_replace(btrim(coalesce(p_question,'')),'\s+',' ','g');
  ans text:=btrim(coalesce(p_answer,''));
  segs text[];
  parts text[];
  i int;
  left_part text;
  right_part text;
  left_words text[];
  right_words text[];
  left_tail text;
  right_head text;
  windows text[]:='{}'::text[];
  completed text;
begin
  if q='' or ans='' then return ''; end if;

  segs:=regexp_split_to_array(q,'\s*[_.…]{2,}\s*');
  parts:=regexp_split_to_array(ans,'\s*[,;]\s*');
  completed:=q;

  for i in 1..coalesce(array_length(parts,1),0) loop
    completed:=regexp_replace(completed,'\s*[_.…]{2,}\s*',' '||btrim(parts[i])||' ',1,1);
    left_part:=coalesce(segs[i],'');
    right_part:=coalesce(segs[i+1],'');
    left_words:=regexp_split_to_array(btrim(left_part),'\s+');
    right_words:=regexp_split_to_array(btrim(right_part),'\s+');
    left_tail:=btrim(concat_ws(' ',
      case when coalesce(array_length(left_words,1),0)>=2 then left_words[array_length(left_words,1)-1] end,
      case when coalesce(array_length(left_words,1),0)>=1 then left_words[array_length(left_words,1)] end
    ));
    right_head:=btrim(concat_ws(' ',
      case when coalesce(array_length(right_words,1),0)>=1 then right_words[1] end,
      case when coalesce(array_length(right_words,1),0)>=2 then right_words[2] end
    ));
    windows:=array_append(
      windows,
      regexp_replace(btrim(concat_ws(' ',nullif(left_tail,''),btrim(parts[i]),nullif(right_head,''))),'[.?!]+$','')
    );
  end loop;

  completed:=regexp_replace(completed,'\s+',' ','g');
  if coalesce(array_length(parts,1),0)=1 then
    return 'Use “'||btrim(parts[1])||'” in the required pattern “'||windows[1]||'”. Correct form: “'||btrim(completed)||'”';
  end if;

  return 'Use the required forms in sequence '
    ||array_to_string(array(select '“'||btrim(x)||'”' from unnest(parts) x),', ')
    ||'. Around the blanks, the tested patterns are '
    ||array_to_string(array(select '“'||x||'”' from unnest(windows) x),'; ')
    ||'. Correct form: “'||btrim(completed)||'”';
end $$;

-- Four no-preposition items need an explicit grammar reason rather than a generic completion.
update english.questions
set explanation='“Discuss” is transitive here and takes its object directly: use “discuss the ways”, not “discuss about/on/of the ways”.'
where question_id='FP0004' and btrim(coalesce(explanation,''))='';

update english.questions
set explanation='“Discuss” takes a direct object, so no preposition comes before “The Female Education in India”. Use “discuss the topic”, not “discuss about the topic”.'
where question_id='FP0180' and btrim(coalesce(explanation,''))='';

update english.questions
set explanation='“Home” functions adverbially after a verb of movement: say “go home”, not “go to home”.'
where question_id='FP0046' and btrim(coalesce(explanation,''))='';

update english.questions
set explanation='“Abroad” is an adverb of place, so it follows “went” directly: “went abroad”, with no preposition.'
where question_id='FP0229' and btrim(coalesce(explanation,''))='';

update english.questions q
set explanation=english.fixed_preposition_explanation(
  q.question,
  case upper(q.correct)
    when 'A' then q.option_a
    when 'B' then q.option_b
    when 'C' then q.option_c
    when 'D' then q.option_d
  end
)
where q.active
  and lower(coalesce(q.subtopic,''))='fixed preposition'
  and lower(coalesce(q.question_type,''))='fill in the blank'
  and btrim(coalesce(q.explanation,''))='';

do $$
begin
  if exists(
    select 1
    from english.questions q
    where q.active
      and lower(coalesce(q.subtopic,''))='fixed preposition'
      and lower(coalesce(q.question_type,''))='fill in the blank'
      and btrim(coalesce(q.explanation,''))=''
  ) then
    raise exception 'Fixed Preposition explanation backfill incomplete';
  end if;
end $$;

drop function english.fixed_preposition_explanation(text,text);

-- ================================================================
-- Quiz-session lifecycle hygiene
-- ================================================================

alter table english.quiz_sessions add column if not exists terminal_reason text;

update english.quiz_sessions
set terminal_reason=coalesce(terminal_reason,'completed')
where completed_at is not null;

update english.quiz_sessions
set completed_at=created_at+interval '24 hours',terminal_reason='expired'
where completed_at is null
  and created_at<now()-interval '24 hours';

create or replace function english.expire_stale_quiz_sessions_on_new()
returns trigger
language plpgsql
security definer
set search_path to 'pg_catalog','english'
as $$
begin
  update english.quiz_sessions
  set completed_at=created_at+interval '24 hours',terminal_reason='expired'
  where user_id=new.user_id
    and completed_at is null
    and created_at<now()-interval '24 hours';
  return new;
end $$;

drop trigger if exists quiz_sessions_expire_stale_before_insert on english.quiz_sessions;
create trigger quiz_sessions_expire_stale_before_insert
before insert on english.quiz_sessions
for each row execute function english.expire_stale_quiz_sessions_on_new();

-- ================================================================
-- Sprint generation lifecycle hygiene
-- ================================================================

alter table english.sprint_generation_jobs
  drop constraint if exists sprint_generation_jobs_status_check;

alter table english.sprint_generation_jobs
  add constraint sprint_generation_jobs_status_check
  check(status=any(array[
    'queued'::text,'generating'::text,'ready'::text,'failed'::text,'claimed'::text,
    'completed'::text,'abandoned'::text
  ]));

create or replace function english.sync_sprint_generation_terminal()
returns trigger
language plpgsql
security definer
set search_path to 'pg_catalog','english'
as $$
begin
  if new.status='completed' and old.status is distinct from new.status then
    update english.sprint_generation_jobs
    set status='completed',updated_at=now(),completed_at=coalesce(completed_at,now()),expires_at=now()
    where user_id=new.user_id and session_id=new.session_id and status='claimed';
  elsif new.status='abandoned' and old.status is distinct from new.status then
    update english.sprint_generation_jobs
    set status='abandoned',updated_at=now(),completed_at=coalesce(completed_at,now()),expires_at=now()
    where user_id=new.user_id and session_id=new.session_id and status='claimed';
  end if;
  return new;
end $$;

drop trigger if exists sprint_generation_terminal_sync on english.sprint_sessions;
create trigger sprint_generation_terminal_sync
after update of status on english.sprint_sessions
for each row execute function english.sync_sprint_generation_terminal();

-- Reconcile the two classes of already-terminal sessions without touching learner results.
update english.sprint_generation_jobs j
set status=case s.status when 'completed' then 'completed' when 'abandoned' then 'abandoned' else j.status end,
    updated_at=now(),
    completed_at=coalesce(j.completed_at,s.completed_at,now()),
    expires_at=now()
from english.sprint_sessions s
where j.session_id=s.session_id
  and j.user_id=s.user_id
  and j.status='claimed'
  and s.status in('completed','abandoned');

-- ================================================================
-- Security and RLS hardening
-- ================================================================

revoke execute on function public.english_get_today_extra_batch(integer) from public,anon;
revoke execute on function public.english_set_hindu_vocab(text,boolean) from public,anon;
grant execute on function public.english_get_today_extra_batch(integer) to authenticated;
grant execute on function public.english_set_hindu_vocab(text,boolean) to authenticated;

drop policy if exists quiz_sessions_select_own on english.quiz_sessions;
create policy quiz_sessions_select_own
on english.quiz_sessions for select
using ((select auth.uid())=user_id);

drop policy if exists quiz_session_exposures_select_own on english.quiz_session_exposures;
create policy quiz_session_exposures_select_own
on english.quiz_session_exposures for select
using ((select auth.uid())=user_id);

drop policy if exists sprint_ai_usage_select_own on english.sprint_ai_usage;
create policy sprint_ai_usage_select_own
on english.sprint_ai_usage for select
using (user_id=(select auth.uid()));

-- ================================================================
-- High-value FK/query indexes identified by the audit advisor
-- ================================================================

create index if not exists english_confusable_cluster_terms_concept_idx on english.confusable_cluster_terms(concept_id);
create index if not exists english_learner_confusions_primary_concept_idx on english.learner_confusions(primary_concept_id);
create index if not exists english_learner_confusions_related_concept_idx on english.learner_confusions(related_concept_id);
create index if not exists english_learner_confusions_primary_question_idx on english.learner_confusions(primary_question_id);
create index if not exists english_learner_confusions_related_question_idx on english.learner_confusions(related_question_id);
create index if not exists english_learner_confusions_source_note_idx on english.learner_confusions(source_note_id);
create index if not exists english_context_notes_attempt_idx on english.learner_context_notes(attempt_id);
create index if not exists english_context_notes_question_idx on english.learner_context_notes(question_id);
create index if not exists english_intelligence_activity_concept_idx on english.learning_intelligence_activity(concept_id);
create index if not exists english_intelligence_activity_question_idx on english.learning_intelligence_activity(question_id);
create index if not exists english_intelligence_activity_note_idx on english.learning_intelligence_activity(source_note_id);
create index if not exists english_route_events_question_idx on english.learning_route_events(question_id);
create index if not exists english_route_state_question_idx on english.learning_route_state(question_id);
create index if not exists english_question_distractor_question_idx on english.question_distractor_metrics(question_id);
create index if not exists english_generation_provenance_concept_idx on english.question_generation_provenance(concept_id);
create index if not exists english_generation_provenance_owner_idx on english.question_generation_provenance(owner_user_id);
create index if not exists english_generation_provenance_source_question_idx on english.question_generation_provenance(source_question_id);
create index if not exists english_quality_metrics_question_idx on english.question_quality_metrics(question_id);
create index if not exists english_quality_reviews_question_idx on english.question_quality_reviews(question_id);
create index if not exists english_revision_proposals_question_idx on english.question_revision_proposals(question_id);
create index if not exists english_quiz_exposures_session_idx on english.quiz_session_exposures(session_id);
create index if not exists english_sprint_ai_usage_session_idx on english.sprint_ai_usage(session_id);
create index if not exists english_sprint_bank_question_idx on english.sprint_bank_items(question_id);
create index if not exists english_sprint_bank_source_session_idx on english.sprint_bank_items(source_session_id);
create index if not exists english_sprint_generation_session_idx on english.sprint_generation_jobs(session_id);
create index if not exists english_transfer_jobs_concept_idx on english.targeted_transfer_jobs(concept_id);
create index if not exists english_transfer_jobs_generated_question_idx on english.targeted_transfer_jobs(generated_question_id);
create index if not exists english_transfer_jobs_source_note_idx on english.targeted_transfer_jobs(source_note_id);
create index if not exists english_transfer_jobs_source_question_idx on english.targeted_transfer_jobs(source_question_id);
create index if not exists english_user_revisions_question_idx on english.user_question_revisions(question_id);
