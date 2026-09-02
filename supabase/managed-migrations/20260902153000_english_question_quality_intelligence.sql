-- English V2 question-quality intelligence.
-- Adds learner-specific difficulty calibration, distractor evidence, canonical review queue,
-- confusable-term memory, revision outcome learning, generated-question provenance and worker telemetry.
-- No canonical question row is rewritten by this migration.

create table if not exists english.question_quality_metrics (
  user_id uuid not null references auth.users(id) on delete cascade,
  question_id text not null references english.questions(question_id) on delete cascade,
  attempts integer not null default 0,
  correct integer not null default 0,
  wrong integer not null default 0,
  guessed integer not null default 0,
  correct_rate numeric not null default 0 check (correct_rate between 0 and 1),
  avg_time_seconds numeric not null default 0,
  observed_difficulty numeric not null default 0.5 check (observed_difficulty between 0 and 1),
  distractor_effectiveness numeric not null default 0 check (distractor_effectiveness between 0 and 1),
  triviality_score numeric not null default 0.5 check (triviality_score between 0 and 1),
  too_easy boolean not null default false,
  wrong_option_counts jsonb not null default '{}'::jsonb,
  last_attempt_at timestamptz,
  updated_at timestamptz not null default now(),
  primary key(user_id,question_id)
);

create table if not exists english.question_distractor_metrics (
  user_id uuid not null references auth.users(id) on delete cascade,
  question_id text not null references english.questions(question_id) on delete cascade,
  option_key text not null check (option_key in ('A','B','C','D')),
  selected_when_wrong integer not null default 0,
  share_of_wrong numeric not null default 0 check (share_of_wrong between 0 and 1),
  effectiveness numeric not null default 0 check (effectiveness between 0 and 1),
  updated_at timestamptz not null default now(),
  primary key(user_id,question_id,option_key)
);

create table if not exists english.revision_strategy_stats (
  user_id uuid not null references auth.users(id) on delete cascade,
  feedback_reason text not null,
  ready_count integer not null default 0,
  applied_count integer not null default 0,
  kept_count integer not null default 0,
  failed_count integer not null default 0,
  followup_attempts integer not null default 0,
  followup_correct integer not null default 0,
  followup_wrong integer not null default 0,
  updated_at timestamptz not null default now(),
  primary key(user_id,feedback_reason)
);

create table if not exists english.confusable_clusters (
  cluster_id uuid primary key default gen_random_uuid(),
  anchor_concept_id text not null references english.concepts(concept_id) on delete cascade,
  label text not null,
  source text not null default 'ai_validated' check (source in ('curated','learner','ai_validated','semantic')),
  active boolean not null default true,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(anchor_concept_id,label)
);

create table if not exists english.confusable_cluster_terms (
  cluster_id uuid not null references english.confusable_clusters(cluster_id) on delete cascade,
  term text not null,
  concept_id text references english.concepts(concept_id) on delete set null,
  relation text not null default 'confusable',
  weight numeric not null default 0.7 check (weight between 0 and 1),
  source text not null default 'ai_validated',
  created_at timestamptz not null default now(),
  primary key(cluster_id,term)
);

create table if not exists english.question_generation_provenance (
  question_id text primary key references english.questions(question_id) on delete cascade,
  owner_user_id uuid references auth.users(id) on delete cascade,
  source_question_id text references english.questions(question_id) on delete set null,
  concept_id text references english.concepts(concept_id) on delete set null,
  intent text not null,
  generation_source text not null,
  critic jsonb not null default '{}'::jsonb,
  related_terms jsonb not null default '[]'::jsonb,
  model text,
  usage jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

create table if not exists english.worker_observability (
  event_id bigint generated always as identity primary key,
  worker text not null default 'english-context-worker',
  metrics jsonb not null,
  elapsed_ms integer not null default 0,
  created_at timestamptz not null default now()
);
create index if not exists english_worker_observability_created_idx on english.worker_observability(created_at desc);

create table if not exists english.question_quality_reviews (
  review_id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  question_id text not null references english.questions(question_id) on delete cascade,
  reason text not null default 'correct_answer_doubtful' check (reason in ('correct_answer_doubtful','ambiguity','content_error')),
  note text,
  status text not null default 'queued' check (status in ('queued','processing','reviewed','failed','closed')),
  verdict text check (verdict is null or verdict in ('valid','issue_suspected')),
  critic jsonb,
  attempts integer not null default 0 check (attempts between 0 and 3),
  claimed_at timestamptz,
  next_attempt_at timestamptz,
  last_error text,
  reviewed_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists english_question_quality_review_queue_idx
  on english.question_quality_reviews(status,next_attempt_at,created_at)
  where status in ('queued','processing');
create index if not exists english_question_quality_review_user_idx
  on english.question_quality_reviews(user_id,question_id,created_at desc);

alter table english.question_quality_metrics enable row level security;
alter table english.question_distractor_metrics enable row level security;
alter table english.revision_strategy_stats enable row level security;
alter table english.confusable_clusters enable row level security;
alter table english.confusable_cluster_terms enable row level security;
alter table english.question_generation_provenance enable row level security;
alter table english.worker_observability enable row level security;
alter table english.question_quality_reviews enable row level security;

revoke all on english.question_quality_metrics,english.question_distractor_metrics,english.revision_strategy_stats,
  english.confusable_clusters,english.confusable_cluster_terms,english.question_generation_provenance,
  english.worker_observability,english.question_quality_reviews from public,anon,authenticated;
grant select,insert,update,delete on english.question_quality_metrics,english.question_distractor_metrics,
  english.revision_strategy_stats,english.confusable_clusters,english.confusable_cluster_terms,
  english.question_generation_provenance,english.worker_observability,english.question_quality_reviews to service_role;

create policy english_question_quality_metrics_own_read on english.question_quality_metrics
  for select to authenticated using (user_id=(select auth.uid()));
create policy english_question_distractor_metrics_own_read on english.question_distractor_metrics
  for select to authenticated using (user_id=(select auth.uid()));
create policy english_revision_strategy_stats_own_read on english.revision_strategy_stats
  for select to authenticated using (user_id=(select auth.uid()));
create policy english_question_quality_reviews_own_read on english.question_quality_reviews
  for select to authenticated using (user_id=(select auth.uid()));

create or replace function english.recompute_question_quality(p_user_id uuid,p_question_id text)
returns void
language plpgsql
security definer
set search_path to 'pg_catalog','english'
as $$
declare
  q english.questions%rowtype;
  v_attempts integer:=0; v_correct integer:=0; v_wrong integer:=0; v_guessed integer:=0;
  v_avg numeric:=0; v_rate numeric:=0; v_wrong_rate numeric:=0; v_guess_rate numeric:=0; v_time_factor numeric:=0;
  v_difficulty numeric:=0.5; v_effective numeric:=0; v_trivial numeric:=0.5; v_too_easy boolean:=false;
  v_a integer:=0; v_b integer:=0; v_c integer:=0; v_d integer:=0; v_distinct integer:=0; v_last timestamptz;
  k text; c integer; total_wrong integer;
begin
  if p_user_id is null or nullif(trim(coalesce(p_question_id,'')),'') is null then return; end if;
  select * into q from english.questions where question_id=p_question_id;
  if not found then return; end if;

  select count(*)::int,
         count(*) filter(where coalesce(a.correct,false))::int,
         count(*) filter(where not coalesce(a.correct,false))::int,
         coalesce(avg(greatest(0,coalesce(a.time_seconds,0))),0),
         max(a.attempted_at),
         count(*) filter(where not coalesce(a.correct,false) and upper(coalesce(a.selected_answer,''))='A')::int,
         count(*) filter(where not coalesce(a.correct,false) and upper(coalesce(a.selected_answer,''))='B')::int,
         count(*) filter(where not coalesce(a.correct,false) and upper(coalesce(a.selected_answer,''))='C')::int,
         count(*) filter(where not coalesce(a.correct,false) and upper(coalesce(a.selected_answer,''))='D')::int
  into v_attempts,v_correct,v_wrong,v_avg,v_last,v_a,v_b,v_c,v_d
  from english.attempts a where a.user_id=p_user_id and a.question_id=p_question_id;

  select count(*)::int into v_guessed
  from english.learner_confidence_signals g
  where g.user_id=p_user_id and g.question_id=p_question_id and g.signal='guessed';

  v_rate:=case when v_attempts>0 then v_correct::numeric/v_attempts else 0 end;
  v_wrong_rate:=case when v_attempts>0 then v_wrong::numeric/v_attempts else 0 end;
  v_guess_rate:=case when v_attempts>0 then least(1,v_guessed::numeric/v_attempts) else 0 end;
  v_time_factor:=least(1,coalesce(v_avg,0)/45.0);
  v_difficulty:=greatest(0,least(1,round((v_wrong_rate*0.55+v_guess_rate*0.25+v_time_factor*0.20)::numeric,4)));
  total_wrong:=greatest(0,v_wrong);
  v_distinct:=(case when v_a>0 and upper(coalesce(q.correct,''))<>'A' then 1 else 0 end)
             +(case when v_b>0 and upper(coalesce(q.correct,''))<>'B' then 1 else 0 end)
             +(case when v_c>0 and upper(coalesce(q.correct,''))<>'C' then 1 else 0 end)
             +(case when v_d>0 and upper(coalesce(q.correct,''))<>'D' then 1 else 0 end);
  v_effective:=case when total_wrong=0 then 0 else least(1,round(((v_distinct::numeric/3.0)*0.7+least(1,total_wrong::numeric/6.0)*0.3)::numeric,4)) end;
  v_trivial:=greatest(0,least(1,round((1-v_difficulty)::numeric,4)));
  v_too_easy:=v_attempts>=2 and v_rate>=0.80 and v_difficulty<0.28 and v_guessed=0;
  if v_attempts>=3 and v_rate>=0.90 and coalesce(v_avg,0)<15 and v_guessed=0 then v_too_easy:=true; end if;

  insert into english.question_quality_metrics(
    user_id,question_id,attempts,correct,wrong,guessed,correct_rate,avg_time_seconds,observed_difficulty,
    distractor_effectiveness,triviality_score,too_easy,wrong_option_counts,last_attempt_at,updated_at
  ) values(
    p_user_id,p_question_id,v_attempts,v_correct,v_wrong,v_guessed,v_rate,round(coalesce(v_avg,0)::numeric,2),v_difficulty,
    v_effective,v_trivial,v_too_easy,jsonb_build_object('A',v_a,'B',v_b,'C',v_c,'D',v_d),v_last,now()
  ) on conflict(user_id,question_id) do update set
    attempts=excluded.attempts,correct=excluded.correct,wrong=excluded.wrong,guessed=excluded.guessed,
    correct_rate=excluded.correct_rate,avg_time_seconds=excluded.avg_time_seconds,observed_difficulty=excluded.observed_difficulty,
    distractor_effectiveness=excluded.distractor_effectiveness,triviality_score=excluded.triviality_score,too_easy=excluded.too_easy,
    wrong_option_counts=excluded.wrong_option_counts,last_attempt_at=excluded.last_attempt_at,updated_at=now();

  foreach k in array array['A','B','C','D'] loop
    c:=case k when 'A' then v_a when 'B' then v_b when 'C' then v_c else v_d end;
    if k=upper(coalesce(q.correct,'')) then
      delete from english.question_distractor_metrics where user_id=p_user_id and question_id=p_question_id and option_key=k;
    else
      insert into english.question_distractor_metrics(user_id,question_id,option_key,selected_when_wrong,share_of_wrong,effectiveness,updated_at)
      values(p_user_id,p_question_id,k,c,case when total_wrong>0 then c::numeric/total_wrong else 0 end,
        case when total_wrong>0 then least(1,(c::numeric/total_wrong)*3) else 0 end,now())
      on conflict(user_id,question_id,option_key) do update set selected_when_wrong=excluded.selected_when_wrong,
        share_of_wrong=excluded.share_of_wrong,effectiveness=excluded.effectiveness,updated_at=now();
    end if;
  end loop;
end $$;

create or replace function english.on_question_quality_attempt()
returns trigger
language plpgsql
security definer
set search_path to 'pg_catalog','english'
as $$
begin
  perform english.recompute_question_quality(new.user_id,new.question_id);
  return new;
end $$;

drop trigger if exists english_question_quality_attempt_trg on english.attempts;
create trigger english_question_quality_attempt_trg
after insert or update of selected_answer,correct,time_seconds on english.attempts
for each row execute function english.on_question_quality_attempt();

create or replace function english.on_question_quality_guess()
returns trigger
language plpgsql
security definer
set search_path to 'pg_catalog','english'
as $$
begin
  perform english.recompute_question_quality(new.user_id,new.question_id);
  return new;
end $$;

drop trigger if exists english_question_quality_guess_trg on english.learner_confidence_signals;
create trigger english_question_quality_guess_trg
after insert or update of resolved_at on english.learner_confidence_signals
for each row execute function english.on_question_quality_guess();

create or replace function english.on_revision_followup_attempt()
returns trigger
language plpgsql
security definer
set search_path to 'pg_catalog','english'
as $$
declare v_reason text;
begin
  select p.feedback_reason into v_reason
  from english.user_question_revisions r
  join english.question_revision_proposals p on p.proposal_id=r.proposal_id
  where r.user_id=new.user_id and r.question_id=new.question_id and new.attempted_at>=r.applied_at;
  if v_reason is null then return new; end if;
  insert into english.revision_strategy_stats(user_id,feedback_reason,followup_attempts,followup_correct,followup_wrong,updated_at)
  values(new.user_id,v_reason,1,case when coalesce(new.correct,false) then 1 else 0 end,case when coalesce(new.correct,false) then 0 else 1 end,now())
  on conflict(user_id,feedback_reason) do update set
    followup_attempts=english.revision_strategy_stats.followup_attempts+1,
    followup_correct=english.revision_strategy_stats.followup_correct+case when coalesce(new.correct,false) then 1 else 0 end,
    followup_wrong=english.revision_strategy_stats.followup_wrong+case when coalesce(new.correct,false) then 0 else 1 end,
    updated_at=now();
  return new;
end $$;

drop trigger if exists english_revision_followup_attempt_trg on english.attempts;
create trigger english_revision_followup_attempt_trg
after insert on english.attempts
for each row execute function english.on_revision_followup_attempt();

create or replace function english.confusable_terms_for_concept(p_concept_id text,p_limit integer default 6)
returns jsonb
language sql
stable
security definer
set search_path to 'pg_catalog','english'
as $$
with anchor as(
  select c.name term,1.0::numeric weight from english.concepts c where c.concept_id=p_concept_id and c.active
), saved as(
  select t.term,t.weight from english.confusable_cluster_terms t
  join english.confusable_clusters c on c.cluster_id=t.cluster_id and c.active
  where c.anchor_concept_id=p_concept_id
), all_terms as(
  select * from anchor union all select * from saved
), ranked as(
  select term,max(weight) weight from all_terms where nullif(trim(coalesce(term,'')),'') is not null group by term
  order by max(weight) desc,term limit greatest(1,least(12,coalesce(p_limit,6)))
)
select coalesce(jsonb_agg(term order by weight desc,term),'[]'::jsonb) from ranked;
$$;

create or replace function english.upsert_confusable_terms(p_token text,p_concept_id text,p_terms jsonb,p_source text default 'ai_validated')
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','english'
as $$
declare v_cluster uuid; v_label text; t text; n integer:=0;
begin
  if not english.context_worker_authorized(p_token) then raise exception 'context worker unauthorized'; end if;
  if p_concept_id is null or jsonb_typeof(coalesce(p_terms,'[]'::jsonb))<>'array' then return jsonb_build_object('ok',false); end if;
  select coalesce(nullif(trim(name),''),p_concept_id)||' confusables' into v_label from english.concepts where concept_id=p_concept_id;
  if v_label is null then return jsonb_build_object('ok',false); end if;
  insert into english.confusable_clusters(anchor_concept_id,label,source,metadata,updated_at)
  values(p_concept_id,v_label,case when p_source in ('curated','learner','ai_validated','semantic') then p_source else 'ai_validated' end,'{}'::jsonb,now())
  on conflict(anchor_concept_id,label) do update set active=true,updated_at=now()
  returning cluster_id into v_cluster;
  for t in select trim(value) from jsonb_array_elements_text(p_terms) value where nullif(trim(value),'') is not null limit 12 loop
    insert into english.confusable_cluster_terms(cluster_id,term,weight,source)
    values(v_cluster,left(t,120),0.8,case when p_source in ('curated','learner','ai_validated','semantic') then p_source else 'ai_validated' end)
    on conflict(cluster_id,term) do update set weight=greatest(english.confusable_cluster_terms.weight,excluded.weight),source=excluded.source;
    n:=n+1;
  end loop;
  return jsonb_build_object('ok',true,'clusterId',v_cluster,'terms',n);
end $$;

create or replace function public.english_request_question_quality_review(p_question_id text,p_note text default null)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','public','english','auth'
as $$
declare uid uuid:=(select auth.uid()); v_id uuid; v_note text:=nullif(trim(coalesce(p_note,'')),'');
begin
  if uid is null then raise exception 'authentication required'; end if;
  if not exists(select 1 from english.questions q where q.question_id=p_question_id and q.active and english.question_visible_to_user(uid,q.question_id)) then raise exception 'question not found'; end if;
  if v_note is not null and char_length(v_note)>600 then raise exception 'review note must be at most 600 characters'; end if;
  select review_id into v_id from english.question_quality_reviews
  where user_id=uid and question_id=p_question_id and status in ('queued','processing') order by created_at desc limit 1;
  if v_id is not null then
    update english.question_quality_reviews set note=coalesce(v_note,note),updated_at=now() where review_id=v_id;
    return jsonb_build_object('ok',true,'reviewId',v_id,'status','queued','kind','canonical_review');
  end if;
  insert into english.question_quality_reviews(user_id,question_id,reason,note,status,next_attempt_at)
  values(uid,p_question_id,'correct_answer_doubtful',v_note,'queued',now()) returning review_id into v_id;
  return jsonb_build_object('ok',true,'reviewId',v_id,'status','queued','kind','canonical_review');
end $$;
revoke all on function public.english_request_question_quality_review(text,text) from public,anon;
grant execute on function public.english_request_question_quality_review(text,text) to authenticated,service_role;

create or replace function english.question_quality_review_claim(p_token text,p_limit integer default 1)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','english'
as $$
declare outv jsonb;
begin
  if not english.context_worker_authorized(p_token) then raise exception 'context worker unauthorized'; end if;
  update english.question_quality_reviews set status='queued',next_attempt_at=now(),last_error='stale review recovered',updated_at=now()
  where status='processing' and claimed_at<now()-interval '5 minutes' and attempts<3;
  update english.question_quality_reviews set status='failed',last_error=coalesce(last_error,'review retries exhausted'),updated_at=now()
  where status='processing' and claimed_at<now()-interval '5 minutes' and attempts>=3;
  with pick as(
    select review_id from english.question_quality_reviews
    where status='queued' and attempts<3 and (next_attempt_at is null or next_attempt_at<=now())
    order by created_at,review_id for update skip locked limit greatest(1,least(2,coalesce(p_limit,1)))
  ), upd as(
    update english.question_quality_reviews r set status='processing',attempts=r.attempts+1,claimed_at=now(),last_error=null,updated_at=now()
    from pick where r.review_id=pick.review_id returning r.*
  )
  select jsonb_build_object('items',coalesce(jsonb_agg(jsonb_build_object(
    'reviewId',u.review_id,'userId',u.user_id,'questionId',u.question_id,'reason',u.reason,'note',u.note,
    'question',jsonb_build_object('question',q.question,'optionA',q.option_a,'optionB',q.option_b,'optionC',q.option_c,'optionD',q.option_d,
      'correctKey',upper(q.correct),'explanation',coalesce(q.explanation,''),'questionType',q.question_type,'difficulty',q.difficulty,'word',q.word),
    'conceptId',m.concept_id,'conceptName',c.name,'quality',to_jsonb(qm)
  ) order by u.created_at),'[]'::jsonb)) into outv
  from upd u join english.questions q on q.question_id=u.question_id
  left join english.question_concept_mappings m on m.question_id=u.question_id
  left join english.concepts c on c.concept_id=m.concept_id
  left join english.question_quality_metrics qm on qm.user_id=u.user_id and qm.question_id=u.question_id;
  return coalesce(outv,jsonb_build_object('items','[]'::jsonb));
end $$;

create or replace function public.english_question_quality_review_claim(p_token text,p_limit integer default 1)
returns jsonb language sql security definer set search_path to 'pg_catalog','public','english'
as $$ select english.question_quality_review_claim(p_token,p_limit); $$;
revoke all on function public.english_question_quality_review_claim(text,integer) from public,anon,authenticated;
grant execute on function public.english_question_quality_review_claim(text,integer) to service_role;

create or replace function english.apply_question_quality_review_result(p_token text,p_review_id uuid,p_critic jsonb,p_model text default 'gpt-5.6-luna',p_usage jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','english'
as $$
declare r english.question_quality_reviews%rowtype; v_verdict text; v_conf numeric;
begin
  if not english.context_worker_authorized(p_token) then raise exception 'context worker unauthorized'; end if;
  select * into r from english.question_quality_reviews where review_id=p_review_id for update;
  if not found then raise exception 'quality review not found'; end if;
  if r.status='reviewed' then return jsonb_build_object('ok',true,'alreadyReviewed',true,'verdict',r.verdict); end if;
  if r.status<>'processing' then raise exception 'quality review is not claimed'; end if;
  v_verdict:=lower(trim(coalesce(p_critic->>'verdict','')));
  v_conf:=coalesce((p_critic->>'confidence')::numeric,0);
  if v_verdict not in ('valid','issue_suspected') or v_conf<0.70 then raise exception 'quality review critic result is insufficient'; end if;
  update english.question_quality_reviews set status='reviewed',verdict=v_verdict,
    critic=coalesce(p_critic,'{}'::jsonb)||jsonb_build_object('model',p_model,'usage',coalesce(p_usage,'{}'::jsonb)),
    reviewed_at=now(),last_error=null,updated_at=now() where review_id=p_review_id;
  return jsonb_build_object('ok',true,'reviewId',p_review_id,'status','reviewed','verdict',v_verdict);
end $$;

create or replace function public.english_apply_question_quality_review_result(p_token text,p_review_id uuid,p_critic jsonb,p_model text default 'gpt-5.6-luna',p_usage jsonb default '{}'::jsonb)
returns jsonb language sql security definer set search_path to 'pg_catalog','public','english'
as $$ select english.apply_question_quality_review_result(p_token,p_review_id,p_critic,p_model,p_usage); $$;
revoke all on function public.english_apply_question_quality_review_result(text,uuid,jsonb,text,jsonb) from public,anon,authenticated;
grant execute on function public.english_apply_question_quality_review_result(text,uuid,jsonb,text,jsonb) to service_role;

create or replace function public.english_fail_question_quality_review(p_token text,p_review_id uuid,p_error text)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','public','english'
as $$
declare r english.question_quality_reviews%rowtype;
begin
  if not english.context_worker_authorized(p_token) then raise exception 'context worker unauthorized'; end if;
  select * into r from english.question_quality_reviews where review_id=p_review_id for update;
  if not found then return jsonb_build_object('ok',false,'missing',true); end if;
  if r.status<>'processing' then return jsonb_build_object('ok',true,'ignored',true,'status',r.status); end if;
  update english.question_quality_reviews set status=case when attempts<3 then 'queued' else 'failed' end,
    next_attempt_at=case when attempts<3 then now()+make_interval(mins=>least(15,greatest(1,attempts)*3)) else null end,
    last_error=left(coalesce(nullif(trim(p_error),''),'quality review failed'),800),updated_at=now() where review_id=p_review_id;
  return jsonb_build_object('ok',true,'retry',r.attempts<3,'attempts',r.attempts);
end $$;
revoke all on function public.english_fail_question_quality_review(text,uuid,text) from public,anon,authenticated;
grant execute on function public.english_fail_question_quality_review(text,uuid,text) to service_role;

create or replace function public.english_get_question_quality_review_state(p_question_id text,p_cache_buster bigint default null)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'pg_catalog','public','english','auth'
as $$
declare uid uuid:=(select auth.uid()); r english.question_quality_reviews%rowtype;
begin
  if uid is null then raise exception 'authentication required'; end if;
  select * into r from english.question_quality_reviews where user_id=uid and question_id=p_question_id order by created_at desc limit 1;
  if not found then return jsonb_build_object('ok',true,'review',null); end if;
  return jsonb_build_object('ok',true,'review',jsonb_strip_nulls(jsonb_build_object(
    'reviewId',r.review_id,'status',r.status,'verdict',r.verdict,'reason',r.reason,
    'rationale',case when r.status='reviewed' then r.critic->>'rationale' else null end,
    'confidence',case when r.status='reviewed' then r.critic->'confidence' else null end,
    'createdAt',r.created_at,'reviewedAt',r.reviewed_at
  )));
end $$;
revoke all on function public.english_get_question_quality_review_state(text,bigint) from public,anon;
grant execute on function public.english_get_question_quality_review_state(text,bigint) to authenticated,service_role;

create or replace function public.english_request_related_practice(p_question_id text,p_note text default null)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','public','english','auth'
as $$
declare uid uuid:=(select auth.uid()); cid text; v_bank text; v_job uuid; v_existing english.targeted_transfer_jobs%rowtype; v_terms jsonb; v_note text:=nullif(trim(coalesce(p_note,'')),'');
begin
  if uid is null then raise exception 'authentication required'; end if;
  if v_note is not null and char_length(v_note)>600 then raise exception 'related-practice note must be at most 600 characters'; end if;
  select m.concept_id into cid from english.questions q join english.question_concept_mappings m on m.question_id=q.question_id
  where q.question_id=p_question_id and q.active and english.question_visible_to_user(uid,q.question_id);
  if cid is null then raise exception 'question concept is unavailable'; end if;
  v_terms:=english.confusable_terms_for_concept(cid,8);

  select q2.question_id into v_bank
  from english.questions q2 join english.question_concept_mappings m2 on m2.question_id=q2.question_id
  left join english.question_quality_metrics qm on qm.user_id=uid and qm.question_id=q2.question_id
  where m2.concept_id=cid and q2.question_id<>p_question_id and q2.active and english.question_visible_to_user(uid,q2.question_id)
    and not coalesce(qm.too_easy,false)
  order by case when qm.question_id is null then 1 else 0 end,coalesce(qm.observed_difficulty,0.5) desc,q2.question_id
  limit 1;
  if v_bank is not null then
    perform english.route_to_targeted(uid,v_bank,'Related Practice','Learner explicitly requested related/confusable practice; existing bank item reused first');
    update english.learning_route_state set metadata=coalesce(metadata,'{}'::jsonb)||jsonb_build_object(
      'targeted_kind','transfer_check','explicit_related_practice',true,'source_question_id',p_question_id,'request_note',v_note),updated_at=now()
    where user_id=uid and question_id=v_bank;
    return jsonb_build_object('ok',true,'status','ready','source','bank_first','questionId',v_bank);
  end if;

  select * into v_existing from english.targeted_transfer_jobs where user_id=uid and concept_id=cid and source_question_id=p_question_id;
  if found then
    if v_existing.status='done' and v_existing.generated_question_id is not null then
      perform english.route_to_targeted(uid,v_existing.generated_question_id,'Related Practice','Existing validated related-practice question reused');
      return jsonb_build_object('ok',true,'status','ready','source','generated_existing','questionId',v_existing.generated_question_id);
    end if;
    update english.targeted_transfer_jobs set reason='Explicit related/confusable practice requested',
      metadata=coalesce(metadata,'{}'::jsonb)||jsonb_build_object('explicitRelatedPractice',true,'requestNote',v_note,'confusableTerms',v_terms,'requestedAt',now()),
      status=case when status='failed' and attempts<3 then 'queued' else status end,
      next_attempt_at=case when status='failed' and attempts<3 then now() else next_attempt_at end,updated_at=now()
    where job_id=v_existing.job_id returning job_id into v_job;
  else
    insert into english.targeted_transfer_jobs(user_id,concept_id,source_question_id,related_term,reason,status,metadata,next_attempt_at)
    values(uid,cid,p_question_id,null,'Explicit related/confusable practice requested','queued',
      jsonb_build_object('explicitRelatedPractice',true,'requestNote',v_note,'confusableTerms',v_terms,'requestedAt',now()),now())
    returning job_id into v_job;
  end if;
  return jsonb_build_object('ok',true,'status','queued','source','generation_queue','jobId',v_job);
end $$;
revoke all on function public.english_request_related_practice(text,text) from public,anon;
grant execute on function public.english_request_related_practice(text,text) to authenticated,service_role;

create or replace function public.english_log_worker_metrics(p_token text,p_metrics jsonb,p_elapsed_ms integer default 0)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','public','english'
as $$
declare v_id bigint;
begin
  if not english.context_worker_authorized(p_token) then raise exception 'context worker unauthorized'; end if;
  insert into english.worker_observability(metrics,elapsed_ms) values(coalesce(p_metrics,'{}'::jsonb),greatest(0,coalesce(p_elapsed_ms,0))) returning event_id into v_id;
  delete from english.worker_observability where created_at<now()-interval '45 days';
  return jsonb_build_object('ok',true,'eventId',v_id);
end $$;
revoke all on function public.english_log_worker_metrics(text,jsonb,integer) from public,anon,authenticated;
grant execute on function public.english_log_worker_metrics(text,jsonb,integer) to service_role;
