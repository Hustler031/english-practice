-- Daily cross-module satisfaction must represent successful learning evidence.
-- Grammar Today's fixed 20 should reopen with today's unattempted questions first.

create or replace function english.daily_satisfied_concepts(
  p_user_id uuid,
  p_batch_date date
)
returns table(concept_key text)
language sql
stable security definer
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
  and a.correct is true
  and a.attempted_at>=b.start_at
  and a.attempted_at<b.end_at;
$function$;

comment on function english.daily_satisfied_concepts(uuid,date) is
  'Concepts successfully answered outside Daily during the batch day. Incorrect attempts never suppress Daily review.';

create or replace function public.english_get_grammar_today()
returns jsonb
language plpgsql
stable security definer
set search_path to 'pg_catalog','public','english','auth'
as $function$
declare
  uid uuid:=auth.uid();
  v_day date:=(now() at time zone 'Asia/Kolkata')::date;
  v_items jsonb:='[]'::jsonb;
begin
  if uid is null then raise exception 'Authentication required'; end if;

  with bounds as (
    select (v_day::timestamp at time zone 'Asia/Kolkata') start_at,
           (((v_day+1)::timestamp) at time zone 'Asia/Kolkata') end_at
  ), attempted_today as materialized (
    select distinct a.question_id
    from english.attempts a
    cross join bounds b
    where a.user_id=uid
      and lower(btrim(coalesce(a.module,'')))='grammardaily'
      and a.attempted_at>=b.start_at
      and a.attempted_at<b.end_at
  )
  select coalesce(jsonb_agg(
    english.grammar_question_payload(uid,i.question_id)
      || jsonb_build_object(
        'slotNo',i.slot_no,
        'ruleKey',i.rule_key,
        'questionFamily',i.question_family,
        'requestedFamily',i.requested_family,
        'isNewVariant',i.is_new_variant,
        'ruleTitle',r.rule_title,
        'canonicalRule',r.canonical_rule,
        'commonTrap',coalesce(r.common_trap,''),
        'contrastWith',coalesce(r.contrast_with,''),
        'attemptedToday',a.question_id is not null
      )
    order by (a.question_id is not null),i.slot_no
  ),'[]'::jsonb)
  into v_items
  from english.grammar_daily_items i
  join english.grammar_rules r on r.rule_key=i.rule_key
  left join attempted_today a on a.question_id=i.question_id
  where i.batch_date=v_day;

  return jsonb_build_object(
    'ok',true,
    'date',v_day,
    'ready',jsonb_array_length(v_items)=20,
    'count',jsonb_array_length(v_items),
    'items',v_items
  );
end;
$function$;

comment on function public.english_get_grammar_today() is
  'Returns the fixed Grammar Today batch with questions not yet attempted in grammardaily today ordered first, preserving slot order within attempted/unattempted groups.';
