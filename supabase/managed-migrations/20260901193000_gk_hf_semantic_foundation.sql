-- GK Hugging Face semantic foundation.
-- Additive only: does not alter quiz selection, learning-state evidence, attempts,
-- exposures, sessions, teacher logic, sprint logic, or any English/Maths runtime.
-- The semantic layer is an admin/content-quality aid. Existing GK remains authoritative.

create extension if not exists vector with schema extensions;

create table if not exists gk.question_embeddings (
  question_id text not null references gk.questions(question_id) on delete cascade,
  model text not null,
  content_hash text not null,
  embedding extensions.vector(384) not null,
  embedded_at timestamptz not null default now(),
  primary key (question_id, model)
);

create index if not exists gk_question_embeddings_model_idx
  on gk.question_embeddings(model, embedded_at desc);

create index if not exists gk_question_embeddings_cosine_hnsw_idx
  on gk.question_embeddings using hnsw (embedding extensions.vector_cosine_ops);

alter table gk.canonical_duplicate_review
  add column if not exists detection_method text not null default 'canonical_fingerprint',
  add column if not exists semantic_similarity numeric null,
  add column if not exists detector_model text null;

alter table gk.canonical_duplicate_review
  drop constraint if exists canonical_duplicate_review_semantic_similarity_check;
alter table gk.canonical_duplicate_review
  add constraint canonical_duplicate_review_semantic_similarity_check
  check (semantic_similarity is null or (semantic_similarity >= 0 and semantic_similarity <= 1));

create index if not exists gk_duplicate_review_detection_idx
  on gk.canonical_duplicate_review(detection_method, review_status, semantic_similarity desc);

revoke all on table gk.question_embeddings from public, anon, authenticated;

-- Stable semantic source: subject/topic/concept + prompt + canonical answer.
-- Distractors and explanations are intentionally excluded so similarity reflects
-- the tested fact/concept rather than boilerplate option wording.
create or replace function gk.hf_semantic_source(p_question_id text)
returns text
language sql
stable
security definer
set search_path=pg_catalog,gk
as $$
select concat_ws(E'\n',
  'Subject: ' || coalesce(nullif(btrim(q.subject),''),'Unknown'),
  'Topic: ' || coalesce(nullif(btrim(q.topic),''),'Unknown'),
  'Concept: ' || coalesce(nullif(btrim(q.concept_id),''),'Unknown'),
  'Question: ' || btrim(q.question),
  'Answer: ' || btrim(coalesce(case upper(btrim(coalesce(q.correct_option,'')))
    when 'A' then q.option_a
    when 'B' then q.option_b
    when 'C' then q.option_c
    when 'D' then q.option_d
    else null end,''))
)
from gk.questions q
where q.question_id=btrim(p_question_id) and q.active
$$;

revoke execute on function gk.hf_semantic_source(text) from public, anon, authenticated, service_role;

-- Internal RPC used only by the authenticated Edge Function through service-role.
create or replace function public.gk_hf_get_embedding_batch(
  p_model text,
  p_limit integer default 8
) returns jsonb
language plpgsql
security definer
set search_path=pg_catalog,public,gk,auth
as $$
declare
  lim integer:=greatest(1,least(coalesce(p_limit,8),32));
  mdl text:=btrim(coalesce(p_model,''));
  out jsonb;
begin
  if coalesce(auth.role(),'') <> 'service_role' then
    raise exception 'Service role required';
  end if;
  if mdl='' then raise exception 'Model required'; end if;

  with src as (
    select q.question_id,
      gk.hf_semantic_source(q.question_id) source_text
    from gk.questions q
    where q.active
  ), hashed as (
    select s.question_id,s.source_text,
      md5(regexp_replace(lower(coalesce(s.source_text,'')),'[[:space:]]+',' ','g')) content_hash
    from src s
    where nullif(btrim(coalesce(s.source_text,'')),'') is not null
  ), needed as (
    select h.question_id,h.source_text,h.content_hash
    from hashed h
    left join gk.question_embeddings e
      on e.question_id=h.question_id and e.model=mdl
    where e.question_id is null or e.content_hash<>h.content_hash
    order by h.question_id
    limit lim
  )
  select jsonb_build_object(
    'model',mdl,
    'items',coalesce(jsonb_agg(jsonb_build_object(
      'questionId',n.question_id,
      'text',n.source_text,
      'contentHash',n.content_hash
    ) order by n.question_id),'[]'::jsonb)
  ) into out
  from needed n;

  return coalesce(out,jsonb_build_object('model',mdl,'items','[]'::jsonb));
end
$$;

revoke execute on function public.gk_hf_get_embedding_batch(text,integer) from public, anon, authenticated;
grant execute on function public.gk_hf_get_embedding_batch(text,integer) to service_role;

create or replace function public.gk_hf_store_embedding(
  p_question_id text,
  p_model text,
  p_content_hash text,
  p_embedding_text text
) returns jsonb
language plpgsql
security definer
set search_path=pg_catalog,public,gk,extensions,auth
as $$
declare
  qid text:=btrim(coalesce(p_question_id,''));
  mdl text:=btrim(coalesce(p_model,''));
  supplied_hash text:=btrim(coalesce(p_content_hash,''));
  current_text text;
  current_hash text;
  v extensions.vector(384);
begin
  if coalesce(auth.role(),'') <> 'service_role' then
    raise exception 'Service role required';
  end if;
  if qid='' or mdl='' or supplied_hash='' then raise exception 'Embedding identity incomplete'; end if;

  current_text:=gk.hf_semantic_source(qid);
  if current_text is null then raise exception 'Active GK question not found'; end if;
  current_hash:=md5(regexp_replace(lower(current_text),'[[:space:]]+',' ','g'));
  if current_hash<>supplied_hash then raise exception 'Question content changed before embedding write'; end if;

  begin
    v:=p_embedding_text::extensions.vector(384);
  exception when others then
    raise exception 'Invalid 384-dimension embedding payload';
  end;

  insert into gk.question_embeddings(question_id,model,content_hash,embedding,embedded_at)
  values(qid,mdl,current_hash,v,now())
  on conflict(question_id,model) do update set
    content_hash=excluded.content_hash,
    embedding=excluded.embedding,
    embedded_at=excluded.embedded_at;

  return jsonb_build_object('ok',true,'questionId',qid,'model',mdl);
end
$$;

revoke execute on function public.gk_hf_store_embedding(text,text,text,text) from public, anon, authenticated;
grant execute on function public.gk_hf_store_embedding(text,text,text,text) to service_role;

-- Build review candidates from cached vectors. Nothing is auto-deleted or merged.
-- Existing human decisions (SAME_PYQ / DISTINCT / DEFERRED) are preserved.
create or replace function public.gk_hf_refresh_duplicate_candidates(
  p_model text,
  p_min_similarity numeric default 0.84,
  p_limit_per_question integer default 5
) returns jsonb
language plpgsql
security definer
set search_path=pg_catalog,public,gk,extensions,auth
as $$
declare
  mdl text:=btrim(coalesce(p_model,''));
  threshold numeric:=greatest(0.70,least(coalesce(p_min_similarity,0.84),0.99));
  per_q integer:=greatest(1,least(coalesce(p_limit_per_question,5),10));
  inserted_count integer:=0;
  candidate_count integer:=0;
begin
  if coalesce(auth.role(),'') <> 'service_role' then
    raise exception 'Service role required';
  end if;
  if mdl='' then raise exception 'Model required'; end if;

  -- Remove only unresolved machine-generated rows from this detector/model so
  -- reruns are deterministic. Human-reviewed outcomes are never removed.
  delete from gk.canonical_duplicate_review
  where detection_method='hf_semantic'
    and detector_model=mdl
    and review_status='NEEDS_REVIEW';

  with pairs as (
    select e1.question_id canonical_question_id,
      e2.question_id candidate_question_id,
      q1.canonical_fingerprint,
      q1.subject subject_1,
      q2.subject subject_2,
      (1-(e1.embedding <=> e2.embedding))::numeric similarity
    from gk.question_embeddings e1
    join gk.question_embeddings e2
      on e2.model=e1.model and e2.question_id>e1.question_id
    join gk.questions q1 on q1.question_id=e1.question_id and q1.active
    join gk.questions q2 on q2.question_id=e2.question_id and q2.active
    where e1.model=mdl
  ), eligible as (
    select p.*,
      row_number() over(partition by p.canonical_question_id order by p.similarity desc,p.candidate_question_id) rn
    from pairs p
    where p.similarity>=threshold
      and (
        lower(coalesce(p.subject_1,''))=lower(coalesce(p.subject_2,''))
        or p.similarity>=greatest(threshold,0.92)
      )
  ), chosen as (
    select * from eligible where rn<=per_q
  ), ins as (
    insert into gk.canonical_duplicate_review(
      review_key,canonical_fingerprint,canonical_question_id,candidate_question_id,
      review_status,reason,created_at,updated_at,detection_method,semantic_similarity,detector_model
    )
    select
      'hf:'||md5(mdl||'|'||c.canonical_question_id||'|'||c.candidate_question_id),
      coalesce(nullif(c.canonical_fingerprint,''),md5(c.canonical_question_id)),
      c.canonical_question_id,c.candidate_question_id,
      'NEEDS_REVIEW',
      'HF semantic candidate; cosine similarity='||round(c.similarity,4)::text,
      now(),now(),'hf_semantic',round(c.similarity,6),mdl
    from chosen c
    on conflict(review_key) do update set
      semantic_similarity=excluded.semantic_similarity,
      reason=excluded.reason,
      detector_model=excluded.detector_model,
      detection_method=excluded.detection_method,
      updated_at=now()
    where gk.canonical_duplicate_review.review_status='NEEDS_REVIEW'
    returning 1
  )
  select count(*) into inserted_count from ins;

  select count(*) into candidate_count
  from gk.canonical_duplicate_review
  where detection_method='hf_semantic' and detector_model=mdl;

  return jsonb_build_object(
    'ok',true,
    'model',mdl,
    'threshold',threshold,
    'candidateRows',candidate_count,
    'rowsTouched',inserted_count
  );
end
$$;

revoke execute on function public.gk_hf_refresh_duplicate_candidates(text,numeric,integer) from public, anon, authenticated;
grant execute on function public.gk_hf_refresh_duplicate_candidates(text,numeric,integer) to service_role;

create or replace function public.gk_get_hf_semantic_status(
  p_model text default 'sentence-transformers/all-MiniLM-L6-v2'
) returns jsonb
language plpgsql
stable
security definer
set search_path=pg_catalog,public,gk,auth
as $$
declare
  uid uuid:=auth.uid();
  mdl text:=btrim(coalesce(p_model,''));
  active_count integer;
  embedded_count integer;
  candidate_count integer;
  reviewed_count integer;
begin
  if uid is null then raise exception 'Authentication required'; end if;
  if mdl='' then raise exception 'Model required'; end if;

  select count(*) into active_count from gk.questions where active;
  select count(*) into embedded_count
  from gk.question_embeddings e
  join gk.questions q on q.question_id=e.question_id and q.active
  where e.model=mdl;
  select count(*) into candidate_count
  from gk.canonical_duplicate_review
  where detection_method='hf_semantic' and detector_model=mdl and review_status='NEEDS_REVIEW';
  select count(*) into reviewed_count
  from gk.canonical_duplicate_review
  where detection_method='hf_semantic' and detector_model=mdl and review_status<>'NEEDS_REVIEW';

  return jsonb_build_object(
    'model',mdl,
    'activeQuestions',active_count,
    'embeddedQuestions',embedded_count,
    'remainingQuestions',greatest(active_count-embedded_count,0),
    'pendingSemanticReviews',candidate_count,
    'reviewedSemanticPairs',reviewed_count,
    'runtimeIntegrated',false
  );
end
$$;

revoke execute on function public.gk_get_hf_semantic_status(text) from public, anon;
grant execute on function public.gk_get_hf_semantic_status(text) to authenticated;
