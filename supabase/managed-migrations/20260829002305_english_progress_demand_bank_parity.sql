create table if not exists english.question_origins (
  question_id text primary key references english.questions(question_id) on delete cascade,
  origin_kind text not null check (origin_kind in ('core','saved_generated','hindu_generated','demand_generated','other_generated')),
  origin_ref text,
  created_at timestamptz not null default now()
);

insert into english.question_origins(question_id,origin_kind,origin_ref,created_at)
select q.question_id,
  case
    when q.question_id ~* '^MYWORD_' or lower(coalesce(q.source_id,q.source_file,'')) like '%my_saved_words%' or lower(coalesce(q.source_id,q.source_file,'')) like '%my saved words%' then 'saved_generated'
    when q.question_id ~* '^HV20[0-9]{6}_' or lower(coalesce(q.topic,'')) like '%the hindu%' or lower(coalesce(q.source_id,q.source_file,'')) like '%the hindu daily%' or lower(coalesce(q.source_id,q.source_file,'')) like '%daily news vocabulary%' then 'hindu_generated'
    else 'core'
  end,
  coalesce(nullif(q.source_id,''),nullif(q.source_file,'')),
  coalesce(q.created_at,now())
from english.questions q
on conflict (question_id) do nothing;

alter table english.question_origins enable row level security;
drop policy if exists english_question_origins_authenticated_read on english.question_origins;
create policy english_question_origins_authenticated_read on english.question_origins for select to authenticated using (true);
revoke insert,update,delete on english.question_origins from anon,authenticated;
grant select on english.question_origins to authenticated;

alter table english.practice_sets add column if not exists source_origin text;
alter table english.practice_sets add column if not exists prompt_ref text;
alter table english.practice_sets add column if not exists category_tag text;
alter table english.practice_sets add column if not exists topic_tag text;
alter table english.practice_sets add column if not exists owner_user_id uuid references auth.users(id) on delete cascade;

create table if not exists english.practice_set_state (
  user_id uuid not null references auth.users(id) on delete cascade,
  set_id text not null references english.practice_sets(set_id) on delete cascade,
  resume_index integer not null default 0 check (resume_index >= 0),
  completed boolean not null default false,
  completed_at timestamptz,
  pinned boolean not null default false,
  last_opened_at timestamptz,
  updated_at timestamptz not null default now(),
  primary key(user_id,set_id)
);
alter table english.practice_set_state enable row level security;
drop policy if exists english_practice_set_state_select_own on english.practice_set_state;
create policy english_practice_set_state_select_own on english.practice_set_state for select to authenticated using (user_id=auth.uid());
revoke insert,update,delete on english.practice_set_state from anon,authenticated;
grant select on english.practice_set_state to authenticated;

create or replace function public.english_set_demand_state(
  p_set_id text,
  p_resume_index integer default null,
  p_completed boolean default null,
  p_pinned boolean default null
) returns jsonb
language plpgsql security definer
set search_path='pg_catalog','public','english','auth'
as $$
declare uid uuid:=auth.uid(); v_id text:=btrim(coalesce(p_set_id,'')); out jsonb;
begin
  if uid is null then raise exception 'Authentication required'; end if;
  if v_id='' or not exists(select 1 from english.practice_sets s where s.set_id=v_id and s.active and (s.owner_user_id is null or s.owner_user_id=uid)) then raise exception 'Demand set not found'; end if;
  insert into english.practice_set_state(user_id,set_id,resume_index,completed,completed_at,pinned,last_opened_at,updated_at)
  values(uid,v_id,greatest(0,coalesce(p_resume_index,0)),coalesce(p_completed,false),case when coalesce(p_completed,false) then now() end,coalesce(p_pinned,false),now(),now())
  on conflict(user_id,set_id) do update set
    resume_index=case when p_resume_index is null then english.practice_set_state.resume_index else greatest(0,p_resume_index) end,
    completed=coalesce(p_completed,english.practice_set_state.completed),
    completed_at=case when p_completed=true then now() when p_completed=false then null else english.practice_set_state.completed_at end,
    pinned=coalesce(p_pinned,english.practice_set_state.pinned),
    last_opened_at=now(),updated_at=now();
  select jsonb_build_object('ok',true,'setId',s.set_id,'resumeIndex',s.resume_index,'completed',s.completed,'pinned',s.pinned,'updatedAt',s.updated_at) into out
  from english.practice_set_state s where s.user_id=uid and s.set_id=v_id;
  return out;
end $$;
grant execute on function public.english_set_demand_state(text,integer,boolean,boolean) to authenticated;

create or replace function public.english_get_demand_sets() returns jsonb
language sql stable security definer
set search_path='pg_catalog','public','english','auth'
as $$
with sets as (
  select ps.set_id,ps.name,ps.description,ps.created_at,ps.source_origin,ps.prompt_ref,ps.category_tag,ps.topic_tag,
    count(i.question_id)::int count,
    count(*) filter(where coalesce(qs.status,'New') in ('Persistent Weak','Weak','Fragile') or coalesce(qs.attempts,0)>0)::int weak_started,
    coalesce(st.resume_index,0)::int resume_index,coalesce(st.completed,false) completed,coalesce(st.pinned,false) pinned,st.last_opened_at,st.completed_at
  from english.practice_sets ps
  left join english.practice_set_items i on i.set_id=ps.set_id
  left join english.question_state qs on qs.user_id=auth.uid() and qs.question_id=i.question_id
  left join english.practice_set_state st on st.user_id=auth.uid() and st.set_id=ps.set_id
  where auth.uid() is not null and ps.active and (ps.owner_user_id is null or ps.owner_user_id=auth.uid())
  group by ps.set_id,ps.name,ps.description,ps.created_at,ps.source_origin,ps.prompt_ref,ps.category_tag,ps.topic_tag,st.resume_index,st.completed,st.pinned,st.last_opened_at,st.completed_at
)
select coalesce(jsonb_agg(jsonb_build_object(
  'id',set_id,'name',name,'count',count,'weakStarted',weak_started,'notes',description,
  'createdAt',created_at,'sourceOrigin',source_origin,'promptRef',prompt_ref,'categoryTag',category_tag,'topicTag',topic_tag,
  'resumeIndex',resume_index,'completed',completed,'pinned',pinned,'lastOpenedAt',last_opened_at,'completedAt',completed_at
) order by pinned desc,coalesce(last_opened_at,created_at) desc,set_id),'[]'::jsonb) from sets;
$$;
grant execute on function public.english_get_demand_sets() to authenticated;

create or replace function public.english_get_bank_coverage_hub() returns jsonb
language sql stable security definer
set search_path='pg_catalog','public','english','auth'
as $$
with bank as (
  select q.question_id,english.learning_category(q.topic) id,q.topic,
    coalesce(s.attempts,0)>0 exposed
  from english.questions q
  left join english.question_state s on s.user_id=auth.uid() and s.question_id=q.question_id
  where auth.uid() is not null and english.is_genuine_bank_question(q)
), g as (
  select id,min(topic) topic,count(*)::int total,count(*) filter(where exposed)::int exposed,count(*) filter(where not exposed)::int available
  from bank group by id
), named as (
  select *,case id when 'VOC' then 'Vocabulary' when 'IDIOM' then 'Idioms & Phrases' when 'PHRASAL' then 'Phrasal Verbs' when 'OWS' then 'One Word Substitution' when 'FIELDS_OF_STUDY' then 'Fields of Study' when 'FIXED_PREPOSITION' then 'Fixed Preposition' when 'SYN_ANT' then 'Synonyms & Antonyms' when 'CONFUSED' then 'Confused Words' when 'SPELLING' then 'Spelling' when 'GRAMMAR' then 'Grammar' when 'ERROR' then 'Error Detection' when 'SENT_IMP' then 'Sentence Improvement' when 'FILL' then 'Fill in the Blanks' when 'CLOZE' then 'Cloze Test' when 'PARA' then 'Para Jumbles' when 'RC' then 'Reading Comprehension' else coalesce(topic,'Other') end name
  from g
), totals as (select count(*)::int total,count(*) filter(where exposed)::int exposed from bank)
select jsonb_build_object(
  'total',(select total from totals),'exposed',(select exposed from totals),
  'coverage',case when (select total from totals)>0 then round((select exposed from totals)*100.0/(select total from totals),1) else 0 end,
  'complete',(select total=exposed from totals),
  'categories',coalesce((select jsonb_agg(jsonb_build_object('id',id,'name',name,'total',total,'exposed',exposed,'available',least(10,available),'unseen',available,'coverage',case when total>0 then round(exposed*100.0/total,1) else 0 end,'complete',available=0) order by total desc,name) from named),'[]'::jsonb)
);
$$;
grant execute on function public.english_get_bank_coverage_hub() to authenticated;

create or replace function public.english_get_bank_coverage_batch(p_category text,p_count integer default 10) returns jsonb
language plpgsql stable security definer
set search_path='pg_catalog','public','english','auth'
as $$
declare uid uuid:=auth.uid(); v_cat text:=upper(btrim(coalesce(p_category,''))); v_n integer:=greatest(1,least(10,coalesce(p_count,10))); out jsonb;
begin
  if uid is null then raise exception 'Authentication required'; end if;
  with c as (
    select q.question_id,row_number() over(order by q.question_id)::int ord
    from english.questions q
    left join english.question_state s on s.user_id=uid and s.question_id=q.question_id
    where english.is_genuine_bank_question(q) and english.learning_category(q.topic)=v_cat and coalesce(s.attempts,0)=0 and not coalesce(s.mastered,false)
    order by q.question_id limit v_n
  ) select coalesce(jsonb_agg(english.question_payload(uid,c.question_id) order by c.ord),'[]'::jsonb) into out from c;
  return out;
end $$;
grant execute on function public.english_get_bank_coverage_batch(text,integer) to authenticated;

create or replace function public.english_get_learning_progress() returns jsonb
language sql stable security definer
set search_path='pg_catalog','public','english','auth'
as $$
with bank as (
  select q.question_id,q.topic,q.concept_id,english.learning_category(q.topic) category_id
  from english.questions q
  left join english.question_state s on s.user_id=auth.uid() and s.question_id=q.question_id
  where auth.uid() is not null and english.is_genuine_bank_question(q) and (not coalesce(s.mastered,false) or coalesce(s.attempts,0)>0)
), a0 as (
  select a.*, (a.attempted_at at time zone 'Asia/Kolkata')::date study_date,
    row_number() over(partition by a.question_id order by a.attempted_at,a.source_row nulls last,a.created_at,a.attempt_id) overall_rn,
    row_number() over(partition by a.question_id,(a.attempted_at at time zone 'Asia/Kolkata')::date order by a.attempted_at,a.source_row nulls last,a.created_at,a.attempt_id) day_rn
  from english.attempts a join bank b on b.question_id=a.question_id where a.user_id=auth.uid()
), cp as (
  select a0.*,row_number() over(partition by question_id order by study_date,attempted_at,source_row nulls last,created_at,attempt_id) cp_rn from a0 where day_rn=1
), perq as (
  select b.question_id,b.category_id,b.concept_id,
    count(a0.attempt_id)::int attempts,
    coalesce(bool_or(a0.overall_rn=1 and a0.correct),false) first_correct,
    count(cp.attempt_id) filter(where cp.cp_rn>1)::int retention_attempts,
    count(cp.attempt_id) filter(where cp.cp_rn>1 and cp.correct)::int retention_correct,
    count(a0.attempt_id) filter(where a0.day_rn>1)::int after_attempts,
    count(a0.attempt_id) filter(where a0.day_rn>1 and a0.correct)::int after_correct,
    coalesce(s.status,'New') state,coalesce(s.mastered,false) manual_mastered
  from bank b left join a0 on a0.question_id=b.question_id left join cp on cp.attempt_id=a0.attempt_id
  left join english.question_state s on s.user_id=auth.uid() and s.question_id=b.question_id
  group by b.question_id,b.category_id,b.concept_id,s.status,s.mastered
), metrics as (
  select category_id,
    count(*)::int total,count(*) filter(where attempts>0)::int exposed,
    count(*) filter(where attempts>0)::int first_n,count(*) filter(where attempts>0 and first_correct)::int first_c,
    sum(retention_attempts)::int ret_n,sum(retention_correct)::int ret_c,sum(after_attempts)::int after_n,sum(after_correct)::int after_c,
    count(*) filter(where state in ('Persistent Weak','Weak','Fragile'))::int weak,
    count(distinct case when state in ('Persistent Weak','Weak') and attempts>0 then coalesce(nullif(concept_id,''),'Q:'||question_id) end)::int weak_concepts,
    count(*) filter(where state='Persistent Weak')::int persistent_weak,
    count(*) filter(where state='Proven Mastered')::int mastered
  from perq group by grouping sets((category_id),())
), composition as (
  select english.learning_category(q.topic) category_id,
    count(*)::int total_active,
    count(*) filter(where coalesce(o.origin_kind,'core')='core')::int core,
    count(*) filter(where coalesce(o.origin_kind,'core') in ('saved_generated','hindu_generated','other_generated'))::int added,
    count(*) filter(where coalesce(o.origin_kind,'core')='demand_generated')::int demand
  from english.questions q left join english.question_origins o on o.question_id=q.question_id where q.active group by grouping sets((english.learning_category(q.topic)),())
), cats as (
  select m.category_id,m.total,m.exposed,m.first_n,m.first_c,m.ret_n,m.ret_c,m.after_n,m.after_c,m.weak,m.weak_concepts,m.persistent_weak,m.mastered,c.total_active,c.core,c.added,c.demand,
    case m.category_id when 'VOC' then 'Vocabulary' when 'IDIOM' then 'Idioms & Phrases' when 'PHRASAL' then 'Phrasal Verbs' when 'OWS' then 'One Word Substitution' when 'FIELDS_OF_STUDY' then 'Fields of Study' when 'FIXED_PREPOSITION' then 'Fixed Preposition' when 'SYN_ANT' then 'Synonyms & Antonyms' when 'CONFUSED' then 'Confused Words' when 'SPELLING' then 'Spelling' when 'GRAMMAR' then 'Grammar' when 'ERROR' then 'Error Detection' when 'SENT_IMP' then 'Sentence Improvement' when 'FILL' then 'Fill in the Blanks' when 'CLOZE' then 'Cloze Test' when 'PARA' then 'Para Jumbles' when 'RC' then 'Reading Comprehension' else coalesce(m.category_id,'Overall') end name
  from metrics m left join composition c on c.category_id is not distinct from m.category_id
), totalrow as (select * from cats where category_id is null), active_comp as (select * from composition where category_id is null)
select jsonb_build_object(
  'schemaVersion',2,
  'bankExposed',case when t.total>0 then round(t.exposed*100.0/t.total,1) else 0 end,
  'exposed',t.exposed,'total',t.total,'left',greatest(0,t.total-t.exposed),
  'firstAttemptAccuracy',case when t.first_n>0 then round(t.first_c*100.0/t.first_n,1) else 0 end,
  'afterReviewAccuracy',case when t.after_n>0 then round(t.after_c*100.0/t.after_n,1) else 0 end,
  'retentionAccuracy',case when t.ret_n>0 then round(t.ret_c*100.0/t.ret_n,1) else 0 end,
  'weakCount',t.weak,'weakConcepts',t.weak_concepts,'persistentWeakCount',t.persistent_weak,'masteredCount',t.mastered,
  'composition',jsonb_build_object('coreBank',ac.core,'addedGenerated',ac.added,'demandCreated',ac.demand,'totalActive',ac.total_active),
  'categories',coalesce((select jsonb_agg(jsonb_build_object(
    'id',c.category_id,'name',c.name,'total',c.total,'exposed',c.exposed,'coveragePercent',case when c.total>0 then round(c.exposed*100.0/c.total,1) else 0 end,
    'firstAttemptAccuracy',case when c.first_n>0 then round(c.first_c*100.0/c.first_n,1) else 0 end,
    'retentionAccuracy',case when c.ret_n>0 then round(c.ret_c*100.0/c.ret_n,1) else 0 end,
    'weak',c.weak,'weakConcepts',c.weak_concepts,'persistentWeak',c.persistent_weak,'mastered',c.mastered,
    'core',c.core,'added',c.added,'demand',c.demand,'totalActive',c.total_active
  ) order by c.total desc,c.name) from cats c where c.category_id is not null),'[]'::jsonb)
) from totalrow t cross join active_comp ac;
$$;
grant execute on function public.english_get_learning_progress() to authenticated;
