-- Keep Starred Revision representative of the learner's whole starred bank instead
-- of allowing source/question-id clustering to dominate a session.
-- Also remove repeated per-row Daily satisfaction scans from the learner read path,
-- and expose a tiny owner-scoped active-revision feed so quiz payload + overlays can
-- load in parallel rather than serially.

create or replace function english.starred_diversify_payload(p_rows jsonb)
returns jsonb
language sql
stable
security definer
set search_path to 'pg_catalog','english'
as $function$
with expanded as (
  select e.value j,e.ordinality ord,
         english.learning_category(coalesce(e.value->>'topic',e.value->>'category','')) category
  from jsonb_array_elements(coalesce(p_rows,'[]'::jsonb)) with ordinality e(value,ordinality)
), ranked as (
  select j,ord,category,
         row_number() over(partition by category order by ord) category_rank
  from expanded
)
select coalesce(jsonb_agg(j order by category_rank,ord),'[]'::jsonb)
from ranked;
$function$;

revoke execute on function english.starred_diversify_payload(jsonb) from public,anon,authenticated;
grant execute on function english.starred_diversify_payload(jsonb) to service_role;

create or replace function public.english_get_starred_batch(
  p_mode text default 'smart',
  p_count integer default 20,
  p_from_day integer default null,
  p_to_day integer default null
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','public','english','auth'
as $function$
declare
  uid uuid:=auth.uid();
  n integer:=greatest(1,least(50,coalesce(p_count,20)));
  raw jsonb;
begin
  if uid is null then raise exception 'Authentication required'; end if;
  raw:=public.english_get_starred_batch_core_20260830(
    p_mode,least(50,greatest(n,n*4)),p_from_day,p_to_day
  );
  if lower(btrim(coalesce(p_mode,'smart')))<> 'all' then
    raw:=english.concept_dedupe_payload(uid,raw,50);
  end if;
  raw:=english.starred_diversify_payload(raw);
  return english.rotate_fresh_batch(uid,'starredRevision',raw,n,90);
end
$function$;

create or replace function english.daily_satisfied_concepts(
  p_user_id uuid,
  p_batch_date date
)
returns table(concept_key text)
language sql
stable
security definer
set search_path to 'pg_catalog','english','auth'
as $function$
with bounds as (
  select (p_batch_date::timestamp at time zone 'Asia/Kolkata') start_at,
         ((((now() at time zone 'Asia/Kolkata')::date+1)::timestamp) at time zone 'Asia/Kolkata') end_at
)
select distinct coalesce(m.concept_id,a.question_id) concept_key
from english.attempts a
left join english.question_concept_mappings m on m.question_id=a.question_id
cross join bounds b
where a.user_id=p_user_id
  and lower(btrim(coalesce(a.module,'')))<>'daily'
  and a.attempted_at>=b.start_at
  and a.attempted_at<b.end_at;
$function$;

revoke execute on function english.daily_satisfied_concepts(uuid,date) from public,anon;
grant execute on function english.daily_satisfied_concepts(uuid,date) to authenticated,service_role;

create or replace function english.daily_satisfied_elsewhere(
  p_user_id uuid,
  p_question_id text,
  p_batch_date date
)
returns boolean
language sql
stable
security definer
set search_path to 'pg_catalog','english','auth'
as $function$
with target as (
  select coalesce(m.concept_id,q.question_id) concept_key
  from english.questions q
  left join english.question_concept_mappings m on m.question_id=q.question_id
  where q.question_id=p_question_id
)
select coalesce(exists(
  select 1 from target t
  join english.daily_satisfied_concepts(p_user_id,p_batch_date) s on s.concept_key=t.concept_key
),false);
$function$;

revoke execute on function english.daily_satisfied_elsewhere(uuid,text,date) from public,anon;
grant execute on function english.daily_satisfied_elsewhere(uuid,text,date) to authenticated,service_role;

create or replace function english.daily_effective_counts(
  p_user_id uuid,
  p_batch_date date,
  p_target integer default 120
)
returns table(total integer,completed integer,satisfied_elsewhere integer,remaining integer,raw_planned integer)
language sql
stable
security definer
set search_path to 'pg_catalog','english','auth'
as $function$
with sat as materialized (
  select concept_key from english.daily_satisfied_concepts(p_user_id,p_batch_date)
), base as (
  select d.question_id,d.sequence,d.status,
         lower(coalesce(d.status,''))='completed' is_completed,
         english.daily_reason(p_user_id,d.question_id,d.quiz_date) reason_now,
         case when lower(coalesce(d.status,''))='completed' then false else sc.concept_key is not null end satisfied
  from english.daily_current d
  left join english.question_concept_mappings m on m.question_id=d.question_id
  left join sat sc on sc.concept_key=coalesce(m.concept_id,d.question_id)
  where d.user_id=p_user_id and d.quiz_date=p_batch_date
), planned as (
  select b.*,
         row_number() over(order by case when b.is_completed then 0 else 1 end,b.sequence,b.question_id) slot_rank
  from base b
  where b.is_completed or b.reason_now<>'' or b.satisfied
), effective as (
  select * from planned where slot_rank<=greatest(1,least(120,coalesce(p_target,120)))
)
select
  count(*)::int,
  count(*) filter(where is_completed)::int,
  count(*) filter(where not is_completed and satisfied)::int,
  count(*) filter(where not is_completed and not satisfied and reason_now<>'')::int,
  (select count(*)::int from planned)
from effective;
$function$;

create or replace function english.current_daily_items(p_user_id uuid)
returns table(
  sequence integer,priority integer,reason text,quiz_date date,status text,
  question_id text,topic text,word text,question text,option_a text,option_b text,option_c text,option_d text,
  correct_key text,explanation text,subtopic text,question_type text,source_file text,source_page text,
  concept_id text,difficulty text,tip text,usage_note text,example_sentence text,memory_aid text,related_words text,
  source_url text,starred boolean,difficult boolean
)
language sql
stable
security definer
set search_path to 'pg_catalog','english','auth'
as $function$
with batch as (
  select min(quiz_date) quiz_date from english.daily_current where user_id=p_user_id
), sat as materialized (
  select s.concept_key from batch b cross join lateral english.daily_satisfied_concepts(p_user_id,b.quiz_date) s
  where b.quiz_date is not null
), base as (
  select d.sequence,d.priority,d.reason,d.quiz_date,d.status,
         q.question_id,q.topic,q.word,q.question,q.option_a,q.option_b,q.option_c,q.option_d,upper(q.correct) correct_key,
         q.explanation,q.subtopic,q.question_type,q.source_file,q.source_page,q.concept_id,q.difficulty,
         q.tip,q.usage_note,q.example_sentence,q.memory_aid,q.related_words,q.source_url,
         coalesce(s.last_marked,false) starred,coalesce(ds.difficult,false) difficult,
         lower(coalesce(d.status,''))='completed' is_completed,
         english.daily_reason(p_user_id,q.question_id,d.quiz_date) reason_now,
         case when lower(coalesce(d.status,''))='completed' then false else sc.concept_key is not null end satisfied
  from english.daily_current d
  join english.questions q on q.question_id=d.question_id
  left join english.question_concept_mappings m on m.question_id=q.question_id
  left join sat sc on sc.concept_key=coalesce(m.concept_id,q.question_id)
  left join english.question_state s on s.user_id=p_user_id and s.question_id=q.question_id
  left join english.difficult_state ds on ds.user_id=p_user_id and ds.question_id=q.question_id
  where d.user_id=p_user_id
    and q.active
    and not coalesce(s.mastered,false)
), planned as (
  select b.*,
         row_number() over(order by case when b.is_completed then 0 else 1 end,b.sequence,b.question_id) slot_rank
  from base b
  where b.is_completed or b.reason_now<>'' or b.satisfied
)
select sequence,priority,reason,quiz_date,status,
       question_id,topic,word,question,option_a,option_b,option_c,option_d,correct_key,
       explanation,subtopic,question_type,source_file,source_page,concept_id,difficulty,
       tip,usage_note,example_sentence,memory_aid,related_words,source_url,starred,difficult
from planned
where slot_rank<=120
  and (is_completed or (reason_now<>'' and not satisfied))
order by sequence;
$function$;

create or replace function english.ensure_daily(p_user_id uuid,p_target integer default 120)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','english','auth'
as $function$
declare
  v_today date:=(now() at time zone 'Asia/Kolkata')::date;
  v_batch date;
  v_pending integer:=0;
  v_effective integer:=0;
  v_created integer:=0;
  v_archived integer:=0;
  v_next date;
  c record;
begin
  select min(quiz_date) into v_batch from english.daily_current where user_id=p_user_id;
  if v_batch is null then
    v_batch:=v_today;
    v_created:=english.create_daily(p_user_id,v_batch,p_target);
  else
    select total,remaining into v_effective,v_pending from english.daily_effective_counts(p_user_id,v_batch,p_target);
    v_effective:=coalesce(v_effective,0);
    v_pending:=coalesce(v_pending,0);
    if v_batch<v_today and v_pending=0 then
      v_archived:=english.archive_daily(p_user_id,v_batch);
      v_next:=v_batch+1;
      v_batch:=v_next;
      v_created:=english.create_daily(p_user_id,v_batch,p_target);
    elsif v_batch=v_today and v_effective<greatest(1,least(120,coalesce(p_target,120))) then
      v_created:=english.repair_daily_shortfall(p_user_id,v_batch,p_target);
    end if;
  end if;

  select * into c from english.daily_effective_counts(p_user_id,v_batch,p_target);
  return jsonb_build_object(
    'ok',true,'batch_date',v_batch,'today',v_today,'pending_previous_day',(v_batch<v_today),
    'created',v_created,'archived',v_archived,'target_is_maximum',true,'target_guaranteed_when_eligible',true,
    'total',coalesce(c.total,0),'completed',coalesce(c.completed,0),
    'satisfied_elsewhere',coalesce(c.satisfied_elsewhere,0),
    'done',coalesce(c.completed,0)+coalesce(c.satisfied_elsewhere,0),
    'remaining',coalesce(c.remaining,0),'raw_planned',coalesce(c.raw_planned,0)
  );
end
$function$;

create or replace function public.english_get_active_question_revisions()
returns jsonb
language plpgsql
stable
security definer
set search_path to 'pg_catalog','public','english','auth'
as $function$
declare uid uuid:=auth.uid(); outv jsonb;
begin
  if uid is null then raise exception 'authentication required'; end if;
  select coalesce(jsonb_agg(jsonb_build_object(
    'questionId',r.question_id,'proposalId',r.proposal_id,'version',r.proposal_version,'payload',p.proposed_payload
  ) order by r.question_id),'[]'::jsonb)
  into outv
  from english.user_question_revisions r
  join english.question_revision_proposals p on p.proposal_id=r.proposal_id
  where r.user_id=uid and p.status='applied';
  return jsonb_build_object('ok',true,'revisions',outv);
end
$function$;

revoke execute on function public.english_get_active_question_revisions() from public,anon;
grant execute on function public.english_get_active_question_revisions() to authenticated,service_role;
