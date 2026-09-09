-- ENGLISH V2 — Grammar Stage 1 selector alias fix
-- PL/pgSQL record variables share identifier resolution with SQL references.
-- Keep the loop record and table aliases distinct so PostgreSQL never treats a table alias as an unassigned record.

create or replace function english.maintenance_grammar_batch(p_count integer default 20)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','public','english','auth'
set statement_timeout to '60s'
as $function$
declare
  uid uuid; v_users integer; v_day date:=(now() at time zone 'Asia/Kolkata')::date;
  v_introduced integer:=0; v_review_cap integer:=0; v_new_cap integer:=0; v_selected integer:=0;
  v_rule_rec record; v_allowed text[]; v_preferred text; v_ref jsonb; v_items jsonb:='[]'::jsonb; v_slot integer:=0; v_gaps integer:=0;
begin
  if p_count<>20 then raise exception 'Grammar Daily invariant requires exactly 20 slots'; end if;
  select count(*) into v_users from auth.users where deleted_at is null;
  select id into uid from auth.users where deleted_at is null order by id limit 1;
  if v_users<>1 or uid is null then raise exception 'Grammar selector requires exactly one active learner'; end if;

  select count(*) into v_introduced
  from english.grammar_rule_evidence
  where user_id=uid and introduced_at is not null;

  if v_introduced<20 then v_review_cap:=0;
  elsif v_introduced<140 then v_review_cap:=3;
  elsif v_introduced<220 then v_review_cap:=6;
  else v_review_cap:=12;
  end if;
  v_new_cap:=20-v_review_cap;

  create temp table grammar_pick(
    ord bigserial,
    rule_key text primary key,
    selection_type text,
    rank_score numeric
  ) on commit drop;

  -- Review stays deliberately bounded while the curriculum is still broadening.
  insert into grammar_pick(rule_key,selection_type,rank_score)
  select e.rule_key,'review',
    (case e.coverage_state when 'weak' then 1000 when 'learning' then 600 when 'strong' then 300 else 100 end)
      + e.recent_failures*100 + gr.priority
  from english.grammar_rule_evidence e
  join english.grammar_rules gr using(rule_key)
  where e.user_id=uid
    and e.introduced_at is not null
    and gr.active
    and (e.coverage_state='weak' or e.recent_failures>0 or e.next_review is null or e.next_review<=now())
  order by 3 desc,e.next_review nulls first,e.last_attempt_at nulls first
  limit v_review_cap;

  -- New-rule selection is chapter-interleaved so one high-priority chapter cannot monopolise a day.
  with raw as(
    select gr.rule_key,gr.chapter,gr.priority,coalesce(e.recent_failures,0) diagnostic_failures,
      row_number() over(
        partition by gr.chapter
        order by coalesce(e.recent_failures,0) desc,gr.priority desc,gr.rule_key
      ) chapter_rn
    from english.grammar_rules gr
    left join english.grammar_rule_evidence e on e.user_id=uid and e.rule_key=gr.rule_key
    where gr.active and e.introduced_at is null
  ), ranked as(
    select *,
      row_number() over(
        order by chapter_rn,diagnostic_failures desc,priority desc,md5(rule_key||v_day::text)
      ) global_rn
    from raw
  )
  insert into grammar_pick(rule_key,selection_type,rank_score)
  select rule_key,'new',10000-global_rn
  from ranked
  order by global_rn
  limit v_new_cap
  on conflict(rule_key) do nothing;

  select count(*) into v_selected from grammar_pick;
  if v_selected<20 then
    insert into grammar_pick(rule_key,selection_type,rank_score)
    select gr.rule_key,'rotation',gr.priority+coalesce(e.recent_failures,0)*100
    from english.grammar_rules gr
    join english.grammar_rule_evidence e
      on e.user_id=uid and e.rule_key=gr.rule_key and e.introduced_at is not null
    where gr.active
      and not exists(select 1 from grammar_pick p where p.rule_key=gr.rule_key)
    order by (e.coverage_state='weak') desc,e.next_review nulls first,e.last_selected_at nulls first,gr.priority desc
    limit 20-v_selected
    on conflict(rule_key) do nothing;
  end if;

  select count(*) into v_selected from grammar_pick;
  if v_selected<>20 then
    raise exception 'Grammar selector could form only % of 20 distinct rule slots; curriculum is incomplete',v_selected;
  end if;

  for v_rule_rec in
    select p.selection_type,gr.*,
      coalesce(e.selection_count,0) selection_count,
      coalesce(e.attempts,0) attempts,
      coalesce(e.correct,0) correct,
      coalesce(e.wrong,0) wrong,
      coalesce(e.recent_failures,0) recent_failures,
      coalesce(e.distinct_families,0) distinct_families,
      coalesce(e.transfer_successes,0) transfer_successes,
      coalesce(e.coverage_state,'introduced') learner_state,
      e.next_review,e.last_attempt_at
    from grammar_pick p
    join english.grammar_rules gr using(rule_key)
    left join english.grammar_rule_evidence e on e.user_id=uid and e.rule_key=gr.rule_key
    order by md5(p.rule_key||v_day::text)
  loop
    v_slot:=v_slot+1;
    v_allowed:=english.grammar_allowed_families(
      v_rule_rec.supported_families,v_rule_rec.selection_count,v_rule_rec.learner_state
    );
    v_preferred:=english.grammar_preferred_family(
      v_rule_rec.supported_families,v_rule_rec.selection_count,v_rule_rec.learner_state
    );
    v_ref:=english.grammar_reference_variant(uid,v_rule_rec.rule_key,array[v_preferred]);
    if v_ref is null then v_gaps:=v_gaps+1; end if;

    v_items:=v_items||jsonb_build_array(jsonb_build_object(
      'slotNo',v_slot,
      'ruleKey',v_rule_rec.rule_key,
      'chapter',v_rule_rec.chapter,
      'ruleFamily',v_rule_rec.rule_family,
      'ruleTitle',v_rule_rec.rule_title,
      'canonicalRule',v_rule_rec.canonical_rule,
      'commonTrap',coalesce(v_rule_rec.common_trap,''),
      'contrastWith',coalesce(v_rule_rec.contrast_with,''),
      'priority',v_rule_rec.priority,
      'difficulty',v_rule_rec.difficulty,
      'selectionType',v_rule_rec.selection_type,
      'selectionCount',v_rule_rec.selection_count,
      'attempts',v_rule_rec.attempts,
      'correct',v_rule_rec.correct,
      'wrong',v_rule_rec.wrong,
      'recentFailures',v_rule_rec.recent_failures,
      'distinctFamilies',v_rule_rec.distinct_families,
      'transferSuccesses',v_rule_rec.transfer_successes,
      'learnerState',v_rule_rec.learner_state,
      'nextReview',v_rule_rec.next_review,
      'lastAttemptAt',v_rule_rec.last_attempt_at,
      'preferredQuestionFamily',v_preferred,
      'allowedQuestionFamilies',to_jsonb(v_allowed),
      'referenceVariant',v_ref,
      'contentGap',(v_ref is null),
      'sourceName',v_rule_rec.source_name,
      'sourceUrl',v_rule_rec.source_url,
      'verificationNote',coalesce(v_rule_rec.verification_note,''),
      'aiPlanner',jsonb_build_object(
        'required',v_ref is null,
        'role','Choose the most pedagogically useful family only from allowedQuestionFamilies, preserve the verified rule, and keep difficulty SSC-realistic.',
        'coldStartGuard',v_rule_rec.selection_count<=1,
        'doNotEscalateIfWeak',v_rule_rec.learner_state='weak'
      )
    ));
  end loop;

  return jsonb_build_object(
    'ok',true,
    'date',v_day,
    'count',20,
    'introducedRules',v_introduced,
    'reviewCap',v_review_cap,
    'newTarget',v_new_cap,
    'generatedNeeded',v_gaps,
    'sourceId','GRAMMAR_DAILY_'||to_char(v_day,'YYYYMMDD'),
    'sourceFile','Grammar Daily '||to_char(v_day,'YYYY-MM-DD'),
    'items',v_items,
    'contract',jsonb_build_object(
      'exactCount',20,
      'planner','chatgpt',
      'critic','chatgpt_self_critic',
      'canonicalReuse',true
    )
  );
end
$function$;

revoke all on function english.maintenance_grammar_batch(integer) from public;
grant execute on function english.maintenance_grammar_batch(integer) to service_role;
