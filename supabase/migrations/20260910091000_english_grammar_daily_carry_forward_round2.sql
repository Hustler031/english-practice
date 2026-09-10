-- ENGLISH V2 — Grammar Daily carry-forward, completion and focused Round 2
-- Batch identity is encoded in new Grammar Daily attempt modules as grammardaily:YYYY-MM-DD.
-- Legacy grammardaily attempts remain recognized by their Asia/Kolkata attempt date.

create or replace function english.grammar_daily_batch_attempts(
  p_user_id uuid,
  p_batch_date date
)
returns table(
  question_id text,
  attempt_id text,
  correct boolean,
  attempted_at timestamptz,
  guessed boolean
)
language sql
stable
security definer
set search_path to 'pg_catalog','english'
as $function$
with ranked as (
  select
    a.question_id,
    a.attempt_id,
    coalesce(a.correct,false) correct,
    a.attempted_at,
    row_number() over(
      partition by a.question_id
      order by a.attempted_at desc,a.created_at desc,a.attempt_id desc
    ) rn
  from english.attempts a
  where a.user_id=p_user_id
    and (
      lower(btrim(coalesce(a.module,'')))='grammardaily:'||p_batch_date::text
      or (
        lower(btrim(coalesce(a.module,'')))='grammardaily'
        and (a.attempted_at at time zone 'Asia/Kolkata')::date=p_batch_date
      )
    )
), latest as (
  select * from ranked where rn=1
)
select
  l.question_id,
  l.attempt_id,
  l.correct,
  l.attempted_at,
  exists(
    select 1
    from english.learner_confidence_signals s
    where s.user_id=p_user_id
      and s.question_id=l.question_id
      and s.signal='guessed'
      and s.attempt_id=l.attempt_id
  ) guessed
from latest l
$function$;

create or replace function english.grammar_daily_progress(
  p_user_id uuid,
  p_batch_date date
)
returns table(
  total integer,
  practiced integer,
  correct integer,
  wrong integer,
  round2_focus integer
)
language sql
stable
security definer
set search_path to 'pg_catalog','english'
as $function$
with a as materialized (
  select * from english.grammar_daily_batch_attempts(p_user_id,p_batch_date)
), base as (
  select
    i.question_id,
    a.attempt_id,
    a.correct,
    a.guessed,
    coalesce(d.difficult,false) difficult
  from english.grammar_daily_items i
  left join a on a.question_id=i.question_id
  left join english.difficult_state d
    on d.user_id=p_user_id and d.question_id=i.question_id
  where i.batch_date=p_batch_date
)
select
  count(*)::int total,
  count(*) filter(where attempt_id is not null)::int practiced,
  count(*) filter(where attempt_id is not null and correct)::int correct,
  count(*) filter(where attempt_id is not null and not correct)::int wrong,
  count(*) filter(
    where attempt_id is not null
      and (not correct or guessed or difficult)
  )::int round2_focus
from base
$function$;

create or replace function public.english_get_grammar_hub()
returns jsonb
language plpgsql
stable
security definer
set search_path to 'pg_catalog','public','english','auth'
as $function$
declare
  uid uuid:=auth.uid();
  v_total integer:=0; v_covered integer:=0; v_weak integer:=0; v_due integer:=0; v_mastered integer:=0;
  v_available integer:=0; v_weak_available integer:=0; v_due_available integer:=0;
  v_today integer:=0; v_today_date date:=(now() at time zone 'Asia/Kolkata')::date;
  v_today_new integer:=0; v_today_review integer:=0;
  v_today_practiced integer:=0; v_today_correct integer:=0; v_today_wrong integer:=0; v_today_round2 integer:=0;
  v_active_date date; v_active_total integer:=0; v_active_practiced integer:=0; v_active_correct integer:=0; v_active_wrong integer:=0; v_active_round2 integer:=0;
  v_chapters jsonb:='[]'::jsonb;
begin
  if uid is null then raise exception 'Authentication required'; end if;

  select
    count(*)::int,
    count(*) filter(where e.introduced_at is not null or coalesce(e.attempts,0)>0)::int,
    count(*) filter(where e.coverage_state='weak' or coalesce(e.recent_failures,0)>0)::int,
    count(*) filter(where (e.introduced_at is not null or coalesce(e.attempts,0)>0) and e.next_review is not null and e.next_review<=now())::int,
    count(*) filter(where e.coverage_state='mastered')::int
  into v_total,v_covered,v_weak,v_due,v_mastered
  from english.grammar_rules r
  left join english.grammar_rule_evidence e on e.user_id=uid and e.rule_key=r.rule_key
  where r.active;

  with vr as(select distinct rule_key from english.grammar_question_variants)
  select
    count(*)::int,
    count(*) filter(where e.coverage_state='weak' or coalesce(e.recent_failures,0)>0)::int,
    count(*) filter(where e.next_review is not null and e.next_review<=now())::int
  into v_available,v_weak_available,v_due_available
  from vr
  join english.grammar_rules r using(rule_key)
  left join english.grammar_rule_evidence e on e.user_id=uid and e.rule_key=vr.rule_key
  where r.active;

  select
    count(*)::int,
    count(*) filter(where is_new_variant)::int,
    count(*) filter(where not is_new_variant)::int
  into v_today,v_today_new,v_today_review
  from english.grammar_daily_items
  where batch_date=v_today_date;

  select practiced,correct,wrong,round2_focus
  into v_today_practiced,v_today_correct,v_today_wrong,v_today_round2
  from english.grammar_daily_progress(uid,v_today_date);

  select b.batch_date
  into v_active_date
  from (
    select distinct batch_date
    from english.grammar_daily_items
    where batch_date<=v_today_date
  ) b
  cross join lateral english.grammar_daily_progress(uid,b.batch_date) p
  where p.total>0 and p.practiced<p.total
  order by b.batch_date
  limit 1;

  if v_active_date is null and v_today>0 then
    v_active_date:=v_today_date;
  end if;

  if v_active_date is not null then
    select total,practiced,correct,wrong,round2_focus
    into v_active_total,v_active_practiced,v_active_correct,v_active_wrong,v_active_round2
    from english.grammar_daily_progress(uid,v_active_date);
  end if;

  with variants as(
    select rule_key,count(*)::int question_count
    from english.grammar_question_variants
    group by rule_key
  ), per_chapter as(
    select
      r.chapter,
      count(*)::int total_rules,
      count(*) filter(where e.introduced_at is not null or coalesce(e.attempts,0)>0)::int covered_rules,
      count(*) filter(where e.coverage_state='weak' or coalesce(e.recent_failures,0)>0)::int weak_rules,
      count(*) filter(where e.next_review is not null and e.next_review<=now())::int due_rules,
      coalesce(sum(v.question_count),0)::int question_count
    from english.grammar_rules r
    left join english.grammar_rule_evidence e on e.user_id=uid and e.rule_key=r.rule_key
    left join variants v on v.rule_key=r.rule_key
    where r.active
    group by r.chapter
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'chapter',chapter,
    'totalRules',total_rules,
    'coveredRules',covered_rules,
    'coveragePercent',case when total_rules>0 then round(covered_rules::numeric*100/total_rules)::int else 0 end,
    'weakRules',weak_rules,
    'dueRules',due_rules,
    'questionCount',question_count
  ) order by chapter),'[]'::jsonb)
  into v_chapters
  from per_chapter;

  return jsonb_build_object(
    'ok',true,
    'dailyTarget',20,
    'stats',jsonb_build_object(
      'totalRules',v_total,
      'covered',v_covered,
      'coveragePercent',case when v_total>0 then round(v_covered::numeric*100/v_total)::int else 0 end,
      'weak',v_weak,
      'due',v_due,
      'mastered',v_mastered
    ),
    'today',jsonb_build_object(
      'date',v_today_date,
      'count',v_today,
      'target',20,
      'ready',v_today=20,
      'newCount',v_today_new,
      'reviewCount',v_today_review,
      'practiced',v_today_practiced,
      'remaining',greatest(0,v_today-v_today_practiced),
      'correct',v_today_correct,
      'wrong',v_today_wrong,
      'round2Focus',v_today_round2,
      'complete',(v_today=20 and v_today_practiced=20)
    ),
    'daily',jsonb_build_object(
      'activeDate',v_active_date,
      'activeTotal',v_active_total,
      'activePracticed',v_active_practiced,
      'activeRemaining',greatest(0,v_active_total-v_active_practiced),
      'activeCorrect',v_active_correct,
      'activeWrong',v_active_wrong,
      'activeRound2Focus',v_active_round2,
      'isBacklog',(v_active_date is not null and v_active_date<v_today_date),
      'todayLocked',(v_active_date is not null and v_active_date<v_today_date)
    ),
    'available',jsonb_build_object(
      'smart',v_available,
      'weak',v_weak_available,
      'due',v_due_available,
      'all',v_available
    ),
    'sizes',jsonb_build_array(10,20,30,50),
    'chapters',v_chapters,
    'readOnlyBrowsing',true
  );
end
$function$;

create or replace function public.english_get_grammar_today()
returns jsonb
language plpgsql
stable
security definer
set search_path to 'pg_catalog','public','english','auth'
as $function$
declare
  uid uuid:=auth.uid();
  v_today date:=(now() at time zone 'Asia/Kolkata')::date;
  v_day date;
  v_items jsonb:='[]'::jsonb;
  v_total integer:=0; v_practiced integer:=0; v_correct integer:=0; v_wrong integer:=0; v_round2 integer:=0;
begin
  if uid is null then raise exception 'Authentication required'; end if;

  select b.batch_date
  into v_day
  from (
    select distinct batch_date
    from english.grammar_daily_items
    where batch_date<=v_today
  ) b
  cross join lateral english.grammar_daily_progress(uid,b.batch_date) p
  where p.total>0 and p.practiced<p.total
  order by b.batch_date
  limit 1;

  if v_day is null then v_day:=v_today; end if;

  select total,practiced,correct,wrong,round2_focus
  into v_total,v_practiced,v_correct,v_wrong,v_round2
  from english.grammar_daily_progress(uid,v_day);

  with a as materialized (
    select * from english.grammar_daily_batch_attempts(uid,v_day)
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
        'batchDate',v_day,
        'attemptedBatch',a.question_id is not null
      )
    order by (a.question_id is not null),i.slot_no
  ),'[]'::jsonb)
  into v_items
  from english.grammar_daily_items i
  join english.grammar_rules r on r.rule_key=i.rule_key
  left join a on a.question_id=i.question_id
  where i.batch_date=v_day;

  return jsonb_build_object(
    'ok',true,
    'date',v_day,
    'currentDate',v_today,
    'isBacklog',v_day<v_today,
    'ready',jsonb_array_length(v_items)=20,
    'count',jsonb_array_length(v_items),
    'practiced',v_practiced,
    'remaining',greatest(0,v_total-v_practiced),
    'correct',v_correct,
    'wrong',v_wrong,
    'round2Focus',v_round2,
    'complete',(v_total=20 and v_practiced=20),
    'items',v_items
  );
end
$function$;

create or replace function public.english_get_grammar_round2(p_batch_date date default null)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'pg_catalog','public','english','auth'
as $function$
declare
  uid uuid:=auth.uid();
  v_today date:=(now() at time zone 'Asia/Kolkata')::date;
  v_day date:=coalesce(p_batch_date,(now() at time zone 'Asia/Kolkata')::date);
  v_items jsonb:='[]'::jsonb;
  v_total integer:=0; v_practiced integer:=0; v_correct integer:=0; v_wrong integer:=0; v_round2 integer:=0;
begin
  if uid is null then raise exception 'Authentication required'; end if;

  select total,practiced,correct,wrong,round2_focus
  into v_total,v_practiced,v_correct,v_wrong,v_round2
  from english.grammar_daily_progress(uid,v_day);

  if v_total=0 then
    return jsonb_build_object('ok',false,'reason','batch-not-found','date',v_day,'count',0,'items','[]'::jsonb);
  end if;
  if v_practiced<v_total then
    return jsonb_build_object('ok',false,'reason','batch-incomplete','date',v_day,'practiced',v_practiced,'remaining',v_total-v_practiced,'count',0,'items','[]'::jsonb);
  end if;

  with a as materialized (
    select * from english.grammar_daily_batch_attempts(uid,v_day)
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
        'batchDate',v_day,
        'round2',true,
        'round2Reasons',to_jsonb(array_remove(array[
          case when not a.correct then 'Wrong' end,
          case when a.guessed then 'Guessed' end,
          case when coalesce(d.difficult,false) then 'Difficult' end
        ],null))
      )
    order by (not a.correct) desc,a.guessed desc,coalesce(d.difficult,false) desc,i.slot_no
  ),'[]'::jsonb)
  into v_items
  from english.grammar_daily_items i
  join english.grammar_rules r on r.rule_key=i.rule_key
  join a on a.question_id=i.question_id
  left join english.difficult_state d on d.user_id=uid and d.question_id=i.question_id
  where i.batch_date=v_day
    and (not a.correct or a.guessed or coalesce(d.difficult,false));

  return jsonb_build_object(
    'ok',true,
    'date',v_day,
    'currentDate',v_today,
    'count',jsonb_array_length(v_items),
    'focus',v_round2,
    'wrong',v_wrong,
    'items',v_items
  );
end
$function$;

grant execute on function public.english_get_grammar_hub() to authenticated;
grant execute on function public.english_get_grammar_today() to authenticated;
grant execute on function public.english_get_grammar_round2(date) to authenticated;
