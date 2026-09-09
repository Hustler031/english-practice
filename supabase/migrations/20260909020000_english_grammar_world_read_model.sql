-- ENGLISH V2 — Grammar World Stage 2 read/practice model
-- UI-facing functions are read-only selectors over the Stage 1 Grammar Intelligence state.
-- Read-only browsing never writes attempts/evidence. Quiz attempts continue through english_submit_answer.

create or replace function english.grammar_question_payload(p_user uuid,p_question_id text)
returns jsonb
language sql
stable
security definer
set search_path to 'pg_catalog','english'
as $function$
select jsonb_build_object(
  'id',q.question_id,
  'category','Grammar',
  'topic',q.topic,
  'subtopic',q.subtopic,
  'word',q.word,
  'question',q.question,
  'questionType',q.question_type,
  'options',jsonb_build_array(
    jsonb_build_object('key','A','text',q.option_a),
    jsonb_build_object('key','B','text',q.option_b),
    jsonb_build_object('key','C','text',q.option_c),
    jsonb_build_object('key','D','text',q.option_d)
  ),
  'correctKey',q.correct,
  'explanation',q.explanation,
  'tip',q.tip,
  'usageNote',q.usage_note,
  'example',q.example_sentence,
  'memoryAid',q.memory_aid,
  'related',q.related_words,
  'difficulty',q.difficulty,
  'sourceUrl',q.source_url,
  'conceptId',q.concept_id,
  'attempts',coalesce(qs.attempts,0),
  'questionFamily',v.question_family,
  'ruleKey',v.rule_key,
  'qualityScore',v.quality_score
)
from english.questions q
join english.grammar_question_variants v on v.question_id=q.question_id
left join english.question_state qs on qs.user_id=p_user and qs.question_id=q.question_id
where q.question_id=p_question_id and q.active
limit 1
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

  with vr as(
    select distinct rule_key from english.grammar_question_variants
  )
  select
    count(*)::int,
    count(*) filter(where e.coverage_state='weak' or coalesce(e.recent_failures,0)>0)::int,
    count(*) filter(where e.next_review is not null and e.next_review<=now())::int
  into v_available,v_weak_available,v_due_available
  from vr
  join english.grammar_rules r using(rule_key)
  left join english.grammar_rule_evidence e on e.user_id=uid and e.rule_key=vr.rule_key
  where r.active;

  select count(*)::int into v_today
  from english.grammar_daily_items
  where batch_date=v_today_date;

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
      'ready',v_today=20
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

create or replace function public.english_get_grammar_chapter(p_chapter text)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'pg_catalog','public','english','auth'
as $function$
declare
  uid uuid:=auth.uid();
  v_chapter text:=btrim(coalesce(p_chapter,''));
  v_total integer:=0; v_covered integer:=0; v_weak integer:=0; v_due integer:=0; v_questions integer:=0;
  v_rules jsonb:='[]'::jsonb;
begin
  if uid is null then raise exception 'Authentication required'; end if;
  if v_chapter='' then raise exception 'Grammar chapter is required'; end if;

  with variants as(
    select rule_key,count(*)::int question_count,
      array_agg(distinct question_family order by question_family) families
    from english.grammar_question_variants
    group by rule_key
  )
  select
    count(*)::int,
    count(*) filter(where e.introduced_at is not null or coalesce(e.attempts,0)>0)::int,
    count(*) filter(where e.coverage_state='weak' or coalesce(e.recent_failures,0)>0)::int,
    count(*) filter(where e.next_review is not null and e.next_review<=now())::int,
    coalesce(sum(v.question_count),0)::int,
    coalesce(jsonb_agg(jsonb_build_object(
      'ruleKey',r.rule_key,
      'ruleFamily',r.rule_family,
      'ruleTitle',r.rule_title,
      'canonicalRule',r.canonical_rule,
      'commonTrap',coalesce(r.common_trap,''),
      'contrastWith',coalesce(r.contrast_with,''),
      'priority',r.priority,
      'difficulty',r.difficulty,
      'sourceName',r.source_name,
      'sourceUrl',r.source_url,
      'seen',(e.introduced_at is not null or coalesce(e.attempts,0)>0),
      'state',case
        when e.coverage_state='weak' or coalesce(e.recent_failures,0)>0 then 'weak'
        when coalesce(e.coverage_state,'')<>'' then e.coverage_state
        when coalesce(e.attempts,0)>0 then 'learning'
        else 'unseen' end,
      'attempts',coalesce(e.attempts,0),
      'correct',coalesce(e.correct,0),
      'wrong',coalesce(e.wrong,0),
      'recentFailures',coalesce(e.recent_failures,0),
      'confidence',coalesce(e.confidence_score,0),
      'due',(e.next_review is not null and e.next_review<=now()),
      'nextReview',e.next_review,
      'questionCount',coalesce(v.question_count,0),
      'questionFamilies',coalesce(to_jsonb(v.families),'[]'::jsonb)
    ) order by r.rule_family,r.priority desc,r.rule_title),'[]'::jsonb)
  into v_total,v_covered,v_weak,v_due,v_questions,v_rules
  from english.grammar_rules r
  left join english.grammar_rule_evidence e on e.user_id=uid and e.rule_key=r.rule_key
  left join variants v on v.rule_key=r.rule_key
  where r.active and r.chapter=v_chapter;

  if v_total=0 then
    return jsonb_build_object('ok',false,'reason','chapter-not-found','chapter',v_chapter,'rules','[]'::jsonb);
  end if;

  return jsonb_build_object(
    'ok',true,
    'chapter',v_chapter,
    'stats',jsonb_build_object(
      'totalRules',v_total,
      'covered',v_covered,
      'coveragePercent',round(v_covered::numeric*100/v_total)::int,
      'weak',v_weak,
      'due',v_due,
      'questions',v_questions
    ),
    'available',jsonb_build_object(
      'smart',v_questions,
      'weak',v_weak,
      'due',v_due,
      'all',v_questions
    ),
    'rules',v_rules,
    'readOnlyBrowsing',true
  );
end
$function$;

create or replace function public.english_get_grammar_rule_questions(p_rule_key text)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'pg_catalog','public','english','auth'
as $function$
declare
  uid uuid:=auth.uid();
  v_key text:=btrim(coalesce(p_rule_key,''));
  v_items jsonb:='[]'::jsonb;
begin
  if uid is null then raise exception 'Authentication required'; end if;
  if v_key='' then raise exception 'Grammar rule key is required'; end if;

  select coalesce(jsonb_agg(
    english.grammar_question_payload(uid,x.question_id)
    order by x.family_rank,x.created_at,x.question_id
  ),'[]'::jsonb)
  into v_items
  from (
    select v.question_id,v.created_at,
      case v.question_family
        when 'direct_fill' then 1
        when 'context_fill' then 2
        when 'sentence_improvement' then 3
        when 'error_detection' then 4
        when 'transformation' then 5
        when 'contrast' then 6
        when 'transfer' then 7
        else 8 end family_rank
    from english.grammar_question_variants v
    join english.questions q on q.question_id=v.question_id and q.active
    where v.rule_key=v_key
  ) x;

  return jsonb_build_object(
    'ok',true,
    'ruleKey',v_key,
    'count',jsonb_array_length(v_items),
    'readOnly',true,
    'items',v_items
  );
end
$function$;

create or replace function public.english_get_grammar_batch(
  p_mode text default 'smart',
  p_count integer default 20,
  p_chapter text default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'pg_catalog','public','english','auth'
as $function$
declare
  uid uuid:=auth.uid();
  v_mode text:=lower(btrim(coalesce(p_mode,'smart')));
  v_count integer:=least(100,greatest(1,coalesce(p_count,20)));
  v_chapter text:=nullif(btrim(coalesce(p_chapter,'')),'');
  v_items jsonb:='[]'::jsonb;
begin
  if uid is null then raise exception 'Authentication required'; end if;
  if v_mode not in ('smart','weak','due','all') then raise exception 'Unsupported Grammar practice mode: %',v_mode; end if;

  with candidates as(
    select
      v.question_id,v.rule_key,v.question_family,v.quality_score,v.created_at,
      r.chapter,r.priority,
      coalesce(e.coverage_state,'introduced') coverage_state,
      coalesce(e.recent_failures,0) recent_failures,
      coalesce(e.confidence_score,0) confidence_score,
      e.next_review,e.last_attempt_at,
      coalesce(qs.attempts,0) question_attempts,qs.last_attempt,
      row_number() over(
        partition by v.rule_key
        order by
          (coalesce(qs.attempts,0)=0) desc,
          case
            when e.coverage_state='weak' or coalesce(e.recent_failures,0)>0 then
              case v.question_family when 'context_fill' then 1 when 'sentence_improvement' then 2 when 'direct_fill' then 3 when 'error_detection' then 4 else 5 end
            when e.coverage_state in ('strong','mastered') then
              case v.question_family when 'transfer' then 1 when 'contrast' then 2 when 'transformation' then 3 when 'error_detection' then 4 else 5 end
            else
              case v.question_family when 'sentence_improvement' then 1 when 'error_detection' then 2 when 'context_fill' then 3 when 'transformation' then 4 else 5 end
          end,
          v.quality_score desc nulls last,
          v.created_at desc
      ) variant_rank
    from english.grammar_question_variants v
    join english.grammar_rules r on r.rule_key=v.rule_key and r.active
    join english.questions q on q.question_id=v.question_id and q.active
    left join english.grammar_rule_evidence e on e.user_id=uid and e.rule_key=v.rule_key
    left join english.question_state qs on qs.user_id=uid and qs.question_id=v.question_id
    where v_chapter is null or r.chapter=v_chapter
  ), one_per_rule as(
    select *,
      case v_mode
        when 'weak' then 10000 + recent_failures*500 + priority
        when 'due' then 9000 + priority
        when 'smart' then
          case
            when coverage_state='weak' or recent_failures>0 then 10000 + recent_failures*500
            when next_review is not null and next_review<=now() then 8000
            when coverage_state='learning' then 6000
            when coverage_state='introduced' then 4500
            when coverage_state='strong' then 3000
            when coverage_state='mastered' then 1500
            else 2000 end + priority + case when question_attempts=0 then 150 else 0 end
        else priority + case when question_attempts=0 then 100 else 0 end
      end rank_score
    from candidates
    where variant_rank=1
      and (
        v_mode in ('smart','all')
        or (v_mode='weak' and (coverage_state='weak' or recent_failures>0))
        or (v_mode='due' and next_review is not null and next_review<=now())
      )
  ), picked as(
    select *
    from one_per_rule
    order by rank_score desc,last_attempt_at nulls first,md5(rule_key||current_date::text)
    limit v_count
  )
  select coalesce(jsonb_agg(
    english.grammar_question_payload(uid,p.question_id)
    order by p.rank_score desc,p.last_attempt_at nulls first,p.rule_key
  ),'[]'::jsonb)
  into v_items
  from picked p;

  return v_items;
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
  v_day date:=(now() at time zone 'Asia/Kolkata')::date;
  v_items jsonb:='[]'::jsonb;
begin
  if uid is null then raise exception 'Authentication required'; end if;

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
        'contrastWith',coalesce(r.contrast_with,'')
      )
    order by i.slot_no
  ),'[]'::jsonb)
  into v_items
  from english.grammar_daily_items i
  join english.grammar_rules r on r.rule_key=i.rule_key
  where i.batch_date=v_day;

  return jsonb_build_object(
    'ok',true,
    'date',v_day,
    'ready',jsonb_array_length(v_items)=20,
    'count',jsonb_array_length(v_items),
    'items',v_items
  );
end
$function$;

revoke all on function english.grammar_question_payload(uuid,text) from public;
revoke all on function public.english_get_grammar_hub() from public;
revoke all on function public.english_get_grammar_chapter(text) from public;
revoke all on function public.english_get_grammar_rule_questions(text) from public;
revoke all on function public.english_get_grammar_batch(text,integer,text) from public;
revoke all on function public.english_get_grammar_today() from public;

grant execute on function public.english_get_grammar_hub() to authenticated;
grant execute on function public.english_get_grammar_chapter(text) to authenticated;
grant execute on function public.english_get_grammar_rule_questions(text) to authenticated;
grant execute on function public.english_get_grammar_batch(text,integer,text) to authenticated;
grant execute on function public.english_get_grammar_today() to authenticated;
