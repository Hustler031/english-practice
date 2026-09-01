-- English V2 asynchronous semantic concept refinement.
-- Normal learning paths do not wait on embeddings or AI.

create extension if not exists vector with schema extensions;
create extension if not exists pg_net with schema extensions;
create extension if not exists pg_cron;

alter table english.concepts add column if not exists embedding_vector extensions.vector(1536);
alter table english.concepts add column if not exists embedding_model text;
alter table english.concepts add column if not exists embedded_at timestamptz;
alter table english.question_concept_mappings add column if not exists embedding_vector extensions.vector(1536);
alter table english.question_concept_mappings add column if not exists embedded_at timestamptz;

create index if not exists english_concepts_embedding_hnsw
  on english.concepts using hnsw (embedding_vector extensions.vector_cosine_ops)
  where embedding_vector is not null;
create index if not exists english_qcm_embedding_hnsw
  on english.question_concept_mappings using hnsw (embedding_vector extensions.vector_cosine_ops)
  where embedding_vector is not null;
create index if not exists english_saved_embedding_hnsw
  on english.saved_concept_mappings using hnsw (embedding_vector extensions.vector_cosine_ops)
  where embedding_vector is not null;

create table if not exists english.semantic_queue (
  entity_type text not null check(entity_type in ('concept','question','saved')),
  entity_id text not null,
  user_id uuid references auth.users(id) on delete cascade,
  reason text not null default 'semantic_refresh',
  status text not null default 'queued' check(status in ('queued','processing','done','failed')),
  attempts integer not null default 0,
  next_attempt_at timestamptz,
  last_error text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  processed_at timestamptz,
  primary key(entity_type,entity_id)
);
create index if not exists english_semantic_queue_work_idx on english.semantic_queue(status,next_attempt_at,updated_at);
alter table english.semantic_queue enable row level security;

create table if not exists english.semantic_runtime_guard (
  singleton boolean primary key default true check(singleton),
  token text not null default gen_random_uuid()::text,
  created_at timestamptz not null default now(),
  rotated_at timestamptz not null default now()
);
alter table english.semantic_runtime_guard enable row level security;
insert into english.semantic_runtime_guard(singleton) values(true) on conflict(singleton) do nothing;

create table if not exists english.semantic_usage (
  id bigint generated always as identity primary key,
  model text not null,
  item_count integer not null default 0,
  input_tokens integer not null default 0,
  total_tokens integer not null default 0,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);
alter table english.semantic_usage enable row level security;

create or replace function english.sync_question_concept_mapping(p_question_id text) returns text
language plpgsql security definer set search_path=pg_catalog,english as $$
declare q english.questions%rowtype; cid text; fid text;
begin
  select * into q from english.questions where question_id=p_question_id;
  if not found or not coalesce(q.active,true) then return null; end if;
  cid:=coalesce(nullif(trim(q.concept_id),''),'C_'||md5(lower(trim(coalesce(q.topic,'English')||'|'||coalesce(q.subtopic,q.question_type,'Unclassified')||'|'||coalesce(q.word,'')))));
  fid:='F_'||md5(lower(trim(coalesce(q.topic,'English')||'|'||coalesce(q.subtopic,q.question_type,'Unclassified'))));
  insert into english.concepts(concept_id,domain,skill_family,name,description,confidence,exam_relevance,metadata)
  values(cid,'English',coalesce(nullif(trim(q.topic),''),'Unclassified'),
    coalesce(nullif(trim(q.subtopic),''),nullif(trim(q.word),''),nullif(trim(q.topic),''),'Unclassified concept'),nullif(trim(q.explanation),''),
    case when nullif(trim(q.concept_id),'') is not null then 'high' else 'medium' end,
    case when lower(coalesce(q.topic,'')) ~ '(grammar|vocab|phrasal|idiom|spelling|preposition|one word|synonym|antonym)' then 'high' else 'medium' end,
    jsonb_build_object('initial_source','english.questions','question_type',q.question_type))
  on conflict(concept_id) do update set updated_at=now();
  insert into english.question_concept_mappings(question_id,concept_id,family_id,mapping_confidence,mapping_method,review_status,relation_type,updated_at)
  values(q.question_id,cid,fid,case when nullif(trim(q.concept_id),'') is not null then .95 else .78 end,
    case when nullif(trim(q.concept_id),'') is not null then 'existing_concept_id' else 'deterministic_metadata' end,
    case when nullif(trim(q.concept_id),'') is not null then 'verified' else 'mapped' end,'primary',now())
  on conflict(question_id) do update set family_id=coalesce(english.question_concept_mappings.family_id,excluded.family_id),updated_at=now();
  if nullif(trim(q.concept_id),'') is null then update english.questions set concept_id=cid,updated_at=now()
    where question_id=q.question_id and (concept_id is null or trim(concept_id)=''); end if;
  return cid;
end $$;

create or replace function english.enqueue_semantic(p_entity_type text,p_entity_id text,p_user_id uuid default null,p_reason text default 'semantic_refresh') returns void
language plpgsql security definer set search_path=pg_catalog,english as $$
begin
  if p_entity_type not in ('concept','question','saved') or nullif(trim(p_entity_id),'') is null then return; end if;
  insert into english.semantic_queue(entity_type,entity_id,user_id,reason,status,attempts,next_attempt_at,last_error,updated_at,processed_at)
  values(p_entity_type,p_entity_id,p_user_id,coalesce(nullif(trim(p_reason),''),'semantic_refresh'),'queued',0,null,null,now(),null)
  on conflict(entity_type,entity_id) do update set user_id=coalesce(excluded.user_id,english.semantic_queue.user_id),reason=excluded.reason,
    status='queued',attempts=case when english.semantic_queue.status='failed' then 0 else english.semantic_queue.attempts end,
    next_attempt_at=null,last_error=null,updated_at=now(),processed_at=null;
end $$;

create or replace function english.on_concept_semantic_queue() returns trigger
language plpgsql security definer set search_path=pg_catalog,english as $$
begin
  if coalesce(new.active,true) then perform english.enqueue_semantic('concept',new.concept_id,null,
    case when tg_op='INSERT' then 'new_concept' else 'concept_content_changed' end); end if;
  return new;
end $$;

create or replace function english.on_question_semantic_queue() returns trigger
language plpgsql security definer set search_path=pg_catalog,english as $$
declare method text; conf numeric; cid text;
begin
  if coalesce(new.active,true) then
    cid:=english.sync_question_concept_mapping(new.question_id);
    select m.mapping_method,m.mapping_confidence into method,conf from english.question_concept_mappings m where m.question_id=new.question_id;
    if method='deterministic_metadata' or coalesce(conf,0)<.90 then
      perform english.enqueue_semantic('question',new.question_id,null,
        case when tg_op='INSERT' then 'new_question_uncertain_mapping' else 'question_content_changed_uncertain_mapping' end);
    else
      if cid is not null and exists(select 1 from english.concepts c where c.concept_id=cid and c.embedding_vector is null) then
        perform english.enqueue_semantic('concept',cid,null,'trusted_question_concept_needs_embedding');
      end if;
    end if;
  end if;
  return new;
end $$;

create or replace function english.on_saved_semantic_queue() returns trigger
language plpgsql security definer set search_path=pg_catalog,english as $$
begin
  if lower(coalesce(new.gpt_status,'')) in ('ready','complete','completed','done')
     and (tg_op='INSERT' or old.gpt_status is distinct from new.gpt_status or old.gpt_updated_at is distinct from new.gpt_updated_at
       or old.practice_question_id is distinct from new.practice_question_id) then
    perform english.sync_saved_concept(new.saved_id);
    perform english.enqueue_semantic('saved',new.saved_id,new.user_id,'saved_enrichment_ready');
  end if;
  return new;
end $$;

drop trigger if exists english_concept_semantic_queue on english.concepts;
create trigger english_concept_semantic_queue after insert or update of domain,skill_family,name,description,active on english.concepts
for each row execute function english.on_concept_semantic_queue();
drop trigger if exists english_question_semantic_queue on english.questions;
create trigger english_question_semantic_queue after insert or update of topic,word,question,explanation,subtopic,question_type,concept_id,active on english.questions
for each row execute function english.on_question_semantic_queue();
drop trigger if exists english_saved_semantic_queue on english.saved_items;
create trigger english_saved_semantic_queue after insert or update of gpt_status,gpt_updated_at,practice_question_id on english.saved_items
for each row execute function english.on_saved_semantic_queue();

create or replace function english.semantic_claim(p_token text,p_limit integer default 100)
returns table(entity_type text,entity_id text,user_id uuid)
language plpgsql security definer set search_path=pg_catalog,english as $$
begin
  if not exists(select 1 from english.semantic_runtime_guard g where g.singleton and g.token=p_token) then raise exception 'semantic worker unauthorized'; end if;
  return query with pick as (
    select q.entity_type,q.entity_id from english.semantic_queue q
    where q.status='queued' and (q.next_attempt_at is null or q.next_attempt_at<=now())
    order by case q.entity_type when 'concept' then 1 when 'question' then 2 else 3 end,q.updated_at,q.entity_id
    for update skip locked limit greatest(1,least(100,coalesce(p_limit,100)))
  ), upd as (
    update english.semantic_queue q set status='processing',attempts=q.attempts+1,updated_at=now()
    from pick p where q.entity_type=p.entity_type and q.entity_id=p.entity_id returning q.entity_type,q.entity_id,q.user_id
  ) select u.entity_type,u.entity_id,u.user_id from upd u;
end $$;

create or replace function english.semantic_candidates(p_embedding text,p_limit integer default 5,p_exclude_concept text default null)
returns table(concept_id text,name text,skill_family text,domain text,similarity numeric)
language sql stable security definer set search_path=pg_catalog,english,extensions as $$
select c.concept_id,c.name,c.skill_family,c.domain,round((1-(c.embedding_vector <=> p_embedding::extensions.vector))::numeric,6)
from english.concepts c where c.active and c.embedding_vector is not null and (p_exclude_concept is null or c.concept_id<>p_exclude_concept)
order by c.embedding_vector <=> p_embedding::extensions.vector limit greatest(1,least(20,coalesce(p_limit,5)));
$$;

create or replace function english.semantic_candidates_batch(p_items jsonb,p_limit integer default 5) returns jsonb
language sql stable security definer set search_path=pg_catalog,english,extensions as $$
with inputs as (
  select x->>'entity_id' entity_id,nullif(x->>'exclude_concept','') exclude_concept,(x->>'embedding')::extensions.vector embedding
  from jsonb_array_elements(coalesce(p_items,'[]'::jsonb)) x
), candidates as (
  select i.entity_id,coalesce((select jsonb_agg(jsonb_build_object('concept_id',z.concept_id,'name',z.name,'skill_family',z.skill_family,
    'domain',z.domain,'similarity',z.similarity) order by z.similarity desc) from (
      select c.concept_id,c.name,c.skill_family,c.domain,round((1-(c.embedding_vector <=> i.embedding))::numeric,6) similarity
      from english.concepts c where c.active and c.embedding_vector is not null and (i.exclude_concept is null or c.concept_id<>i.exclude_concept)
      order by c.embedding_vector <=> i.embedding limit greatest(1,least(20,coalesce(p_limit,5)))
    ) z),'[]'::jsonb) rows from inputs i
) select coalesce(jsonb_object_agg(entity_id,rows),'{}'::jsonb) from candidates;
$$;

create or replace function english.semantic_finish(p_token text,p_entity_type text,p_entity_id text,p_embedding text,p_model text,
  p_nearest_concept_id text default null,p_similarity numeric default null,p_candidates jsonb default '[]') returns void
language plpgsql security definer set search_path=pg_catalog,english,extensions as $$
declare current_cid text; current_method text; uid uuid;
begin
  if not exists(select 1 from english.semantic_runtime_guard g where g.singleton and g.token=p_token) then raise exception 'semantic worker unauthorized'; end if;
  if p_entity_type='concept' then
    update english.concepts set embedding_vector=p_embedding::extensions.vector,embedding_model=p_model,embedded_at=now(),
      metadata=jsonb_set(coalesce(metadata,'{}'::jsonb),'{semanticCandidates}',coalesce(p_candidates,'[]'::jsonb),true),updated_at=now()
    where concept_id=p_entity_id;
    if p_nearest_concept_id is not null and p_nearest_concept_id<>p_entity_id and coalesce(p_similarity,0)>=.94 then
      insert into english.concept_relationships(concept_id,related_concept_id,relationship,confidence,method,model)
      values(p_entity_id,p_nearest_concept_id,'duplicate_candidate',least(1,p_similarity),'openai_embedding',p_model)
      on conflict(concept_id,related_concept_id,relationship) do update set confidence=greatest(english.concept_relationships.confidence,excluded.confidence),method=excluded.method,model=excluded.model;
    end if;
  elsif p_entity_type='question' then
    perform english.sync_question_concept_mapping(p_entity_id);
    select m.concept_id,m.mapping_method into current_cid,current_method from english.question_concept_mappings m where m.question_id=p_entity_id;
    update english.question_concept_mappings set embedding_vector=p_embedding::extensions.vector,embedding=coalesce(p_candidates,'[]'::jsonb),model=p_model,embedded_at=now(),updated_at=now()
    where question_id=p_entity_id;
    if current_method='deterministic_metadata' and p_nearest_concept_id is not null and p_nearest_concept_id<>current_cid and coalesce(p_similarity,0)>=.88 then
      update english.question_concept_mappings set concept_id=p_nearest_concept_id,mapping_confidence=least(.98,p_similarity),mapping_method='openai_embedding',review_status='verified',updated_at=now()
      where question_id=p_entity_id;
      update english.questions set concept_id=p_nearest_concept_id,updated_at=now() where question_id=p_entity_id;
    elsif current_method='deterministic_metadata' and coalesce(p_similarity,0)>=.76 and coalesce(p_similarity,0)<.88 then
      update english.question_concept_mappings set mapping_confidence=greatest(mapping_confidence,coalesce(p_similarity,.76)),review_status='needs_review',updated_at=now()
      where question_id=p_entity_id;
    elsif current_method<>'deterministic_metadata' and p_nearest_concept_id=current_cid then
      update english.question_concept_mappings set mapping_confidence=greatest(mapping_confidence,least(.99,coalesce(p_similarity,mapping_confidence))),review_status='verified',updated_at=now()
      where question_id=p_entity_id;
    elsif current_cid is not null and p_nearest_concept_id is not null and current_cid<>p_nearest_concept_id and coalesce(p_similarity,0)>=.94 then
      insert into english.concept_relationships(concept_id,related_concept_id,relationship,confidence,method,model)
      values(current_cid,p_nearest_concept_id,'duplicate_candidate',least(1,p_similarity),'openai_embedding',p_model)
      on conflict(concept_id,related_concept_id,relationship) do update set confidence=greatest(english.concept_relationships.confidence,excluded.confidence),method=excluded.method,model=excluded.model;
    end if;
  elsif p_entity_type='saved' then
    select s.user_id into uid from english.saved_items s where s.saved_id=p_entity_id; if uid is null then raise exception 'saved item not found'; end if;
    perform english.sync_saved_concept(p_entity_id);
    update english.saved_concept_mappings set embedding_vector=p_embedding::extensions.vector,model=p_model,embedded_at=now(),updated_at=now() where saved_id=p_entity_id;
    if p_nearest_concept_id is not null and coalesce(p_similarity,0)>=.78 then
      update english.saved_concept_mappings set concept_id=p_nearest_concept_id,mapping_confidence=least(.98,p_similarity),mapping_method='openai_embedding',model=p_model,embedded_at=now(),updated_at=now()
      where saved_id=p_entity_id;
    end if;
  else raise exception 'unknown semantic entity type'; end if;
  update english.semantic_queue set status='done',last_error=null,next_attempt_at=null,processed_at=now(),updated_at=now()
  where entity_type=p_entity_type and entity_id=p_entity_id;
end $$;

create or replace function english.semantic_finish_batch(p_token text,p_items jsonb) returns integer
language plpgsql security definer set search_path=pg_catalog,english as $$
declare x jsonb; n integer:=0;
begin
  if not exists(select 1 from english.semantic_runtime_guard g where g.singleton and g.token=p_token) then raise exception 'semantic worker unauthorized'; end if;
  if jsonb_typeof(coalesce(p_items,'[]'::jsonb))<>'array' then raise exception 'items must be an array'; end if;
  for x in select value from jsonb_array_elements(p_items) value loop
    perform english.semantic_finish(p_token,x->>'entity_type',x->>'entity_id',x->>'embedding',coalesce(nullif(x->>'model',''),'text-embedding-3-small'),
      nullif(x->>'nearest_concept_id',''),nullif(x->>'similarity','')::numeric,coalesce(x->'candidates','[]'::jsonb)); n:=n+1;
  end loop; return n;
end $$;

create or replace function english.semantic_fail(p_token text,p_entity_type text,p_entity_id text,p_error text) returns void
language plpgsql security definer set search_path=pg_catalog,english as $$
begin
  if not exists(select 1 from english.semantic_runtime_guard g where g.singleton and g.token=p_token) then raise exception 'semantic worker unauthorized'; end if;
  update english.semantic_queue set status=case when attempts>=5 then 'failed' else 'queued' end,
    next_attempt_at=case when attempts>=5 then null else now()+make_interval(mins=>least(60,greatest(1,attempts*3))) end,
    last_error=left(coalesce(p_error,'unknown semantic error'),1000),updated_at=now()
  where entity_type=p_entity_type and entity_id=p_entity_id;
end $$;

create or replace function english.semantic_fail_batch(p_token text,p_items jsonb) returns integer
language plpgsql security definer set search_path=pg_catalog,english as $$
declare x jsonb; n integer:=0;
begin
  if not exists(select 1 from english.semantic_runtime_guard g where g.singleton and g.token=p_token) then raise exception 'semantic worker unauthorized'; end if;
  for x in select value from jsonb_array_elements(coalesce(p_items,'[]'::jsonb)) value loop
    perform english.semantic_fail(p_token,x->>'entity_type',x->>'entity_id',coalesce(x->>'error','semantic batch failed')); n:=n+1;
  end loop; return n;
end $$;

create or replace function english.semantic_log_usage(p_token text,p_model text,p_item_count integer,p_usage jsonb default '{}',p_metadata jsonb default '{}') returns void
language plpgsql security definer set search_path=pg_catalog,english as $$
begin
  if not exists(select 1 from english.semantic_runtime_guard g where g.singleton and g.token=p_token) then raise exception 'semantic worker unauthorized'; end if;
  insert into english.semantic_usage(model,item_count,input_tokens,total_tokens,metadata)
  values(coalesce(nullif(p_model,''),'text-embedding-3-small'),greatest(0,coalesce(p_item_count,0)),
    greatest(0,coalesce((p_usage->>'prompt_tokens')::int,(p_usage->>'input_tokens')::int,0)),
    greatest(0,coalesce((p_usage->>'total_tokens')::int,(p_usage->>'prompt_tokens')::int,(p_usage->>'input_tokens')::int,0)),coalesce(p_metadata,'{}'::jsonb));
end $$;

create or replace function public.english_semantic_claim(p_token text,p_limit integer default 100)
returns table(entity_type text,entity_id text,user_id uuid)
language sql security definer set search_path=pg_catalog,english as $$ select * from english.semantic_claim(p_token,p_limit); $$;

create or replace function public.english_semantic_payload_batch(p_token text,p_items jsonb) returns jsonb
language plpgsql stable security definer set search_path=pg_catalog,english as $$
declare outv jsonb;
begin
  if not exists(select 1 from english.semantic_runtime_guard g where g.singleton and g.token=p_token) then raise exception 'semantic worker unauthorized'; end if;
  with req as (select x->>'entity_type' entity_type,x->>'entity_id' entity_id from jsonb_array_elements(coalesce(p_items,'[]'::jsonb)) x), rows as (
    select r.entity_type,r.entity_id,case r.entity_type
      when 'concept' then (select jsonb_build_object('concept_id',c.concept_id,'domain',c.domain,'skill_family',c.skill_family,'name',c.name,'description',c.description,'current_concept',c.concept_id) from english.concepts c where c.concept_id=r.entity_id)
      when 'question' then (select jsonb_build_object('question_id',q.question_id,'topic',q.topic,'subtopic',q.subtopic,'word',q.word,'question_type',q.question_type,'question',q.question,'explanation',q.explanation,
        'current_concept',m.concept_id,'mapping_method',m.mapping_method,'mapping_confidence',m.mapping_confidence) from english.questions q left join english.question_concept_mappings m on m.question_id=q.question_id where q.question_id=r.entity_id)
      when 'saved' then (select jsonb_build_object('saved_id',s.saved_id,'word',s.word,'meaning',s.meaning,'context',s.context,'part_of_speech',s.part_of_speech,'synonyms',s.synonyms,'antonyms',s.antonyms,
        'example',s.example,'explanation',s.explanation,'question',s.question,'current_concept',m.concept_id) from english.saved_items s left join english.saved_concept_mappings m on m.saved_id=s.saved_id where s.saved_id=r.entity_id)
    end payload from req r
  ) select coalesce(jsonb_agg(jsonb_build_object('entity_type',entity_type,'entity_id',entity_id,'payload',payload)),'[]'::jsonb) into outv from rows;
  return outv;
end $$;

create or replace function public.english_semantic_candidates_batch(p_token text,p_items jsonb,p_limit integer default 5) returns jsonb
language plpgsql stable security definer set search_path=pg_catalog,english as $$
begin
  if not exists(select 1 from english.semantic_runtime_guard g where g.singleton and g.token=p_token) then raise exception 'semantic worker unauthorized'; end if;
  return english.semantic_candidates_batch(p_items,p_limit);
end $$;
create or replace function public.english_semantic_finish_batch(p_token text,p_items jsonb) returns integer
language sql security definer set search_path=pg_catalog,english as $$ select english.semantic_finish_batch(p_token,p_items); $$;
create or replace function public.english_semantic_fail_batch(p_token text,p_items jsonb) returns integer
language sql security definer set search_path=pg_catalog,english as $$ select english.semantic_fail_batch(p_token,p_items); $$;
create or replace function public.english_semantic_log_usage(p_token text,p_model text,p_item_count integer,p_usage jsonb default '{}',p_metadata jsonb default '{}') returns void
language sql security definer set search_path=pg_catalog,english as $$ select english.semantic_log_usage(p_token,p_model,p_item_count,p_usage,p_metadata); $$;

revoke all on function public.english_semantic_claim(text,integer) from public,anon,authenticated;
revoke all on function public.english_semantic_payload_batch(text,jsonb) from public,anon,authenticated;
revoke all on function public.english_semantic_candidates_batch(text,jsonb,integer) from public,anon,authenticated;
revoke all on function public.english_semantic_finish_batch(text,jsonb) from public,anon,authenticated;
revoke all on function public.english_semantic_fail_batch(text,jsonb) from public,anon,authenticated;
revoke all on function public.english_semantic_log_usage(text,text,integer,jsonb,jsonb) from public,anon,authenticated;
grant execute on function public.english_semantic_claim(text,integer) to service_role;
grant execute on function public.english_semantic_payload_batch(text,jsonb) to service_role;
grant execute on function public.english_semantic_candidates_batch(text,jsonb,integer) to service_role;
grant execute on function public.english_semantic_finish_batch(text,jsonb) to service_role;
grant execute on function public.english_semantic_fail_batch(text,jsonb) to service_role;
grant execute on function public.english_semantic_log_usage(text,text,integer,jsonb,jsonb) to service_role;

create or replace function public.english_get_semantic_status() returns jsonb
language sql stable security definer set search_path=pg_catalog,english,auth as $$
select case when auth.uid() is null then jsonb_build_object('ok',false,'error','Authentication required') else jsonb_build_object(
  'ok',true,'queued',(select count(*) from english.semantic_queue where status='queued'),
  'processing',(select count(*) from english.semantic_queue where status='processing'),
  'done',(select count(*) from english.semantic_queue where status='done'),
  'failed',(select count(*) from english.semantic_queue where status='failed'),
  'concept_embeddings',(select count(*) from english.concepts where embedding_vector is not null),
  'question_embeddings',(select count(*) from english.question_concept_mappings where embedding_vector is not null),
  'saved_embeddings',(select count(*) from english.saved_concept_mappings where embedding_vector is not null)) end;
$$;
revoke all on function public.english_get_semantic_status() from public,anon;
grant execute on function public.english_get_semantic_status() to authenticated,service_role;

create or replace function english.kick_semantic_worker(p_limit integer default 100) returns bigint
language plpgsql security definer set search_path=pg_catalog,english,net as $$
declare v_token text; v_id bigint;
begin
  update english.semantic_queue set status='queued',next_attempt_at=null,last_error='stale semantic processing recovered',updated_at=now()
  where status='processing' and updated_at<now()-interval '3 minutes';
  select token into v_token from english.semantic_runtime_guard where singleton;
  if v_token is null then raise exception 'semantic runtime guard missing'; end if;
  select net.http_post(url:='https://hytehindbmjdwcfptsic.supabase.co/functions/v1/english-concept-semantic',
    body:=jsonb_build_object('limit',greatest(1,least(100,coalesce(p_limit,100)))),params:='{}'::jsonb,
    headers:=jsonb_build_object('Content-Type','application/json','x-english-semantic-token',v_token),timeout_milliseconds:=55000) into v_id;
  return v_id;
end $$;

-- Initial scope: concepts always get semantic identity; only uncertain questions need question embeddings.
insert into english.semantic_queue(entity_type,entity_id,reason,status)
select 'concept',c.concept_id,'initial_concept_embedding','queued' from english.concepts c where c.active and c.embedding_vector is null
on conflict(entity_type,entity_id) do nothing;

insert into english.semantic_queue(entity_type,entity_id,reason,status)
select 'question',m.question_id,'initial_uncertain_question_mapping','queued'
from english.question_concept_mappings m join english.questions q on q.question_id=m.question_id
where q.active and (m.mapping_method='deterministic_metadata' or m.mapping_confidence<.90)
on conflict(entity_type,entity_id) do nothing;

insert into english.semantic_queue(entity_type,entity_id,reason,status,processed_at)
select 'question',m.question_id,'trusted_explicit_mapping_no_embedding_needed','done',now()
from english.question_concept_mappings m join english.questions q on q.question_id=m.question_id
where q.active and m.mapping_method<>'deterministic_metadata' and m.mapping_confidence>=.90
on conflict(entity_type,entity_id) do update set status=case when english.semantic_queue.status='queued' then 'done' else english.semantic_queue.status end,
  reason=excluded.reason,processed_at=coalesce(english.semantic_queue.processed_at,excluded.processed_at),updated_at=now();

insert into english.semantic_queue(entity_type,entity_id,user_id,reason,status)
select 'saved',s.saved_id,s.user_id,'initial_saved_semantic_mapping','queued'
from english.saved_items s where s.active and lower(coalesce(s.gpt_status,'')) in ('ready','complete','completed','done')
on conflict(entity_type,entity_id) do nothing;

-- Keep the worker conservative: one known-safe 100-item batch each minute.
do $$ begin
  if exists(select 1 from cron.job where jobname='english-semantic-refinement') then perform cron.unschedule('english-semantic-refinement'); end if;
  perform cron.schedule('english-semantic-refinement','* * * * *','select english.kick_semantic_worker(100);');
end $$;
