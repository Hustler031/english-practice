-- Learner-facing UI support for Targeted Mastery and Learning Insights.
-- This does not create a new mastery model. It exposes safe display labels and
-- an authenticated exact-question read path over the existing Targeted route.

create or replace function public.english_get_question_labels(p_question_ids text[])
returns jsonb
language sql
stable
security definer
set search_path to 'pg_catalog','public','english','auth'
as $$
with uid as (
  select auth.uid() id
), requested as (
  select x.question_id,x.ord
  from unnest(coalesce(p_question_ids,'{}'::text[])) with ordinality as x(question_id,ord)
  where nullif(trim(x.question_id),'') is not null
  order by x.ord
  limit 120
), rows as (
  select
    q.question_id,
    coalesce(
      nullif(trim(q.word),''),
      nullif(trim(c.name),''),
      nullif(trim(q.topic),''),
      nullif(left(regexp_replace(coalesce(q.question,''),'\s+',' ','g'),88),''),
      'English question'
    ) as display_name,
    nullif(trim(q.topic),'') as topic,
    nullif(trim(q.question_type),'') as question_type,
    m.concept_id,
    nullif(trim(c.name),'') as concept_name,
    requested.ord
  from uid
  join requested on true
  join english.questions q on q.question_id=requested.question_id
  left join english.question_concept_mappings m on m.question_id=q.question_id
  left join english.concepts c on c.concept_id=m.concept_id
  where q.active and english.question_visible_to_user(uid.id,q.question_id)
)
select case
  when (select id from uid) is null then jsonb_build_object('ok',false,'error','Authentication required','items','[]'::jsonb)
  else jsonb_build_object(
    'ok',true,
    'items',coalesce((select jsonb_agg(jsonb_build_object(
      'questionId',question_id,
      'displayName',display_name,
      'topic',topic,
      'questionType',question_type,
      'conceptId',concept_id,
      'conceptName',concept_name
    ) order by ord) from rows),'[]'::jsonb)
  )
end;
$$;

revoke all on function public.english_get_question_labels(text[]) from public,anon;
grant execute on function public.english_get_question_labels(text[]) to authenticated;

create or replace function public.english_get_targeted_question(p_question_id text)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'pg_catalog','public','english','auth'
as $$
declare
  uid uuid:=auth.uid();
  outv jsonb;
begin
  if uid is null then raise exception 'Authentication required'; end if;
  if nullif(trim(coalesce(p_question_id,'')),'') is null then return '[]'::jsonb; end if;

  select english.question_payload(uid,r.question_id)||jsonb_build_object(
    'learningRoute','targeted',
    'targetedKind',english.targeted_route_kind(r.metadata,r.origins),
    'targetedReason',r.last_route_reason,
    'sourceQuestionId',r.question_id,
    'conceptId',m.concept_id
  )
  into outv
  from english.learning_route_state r
  join english.questions q on q.question_id=r.question_id
    and q.active
    and english.question_visible_to_user(uid,q.question_id)
  left join english.question_concept_mappings m on m.question_id=r.question_id
  where r.user_id=uid
    and r.route='targeted'
    and r.question_id=p_question_id
  limit 1;

  return case when outv is null then '[]'::jsonb else jsonb_build_array(outv) end;
end $$;

revoke all on function public.english_get_targeted_question(text) from public,anon;
grant execute on function public.english_get_targeted_question(text) to authenticated;
