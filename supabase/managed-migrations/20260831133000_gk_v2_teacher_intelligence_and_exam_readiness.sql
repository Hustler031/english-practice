-- GK V2 teacher provenance, canonical source membership, learning-support and exam-readiness layer.
-- Forward-only: preserves existing canonical questions and all historical Attempts / Exposures / Sessions.

begin;

create or replace function gk.canonical_subject(p_subject text)
returns text
language sql
immutable
set search_path = pg_catalog, gk
as $$
  select case lower(btrim(coalesce(p_subject,'')))
    when 'art and culture' then 'Art & Culture'
    when 'art & culture' then 'Art & Culture'
    when 'economy' then 'Economics'
    when 'economics' then 'Economics'
    else nullif(btrim(coalesce(p_subject,'')),'')
  end;
$$;

create or replace function gk.question_fingerprint(p_question text, p_options text[])
returns text
language sql
immutable
set search_path = pg_catalog, gk
as $$
  select md5(
    regexp_replace(lower(btrim(coalesce(p_question,''))), '[[:space:]]+', ' ', 'g') || '|' ||
    coalesce((
      select string_agg(v, '|' order by v)
      from (
        select regexp_replace(lower(btrim(coalesce(x,''))), '[[:space:]]+', ' ', 'g') v
        from unnest(coalesce(p_options,array[]::text[])) x
        where nullif(btrim(coalesce(x,'')),'') is not null
      ) s
    ),'')
  );
$$;

alter table gk.questions add column if not exists canonical_fingerprint text;
update gk.questions q
set canonical_fingerprint = gk.question_fingerprint(q.question,array[q.option_a,q.option_b,q.option_c,q.option_d])
where q.canonical_fingerprint is null;
create index if not exists gk_questions_canonical_fingerprint_idx on gk.questions(canonical_fingerprint) where active;

create table if not exists gk.content_series(
  series_id text primary key,
  series_kind text not null check (series_kind in ('TOPIC_PYQ','MIXED_PYQ','CURRENT_AFFAIRS','GPT_BOOSTER','LEGACY','OTHER')),
  title text not null,
  teacher_source text,
  subject text,
  active boolean not null default true,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists gk.question_source_memberships(
  membership_key text primary key,
  question_id text not null references gk.questions(question_id) on delete restrict,
  series_id text not null references gk.content_series(series_id) on delete restrict,
  lecture_key text,
  lecture_no integer,
  source_identity text not null,
  source_file text,
  source_page text,
  source_label text,
  source_date date,
  membership_kind text not null default 'TEACHER_SOURCE' check (membership_kind in ('TEACHER_SOURCE','TEACHER_REPEAT','LEGACY_SOURCE','GPT_BOOSTER')),
  evidence jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);
create index if not exists gk_qsm_question_idx on gk.question_source_memberships(question_id);
create index if not exists gk_qsm_series_lecture_idx on gk.question_source_memberships(series_id,lecture_key);
create unique index if not exists gk_qsm_identity_uq on gk.question_source_memberships(question_id,series_id,source_identity);

insert into gk.content_series(series_id,series_kind,title,teacher_source,metadata)
values
 ('TEACHER_TOPIC_PYQ','TOPIC_PYQ','Topic-wise PYQ Series','Teacher PDF',jsonb_build_object('library_key','subject-pyq')),
 ('TEACHER_MIXED_PYQ','MIXED_PYQ','Mixed PYQ Series','Teacher PDF',jsonb_build_object('library_key','mixed')),
 ('TEACHER_CURRENT_AFFAIRS','CURRENT_AFFAIRS','Teacher Current Affairs','Teacher PDF',jsonb_build_object('library_key','nitto')),
 ('LEGACY_GK','LEGACY','Legacy GK Library','Migrated GK source',jsonb_build_object('library_key','misc')),
 ('GPT_BOOSTER','GPT_BOOSTER','GPT Booster','GPT learning support',jsonb_build_object('content_authority','support_only'))
on conflict(series_id) do update set
 series_kind=excluded.series_kind,title=excluded.title,teacher_source=excluded.teacher_source,
 metadata=gk.content_series.metadata||excluded.metadata,updated_at=now();

insert into gk.question_source_memberships(
 membership_key,question_id,series_id,lecture_key,lecture_no,source_identity,source_file,source_page,source_label,source_date,membership_kind,evidence
)
select md5(q.question_id||'|'||s.series_id||'|'||coalesce(q.lecture_key,'')||'|'||coalesce(q.source_label,'')),
 q.question_id,s.series_id,q.lecture_key,q.lecture_no,
 coalesce(nullif(q.lecture_key,''),s.series_id||':'||q.question_id),
 coalesce(q.source_payload->>'Source_File',q.source_payload->>'source_file',q.source_payload->>'File_Name'),
 q.source_page,q.source_label,q.source_date,
 case when s.series_id='LEGACY_GK' then 'LEGACY_SOURCE' else 'TEACHER_SOURCE' end,
 jsonb_build_object('backfilled_from','gk.questions','source_row_number',q.source_row_number)
from gk.questions q
cross join lateral (
 select case gk.derive_library_key(q.question_id,q.source_label,q.subject)
   when 'subject-pyq' then 'TEACHER_TOPIC_PYQ'
   when 'mixed' then 'TEACHER_MIXED_PYQ'
   when 'nitto' then 'TEACHER_CURRENT_AFFAIRS'
   else 'LEGACY_GK' end series_id
) s
where q.active
on conflict(membership_key) do nothing;

create table if not exists gk.question_enrichments(
  question_id text primary key references gk.questions(question_id) on delete restrict,
  verified_explanation text,
  exam_trap text,
  memory_tip text,
  confusion_contrast text,
  related_recall jsonb not null default '[]'::jsonb,
  verification_status text not null default 'UNVERIFIED' check (verification_status in ('UNVERIFIED','VERIFIED','NEEDS_REVIEW','OUTDATED')),
  verification_source text,
  last_verified_at timestamptz,
  provenance text not null default 'GPT_ENRICHMENT' check (provenance in ('GPT_ENRICHMENT','MAINTAINER','TEACHER_SUPPLEMENT')),
  model_note text,
  updated_at timestamptz not null default now()
);

create table if not exists gk.concept_confusions(
  confusion_id text primary key,
  subject text,
  concept_a text not null,
  concept_b text not null,
  label text,
  evidence_count integer not null default 0,
  source_kind text not null default 'LEARNER_EVIDENCE' check (source_kind in ('LEARNER_EVIDENCE','TEACHER_VERIFIED','MAINTAINER_VERIFIED')),
  verification_status text not null default 'NEEDS_REVIEW' check (verification_status in ('VERIFIED','NEEDS_REVIEW')),
  active boolean not null default true,
  updated_at timestamptz not null default now(),
  check (concept_a<>concept_b)
);
create index if not exists gk_concept_confusions_a_idx on gk.concept_confusions(concept_a) where active;
create index if not exists gk_concept_confusions_b_idx on gk.concept_confusions(concept_b) where active;

create table if not exists gk.canonical_duplicate_review(
  review_key text primary key,
  canonical_fingerprint text not null,
  canonical_question_id text references gk.questions(question_id) on delete restrict,
  candidate_question_id text not null references gk.questions(question_id) on delete restrict,
  review_status text not null default 'NEEDS_REVIEW' check (review_status in ('NEEDS_REVIEW','SAME_PYQ','DISTINCT','DEFERRED')),
  reason text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (canonical_question_id is null or canonical_question_id<>candidate_question_id)
);

-- Candidate generation is deliberately conservative: fingerprint includes sorted option text,
-- so generic stems such as "Which statement is correct?" are not treated as duplicates by stem alone.
insert into gk.canonical_duplicate_review(review_key,canonical_fingerprint,canonical_question_id,candidate_question_id,reason)
select md5(d.fingerprint||'|'||d.canonical_id||'|'||d.candidate_id),d.fingerprint,d.canonical_id,d.candidate_id,
       'Exact normalized stem + option-set match; review before canonicalisation'
from (
  select canonical_fingerprint fingerprint,
         min(question_id) over(partition by canonical_fingerprint) canonical_id,
         question_id candidate_id,
         count(*) over(partition by canonical_fingerprint) n
  from gk.questions
  where active and canonical_fingerprint is not null
) d
where d.n>1 and d.candidate_id<>d.canonical_id
on conflict(review_key) do nothing;

create table if not exists gk.exam_sessions(
  session_id text primary key,
  user_id uuid not null,
  mode text not null default 'SECTION_SPRINT',
  question_ids jsonb not null default '[]'::jsonb,
  started_at timestamptz not null default now(),
  duration_seconds integer not null default 900 check(duration_seconds between 60 and 7200),
  completed boolean not null default false,
  completed_at timestamptz,
  result jsonb,
  created_at timestamptz not null default now()
);
create index if not exists gk_exam_sessions_user_time_idx on gk.exam_sessions(user_id,started_at desc);

create table if not exists gk.exam_answers(
  session_id text not null references gk.exam_sessions(session_id) on delete cascade,
  question_id text not null references gk.questions(question_id) on delete restrict,
  selected_option text,
  is_correct boolean,
  response_ms integer,
  answered_at timestamptz not null default now(),
  primary key(session_id,question_id)
);

alter table gk.content_series enable row level security;
alter table gk.question_source_memberships enable row level security;
alter table gk.question_enrichments enable row level security;
alter table gk.concept_confusions enable row level security;
alter table gk.canonical_duplicate_review enable row level security;
alter table gk.exam_sessions enable row level security;
alter table gk.exam_answers enable row level security;

drop policy if exists gk_content_series_authenticated_read on gk.content_series;
create policy gk_content_series_authenticated_read on gk.content_series for select to authenticated using (auth.uid() is not null);
drop policy if exists gk_qsm_authenticated_read on gk.question_source_memberships;
create policy gk_qsm_authenticated_read on gk.question_source_memberships for select to authenticated using (auth.uid() is not null);
drop policy if exists gk_enrichment_authenticated_read on gk.question_enrichments;
create policy gk_enrichment_authenticated_read on gk.question_enrichments for select to authenticated using (auth.uid() is not null);
drop policy if exists gk_confusions_authenticated_read on gk.concept_confusions;
create policy gk_confusions_authenticated_read on gk.concept_confusions for select to authenticated using (auth.uid() is not null);
-- Duplicate-review rows are maintainer-only: no authenticated SELECT policy.
drop policy if exists gk_exam_sessions_owner on gk.exam_sessions;
create policy gk_exam_sessions_owner on gk.exam_sessions for select to authenticated using (user_id=(select auth.uid()));
drop policy if exists gk_exam_answers_owner on gk.exam_answers;
create policy gk_exam_answers_owner on gk.exam_answers for select to authenticated using (exists(select 1 from gk.exam_sessions s where s.session_id=exam_answers.session_id and s.user_id=(select auth.uid())));

revoke all on gk.content_series,gk.question_source_memberships,gk.question_enrichments,gk.concept_confusions,gk.canonical_duplicate_review,gk.exam_sessions,gk.exam_answers from anon,authenticated;
grant select on gk.content_series,gk.question_source_memberships,gk.question_enrichments,gk.concept_confusions to authenticated;

create or replace function public.gk_get_intelligence_dashboard()
returns jsonb
language sql
stable security definer
set search_path=pg_catalog,public,gk,auth
as $$
with u as(select auth.uid() uid),
p as(select * from gk.learning_profiles_v2((select uid from u))),
base as(
 select q.question_id,gk.canonical_subject(q.subject) subject,coalesce(nullif(q.topic,''),'General') topic,q.concept_id,
        p.learning_state st,p.retention_attempts,p.retention_correct,p.exposure_count,p.unconfirmed_guess,p.due,
        p.next_review,p.last_attempt,p.first_attempt_correct,
        exists(select 1 from gk.question_source_memberships m join gk.content_series cs on cs.series_id=m.series_id
               where m.question_id=q.question_id and cs.series_kind in('TOPIC_PYQ','MIXED_PYQ')) teacher_pyq
 from gk.questions q join p on p.question_id=q.question_id where q.active
), top as(
 select count(*)::int total,count(*) filter(where exposure_count>0)::int exposed,
  count(*) filter(where st='Persistent Weak')::int persistent_weak,
  count(*) filter(where st in('Persistent Weak','Weak','Fragile'))::int weak_burden,
  count(*) filter(where st='Proven Mastered')::int proven,
  count(*) filter(where unconfirmed_guess)::int unresolved_guesses,
  count(*) filter(where due)::int due,
  coalesce(round(sum(retention_correct)*100.0/nullif(sum(retention_attempts),0),1),0) retention
 from base
), subject_rows as(
 select subject,count(*)::int total,count(*) filter(where exposure_count>0)::int seen,
  count(*) filter(where exposure_count=0)::int unseen,
  count(*) filter(where st='Persistent Weak')::int "persistentWeak",
  count(*) filter(where st='Weak')::int weak,count(*) filter(where st='Fragile')::int fragile,
  count(*) filter(where st='Proven Mastered')::int mastered,
  count(*) filter(where unconfirmed_guess)::int guessed,
  count(*) filter(where teacher_pyq and exposure_count=0)::int "unseenHighYield",
  coalesce(round(sum(retention_correct)*100.0/nullif(sum(retention_attempts),0),1),0) retention,
  coalesce(round(count(*) filter(where exposure_count>0)*100.0/nullif(count(*),0),1),0) coverage,
  (count(*) filter(where st='Persistent Weak')*5 + count(*) filter(where st='Weak')*3 + count(*) filter(where st='Fragile')*2 + count(*) filter(where unconfirmed_guess)*2)::int attention_score
 from base group by subject
), series_rows as(
 select cs.series_id "seriesId",cs.series_kind "seriesKind",cs.title,
  count(distinct m.question_id)::int total,
  count(distinct m.question_id) filter(where p.exposure_count>0)::int exposed,
  count(distinct m.question_id) filter(where p.learning_state in('Persistent Weak','Weak','Fragile'))::int weak,
  count(distinct m.question_id) filter(where p.learning_state='Proven Mastered')::int mastered,
  coalesce(round(count(distinct m.question_id) filter(where p.exposure_count>0)*100.0/nullif(count(distinct m.question_id),0),1),0) completion,
  coalesce(round(sum(p.retention_correct)*100.0/nullif(sum(p.retention_attempts),0),1),0) retention
 from gk.content_series cs join gk.question_source_memberships m on m.series_id=cs.series_id
 join p on p.question_id=m.question_id
 where cs.active and cs.series_kind in('TOPIC_PYQ','MIXED_PYQ','CURRENT_AFFAIRS')
 group by cs.series_id,cs.series_kind,cs.title
), weekly as(
 select count(distinct e.question_id)::int facts_seen
 from gk.exposures e where e.user_id=(select uid from u) and e.exposed_at>=now()-interval '7 days'
), weak_resolved as(
 select count(distinct a.question_id)::int resolved
 from gk.attempts a join base b on b.question_id=a.question_id
 where a.user_id=(select uid from u) and a.attempted_at>=now()-interval '7 days'
   and b.st in('Strong','Proven Mastered')
   and exists(select 1 from gk.attempts old where old.user_id=a.user_id and old.question_id=a.question_id
              and old.attempted_at<a.attempted_at and old.learning_state in('Persistent Weak','Weak','Fragile'))
), score as(
 select t.*,
  coalesce(round(case when t.total=0 then 0 else
    0.45*t.retention + 0.30*(t.exposed*100.0/t.total) + 0.25*(t.proven*100.0/t.total) end,1),0) readiness,
  coalesce(round(t.exposed*100.0/nullif(t.total,0),1),0) exposure_pct,
  coalesce(round(t.proven*100.0/nullif(t.total,0),1),0) proven_pct
 from top t
)
select case when (select uid from u) is null then jsonb_build_object('ok',false,'error','Authentication required') else jsonb_build_object(
 'ok',true,
 'overview',(select jsonb_build_object(
   'readiness',readiness,'retention',retention,'bankExposure',exposure_pct,'provenKnowledge',proven_pct,
   'weakBurden',weak_burden,'persistentWeak',persistent_weak,'unresolvedGuesses',unresolved_guesses,'due',due,
   'teacherContentCompletion',exposure_pct,'questionBankExposure',exposure_pct,'knowledgeRetention',retention
 ) from score),
 'needsAttention',(select coalesce(jsonb_agg(to_jsonb(x) order by x.attention_score desc,x.subject),'[]'::jsonb) from (select * from subject_rows order by attention_score desc,subject limit 4)x),
 'strongest',(select coalesce(jsonb_agg(to_jsonb(x) order by x.retention desc,x.coverage desc),'[]'::jsonb) from (select * from subject_rows where seen>0 order by retention desc,coverage desc limit 3)x),
 'subjects',(select coalesce(jsonb_agg(to_jsonb(x) order by x.attention_score desc,x.subject),'[]'::jsonb) from subject_rows x),
 'seriesProgress',(select coalesce(jsonb_agg(to_jsonb(x) order by case x."seriesKind" when 'TOPIC_PYQ' then 1 when 'MIXED_PYQ' then 2 else 3 end,x.title),'[]'::jsonb) from series_rows x),
 'thisWeek',jsonb_build_object('factsSeen',(select facts_seen from weekly),'weakResolved',(select resolved from weak_resolved),'unresolvedGuesses',(select unresolved_guesses from top))
) end;
$$;

create or replace function public.gk_get_teacher_library()
returns jsonb
language sql
stable security definer
set search_path=pg_catalog,public,gk,auth
as $$
with u as(select auth.uid() uid),p as(select * from gk.learning_profiles_v2((select uid from u))), rows as(
 select cs.series_id "seriesId",cs.series_kind "seriesKind",cs.title,
        m.lecture_key "lectureKey",max(m.source_label) "sourceLabel",max(m.source_date) "sourceDate",
        count(distinct m.question_id)::int total,
        count(distinct m.question_id) filter(where p.exposure_count>0)::int exposed,
        count(distinct m.question_id) filter(where p.learning_state in('Persistent Weak','Weak','Fragile'))::int weak,
        count(distinct m.question_id) filter(where p.learning_state='Proven Mastered')::int mastered
 from gk.content_series cs join gk.question_source_memberships m on m.series_id=cs.series_id
 join p on p.question_id=m.question_id
 where cs.active and cs.series_kind in('TOPIC_PYQ','MIXED_PYQ','CURRENT_AFFAIRS')
 group by cs.series_id,cs.series_kind,cs.title,m.lecture_key
)
select case when (select uid from u) is null then jsonb_build_object('ok',false,'error','Authentication required') else jsonb_build_object(
 'ok',true,'lectures',coalesce((select jsonb_agg(to_jsonb(rows) order by "seriesKind","lectureKey") from rows),'[]'::jsonb)
) end;
$$;

create or replace function public.gk_get_knowledge_story(p_concept_id text default null,p_question_id text default null)
returns jsonb
language sql
stable security definer
set search_path=pg_catalog,public,gk,auth
as $$
with u as(select auth.uid() uid), seed as(
 select q.* from gk.questions q
 where q.active and (q.question_id=p_question_id or (p_question_id is null and q.concept_id=p_concept_id))
 order by case when q.question_id=p_question_id then 0 else 1 end,q.question_id limit 1
), cid as(select coalesce(nullif(p_concept_id,''),(select concept_id from seed)) concept_id), family as(
 select q.question_id,q.subject,q.topic,q.concept_id from gk.questions q,cid
 where q.active and ((cid.concept_id is not null and q.concept_id=cid.concept_id) or (cid.concept_id is null and q.question_id=p_question_id))
), prof as(
 select p.* from gk.learning_profiles_v2((select uid from u)) p join family f on f.question_id=p.question_id
), agg as(
 select count(*)::int questions,sum(attempts)::int attempts,sum(correct)::int correct,sum(wrong)::int wrong,
        sum(guessed_attempts)::int guessed,min(first_seen) "firstSeen",max(last_attempt) "lastAttempt",min(next_review) "nextRecall",
        count(*) filter(where learning_state='Persistent Weak')::int persistent,
        count(*) filter(where learning_state in('Persistent Weak','Weak','Fragile'))::int weak,
        count(*) filter(where learning_state='Proven Mastered')::int mastered
 from prof
), sources as(
 select distinct cs.title "seriesTitle",cs.series_kind "seriesKind",m.lecture_key "lectureKey",m.source_label "sourceLabel",m.source_page "sourcePage",m.source_date "sourceDate"
 from family f join gk.question_source_memberships m on m.question_id=f.question_id join gk.content_series cs on cs.series_id=m.series_id
), support as(
 select e.* from gk.question_enrichments e where e.question_id=(select question_id from seed)
), confusions as(
 select * from gk.concept_confusions c,cid where c.active and cid.concept_id is not null and (c.concept_a=cid.concept_id or c.concept_b=cid.concept_id)
)
select case when (select uid from u) is null then jsonb_build_object('ok',false,'error','Authentication required')
when not exists(select 1 from family) then jsonb_build_object('ok',false,'error','Knowledge story not found')
else jsonb_build_object(
 'ok',true,'conceptId',(select concept_id from cid),
 'title',coalesce((select nullif(topic,'') from seed),(select topic from family limit 1),(select concept_id from cid),p_question_id),
 'subject',gk.canonical_subject(coalesce((select subject from seed),(select subject from family limit 1))),
 'history',(select to_jsonb(agg)||jsonb_build_object('currentState',case when persistent>0 then 'Persistent Weak' when weak>0 then 'Weak' when mastered=questions and questions>0 then 'Proven Mastered' else 'Learning' end) from agg),
 'sources',coalesce((select jsonb_agg(to_jsonb(s) order by "seriesKind","lectureKey") from sources s),'[]'::jsonb),
 'questions',coalesce((select jsonb_agg(jsonb_build_object('questionId',f.question_id,'topic',f.topic,'state',p.learning_state,'attempts',p.attempts,'wrong',p.wrong,'guessed',p.guessed_attempts,'nextRecall',p.next_review) order by f.question_id) from family f join prof p on p.question_id=f.question_id),'[]'::jsonb),
 'learningSupport',coalesce((select to_jsonb(s)-'question_id'-'model_note' from support s),'{}'::jsonb),
 'confusions',coalesce((select jsonb_agg(jsonb_build_object('label',c.label,'conceptA',c.concept_a,'conceptB',c.concept_b,'evidenceCount',c.evidence_count,'verified',c.verification_status='VERIFIED')) from confusions c),'[]'::jsonb)
) end;
$$;

create or replace function public.gk_get_sprint_plan()
returns jsonb
language sql
stable security definer
set search_path=pg_catalog,public,gk,auth
as $$
with u as(select auth.uid() uid),p as(select * from gk.learning_profiles_v2((select uid from u))),b as(
 select q.question_id,q.content_lane,gk.canonical_subject(q.subject) subject,p.learning_state,p.due,p.unconfirmed_guess,p.exposure_count,
        exists(select 1 from gk.question_source_memberships m join gk.content_series s on s.series_id=m.series_id where m.question_id=q.question_id and s.series_kind in('TOPIC_PYQ','MIXED_PYQ')) teacher_pyq
 from gk.questions q join p on p.question_id=q.question_id where q.active
),x as(
 select count(*)::int total,count(*) filter(where exposure_count>0)::int exposed,
 count(*) filter(where learning_state in('Persistent Weak','Weak','Fragile'))::int weak,
 count(*) filter(where due)::int due,count(*) filter(where unconfirmed_guess)::int guessed,
 count(*) filter(where teacher_pyq and exposure_count=0)::int unseen_teacher,
 count(*) filter(where subject='Current Affairs')::int current_affairs
 from b
)
select case when (select uid from u) is null then jsonb_build_object('ok',false,'error','Authentication required') else jsonb_build_object(
 'ok',true,
 'phase',(select case when total=0 or exposed*100.0/nullif(total,0)<40 then 'EARLY' when exposed*100.0/nullif(total,0)<75 then 'MIDDLE' else 'FINAL' end from x),
 'counts',(select to_jsonb(x) from x),
 'actions',jsonb_build_array(
   jsonb_build_object('key','daily','title','Daily Revision','count',(select least(20,greatest(0,due+weak)) from x),'mode','daily','lane','MIXED'),
   jsonb_build_object('key','weak','title','Morning Weak Recall','count',(select least(10,weak) from x),'mode','weak','lane','MIXED'),
   jsonb_build_object('key','teacher','title','High-yield Teacher PYQ','count',(select least(20,unseen_teacher) from x),'mode','new','lane','MAIN'),
   jsonb_build_object('key','current','title','Current Affairs','count',(select least(10,current_affairs) from x),'mode','current_smart','lane','MIXED'),
   jsonb_build_object('key','section','title','GK Section Sprint','count',25,'mode','section_sprint','lane','MAIN'),
   jsonb_build_object('key','night','title','Night Rapid Recall','count',10,'mode','weak','lane','RAPID')
 )
) end;
$$;

create or replace function public.gk_start_section_sprint(p_count integer default 25)
returns jsonb
language plpgsql
security definer
set search_path=pg_catalog,public,gk,auth
as $$
declare uid uuid:=auth.uid(); n int:=greatest(1,least(50,coalesce(p_count,25))); sid text; qs jsonb;
begin
 if uid is null then raise exception 'Authentication required'; end if;
 qs:=public.gk_get_batch('random',n,'MAIN',null,null,null,null,null,null,null);
 sid:='gk-sprint-'||substr(md5(uid::text||clock_timestamp()::text||random()::text),1,24);
 insert into gk.exam_sessions(session_id,user_id,mode,question_ids,duration_seconds)
 values(sid,uid,'SECTION_SPRINT',coalesce((select jsonb_agg(v->>'id') from jsonb_array_elements(coalesce(qs,'[]'::jsonb)) v),'[]'::jsonb),900);
 return jsonb_build_object('ok',true,'sessionId',sid,'durationSeconds',900,'startedAt',now(),'questions',coalesce(qs,'[]'::jsonb));
end;
$$;

create or replace function public.gk_get_section_sprint_session(p_session_id text)
returns jsonb
language sql
stable security definer
set search_path=pg_catalog,public,gk,auth
as $$
with s as(select * from gk.exam_sessions where session_id=p_session_id and user_id=auth.uid()), q as(
 select e.ord,gk.question_payload_v2_read(auth.uid(),e.question_id) payload
 from s,jsonb_array_elements_text(s.question_ids) with ordinality e(question_id,ord)
),a as(select * from gk.exam_answers where session_id=p_session_id)
select case when auth.uid() is null then jsonb_build_object('ok',false,'error','Authentication required')
when not exists(select 1 from s) then jsonb_build_object('ok',false,'error','Sprint not found')
else jsonb_build_object('ok',true,'sessionId',p_session_id,'durationSeconds',(select duration_seconds from s),'startedAt',(select started_at from s),'completed',(select completed from s),'result',(select result from s),
 'questions',coalesce((select jsonb_agg(payload order by ord) from q),'[]'::jsonb),
 'answers',coalesce((select jsonb_object_agg(question_id,jsonb_build_object('selected',selected_option,'correct',is_correct,'responseMs',response_ms)) from a),'{}'::jsonb)) end;
$$;

create or replace function public.gk_finish_section_sprint(p_session_id text,p_answers jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
security definer
set search_path=pg_catalog,public,gk,auth
as $$
declare uid uuid:=auth.uid(); item record; total int; correct_n int; wrong_n int; attempted_n int; result jsonb;
begin
 if uid is null then raise exception 'Authentication required'; end if;
 if not exists(select 1 from gk.exam_sessions where session_id=p_session_id and user_id=uid) then raise exception 'Sprint not found'; end if;
 for item in select key question_id,value answer from jsonb_each(coalesce(p_answers,'{}'::jsonb)) loop
   if exists(select 1 from gk.exam_sessions s,jsonb_array_elements_text(s.question_ids) qid where s.session_id=p_session_id and s.user_id=uid and qid=item.question_id) then
     insert into gk.exam_answers(session_id,question_id,selected_option,is_correct,response_ms)
     select p_session_id,q.question_id,upper(nullif(item.answer->>'selected','')),
            upper(nullif(item.answer->>'selected',''))=upper(coalesce(q.correct_option,'')),
            greatest(0,coalesce((item.answer->>'responseMs')::int,0))
     from gk.questions q where q.question_id=item.question_id and q.active
     on conflict(session_id,question_id) do nothing;
   end if;
 end loop;
 select jsonb_array_length(question_ids) into total from gk.exam_sessions where session_id=p_session_id and user_id=uid;
 select count(*) filter(where is_correct),count(*) filter(where is_correct is false),count(*)
 into correct_n,wrong_n,attempted_n from gk.exam_answers where session_id=p_session_id;
 result:=jsonb_build_object(
   'score',round((correct_n*2.0-wrong_n*0.5)::numeric,2),'maxScore',total*2,
   'correct',correct_n,'wrong',wrong_n,'unattempted',greatest(0,total-attempted_n),
   'accuracy',case when attempted_n=0 then 0 else round(correct_n*100.0/attempted_n,1) end,
   'averageTimeMs',coalesce((select round(avg(response_ms))::int from gk.exam_answers where session_id=p_session_id and response_ms>0),0)
 );
 update gk.exam_sessions set completed=true,completed_at=coalesce(completed_at,now()),result=result where session_id=p_session_id and user_id=uid;
 return jsonb_build_object('ok',true,'sessionId',p_session_id,'result',result,'learningHistoryChanged',false);
end;
$$;

revoke all on function public.gk_get_intelligence_dashboard() from public,anon;
revoke all on function public.gk_get_teacher_library() from public,anon;
revoke all on function public.gk_get_knowledge_story(text,text) from public,anon;
revoke all on function public.gk_get_sprint_plan() from public,anon;
revoke all on function public.gk_start_section_sprint(integer) from public,anon;
revoke all on function public.gk_get_section_sprint_session(text) from public,anon;
revoke all on function public.gk_finish_section_sprint(text,jsonb) from public,anon;
grant execute on function public.gk_get_intelligence_dashboard() to authenticated;
grant execute on function public.gk_get_teacher_library() to authenticated;
grant execute on function public.gk_get_knowledge_story(text,text) to authenticated;
grant execute on function public.gk_get_sprint_plan() to authenticated;
grant execute on function public.gk_start_section_sprint(integer) to authenticated;
grant execute on function public.gk_get_section_sprint_session(text) to authenticated;
grant execute on function public.gk_finish_section_sprint(text,jsonb) to authenticated;

-- Targeted runtime indexes: only the query shapes introduced/confirmed by this work.
create index if not exists gk_attempts_user_question_time_idx on gk.attempts(user_id,question_id,attempted_at desc);
create index if not exists gk_exposures_user_question_time_idx on gk.exposures(user_id,question_id,exposed_at desc);
create index if not exists gk_session_questions_question_session_idx on gk.session_questions(question_id,session_id);
create index if not exists gk_question_state_user_due_idx on gk.question_state(user_id,next_review) where next_review is not null;

commit;
