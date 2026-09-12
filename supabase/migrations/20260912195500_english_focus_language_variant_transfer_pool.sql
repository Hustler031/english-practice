-- Preserve the exact 15 Grammar + 15 Phrasal Focus target without repeating the same question.
-- Same-day Grammar/Phrasal Daily and Review Due exact questions are already excluded by
-- focus_conflicts_with_required_daily(). Concept-level exclusion was too strict on heavy
-- Review Due days, so a different canonical variant of the same concept remains eligible.

create or replace function english.ensure_daily_focus_language_lanes(p_user_id uuid,p_batch_date date)
returns jsonb
language plpgsql
security definer
set search_path='pg_catalog','english','auth','public'
as $function$
declare
  v_grammar integer:=0;
  v_phrasal integer:=0;
  v_missing integer:=0;
begin
  if p_user_id is null or p_batch_date is null then
    raise exception 'user and batch date are required';
  end if;

  if not exists(
    select 1 from english.daily_focus_batches
    where user_id=p_user_id and batch_date=p_batch_date
  ) then
    return jsonb_build_object('ok',false,'reason','no-focus-batch','batchDate',p_batch_date);
  end if;

  select count(*) into v_grammar
  from english.daily_focus_items
  where user_id=p_user_id and batch_date=p_batch_date and lane='grammar';

  v_missing:=greatest(0,15-v_grammar);
  if v_missing>0 then
    with raw as materialized (
      select
        v.question_id,
        v.rule_key,
        english.grammar_concept_id(v.rule_key) concept_key,
        v.question_family,
        v.difficulty,
        v.quality_score,
        coalesce(e.coverage_state,'new') coverage_state,
        e.next_review,
        coalesce(e.recent_failures,0)::int recent_failures,
        coalesce(e.confidence_score,0)::numeric confidence_score,
        coalesce(e.attempts,0)::int rule_attempts,
        coalesce(s.attempts,0)::int question_attempts,
        coalesce(s.status,'New') question_status,
        case
          when coalesce(s.status,'')='Persistent Weak' then 1
          when coalesce(e.coverage_state,'')='weak' or coalesce(e.recent_failures,0)>0 or coalesce(s.status,'')='Weak' then 2
          when coalesce(s.status,'')='Fragile' then 3
          when e.next_review is not null and e.next_review<=now() then 4
          when coalesce(e.attempts,0)=0 then 5
          when coalesce(e.coverage_state,'')='learning' then 6
          else 7
        end priority_bucket,
        case
          when coalesce(s.status,'')='Persistent Weak' then 'Persistent Weak'
          when coalesce(e.coverage_state,'')='weak' or coalesce(e.recent_failures,0)>0 or coalesce(s.status,'')='Weak' then 'Weak / Recent Failure'
          when coalesce(s.status,'')='Fragile' then 'Fragile'
          when e.next_review is not null and e.next_review<=now() then 'Due'
          when coalesce(e.attempts,0)=0 then 'New / Unseen Rule'
          when coalesce(e.coverage_state,'')='learning' then 'Learning'
          else 'Rotation'
        end ci_reason
      from english.grammar_question_variants v
      join english.questions q on q.question_id=v.question_id and q.active
      left join english.grammar_rule_evidence e on e.user_id=p_user_id and e.rule_key=v.rule_key
      left join english.question_state s on s.user_id=p_user_id and s.question_id=v.question_id
      where english.question_visible_to_user(p_user_id,v.question_id)
        and coalesce(e.coverage_state,'')<>'mastered'
        and coalesce(s.status,'') not in ('Mastered','Proven Mastered')
        and not coalesce(s.mastered,false)
        and not english.focus_conflicts_with_required_daily(p_user_id,v.question_id,p_batch_date)
        and not exists(
          select 1 from english.daily_focus_items f
          where f.user_id=p_user_id and f.batch_date=p_batch_date
            and f.concept_key=english.grammar_concept_id(v.rule_key)
        )
    ), ranked as materialized (
      select r.*,
        row_number() over(
          partition by r.concept_key
          order by r.priority_bucket,
                   case when r.question_attempts=0 then 0 else 1 end,
                   r.question_attempts,
                   coalesce(r.quality_score,0) desc,
                   r.question_id
        ) concept_pick
      from raw r
    ), chosen as materialized (
      select * from ranked
      where concept_pick=1
      order by priority_bucket,recent_failures desc,
               case when next_review is not null and next_review<=now() then 0 else 1 end,
               confidence_score,rule_attempts,question_attempts,rule_key
      limit v_missing
    ), numbered as (
      select c.*,
        coalesce((select max(sequence) from english.daily_focus_items
                  where user_id=p_user_id and batch_date=p_batch_date and lane='grammar'),0)
        + row_number() over(order by priority_bucket,recent_failures desc,
                            case when next_review is not null and next_review<=now() then 0 else 1 end,
                            confidence_score,rule_attempts,question_attempts,rule_key)::int seq
      from chosen c
    )
    insert into english.daily_focus_items(
      user_id,batch_date,lane,sequence,question_id,concept_key,reasons,selection_snapshot
    )
    select
      p_user_id,p_batch_date,'grammar',seq,question_id,concept_key,
      array['Grammar CI',ci_reason]::text[],
      jsonb_strip_nulls(jsonb_build_object(
        'source','grammar_intelligence','buildVersion','language_v1','domain','grammar',
        'ruleKey',rule_key,'questionFamily',question_family,'difficulty',difficulty,
        'qualityScore',quality_score,'ciReason',ci_reason,'priorityBucket',priority_bucket,
        'coverageState',coverage_state,'nextReview',next_review,'recentFailures',recent_failures,
        'confidenceScore',confidence_score,'ruleAttempts',rule_attempts,'questionAttempts',question_attempts,
        'questionState',question_status
      ))
    from numbered
    on conflict do nothing;
  end if;

  select count(*) into v_phrasal
  from english.daily_focus_items
  where user_id=p_user_id and batch_date=p_batch_date and lane='phrasal';

  v_missing:=greatest(0,15-v_phrasal);
  if v_missing>0 then
    with concepts as materialized (
      select
        c.*,
        case
          when c.state='Persistent Weak' then 1
          when c.state='Weak' or c.recall_weak or c.confusion_weak or c.recognition_weak then 2
          when c.state='Fragile' then 3
          when c.due then 4
          when c.never_revised or c.state='New' then 5
          when c.difficult then 6
          when c.starred then 7
          else 8
        end priority_bucket,
        case
          when c.state='Persistent Weak' then 'Persistent Weak'
          when c.state='Weak' then 'Weak'
          when c.recall_weak then 'Recall Weak'
          when c.confusion_weak then 'Confusion Weak'
          when c.recognition_weak then 'Recognition Weak'
          when c.state='Fragile' then 'Fragile'
          when c.due then 'Due'
          when c.never_revised or c.state='New' then 'New / Never Revised'
          when c.difficult then 'Difficult'
          when c.starred then 'Starred'
          else 'Rotation'
        end ci_reason
      from english.phrasal_concepts(p_user_id) c
      where not c.proven_mastery
        and c.active_variant_count>0
        and not exists(
          select 1 from english.daily_focus_items f
          where f.user_id=p_user_id and f.batch_date=p_batch_date and f.concept_key=c.concept_id
        )
    ), variants as materialized (
      select
        c.*,
        q.question_id,
        english.phrasal_question_family(q) question_family,
        coalesce(s.attempts,0)::int question_attempts,
        row_number() over(
          partition by c.concept_id
          order by
            case when nullif(c.preferred_family,'') is not null and english.phrasal_question_family(q)=c.preferred_family then 0 else 1 end,
            case when coalesce(s.attempts,0)=0 then 0 else 1 end,
            coalesce(s.attempts,0),q.question_id
        ) variant_pick
      from concepts c
      join english.questions q
        on coalesce(nullif(btrim(q.concept_id),''),'PVQ_'||q.question_id)=c.concept_id
       and q.active
      left join english.question_state s on s.user_id=p_user_id and s.question_id=q.question_id
      where english.question_visible_to_user(p_user_id,q.question_id)
        and (english.canonical_category(q.topic)='PHRASAL' or lower(btrim(coalesce(q.topic,'')))='phrasal verb')
        and not coalesce(s.mastered,false)
        and coalesce(s.status,'') not in ('Mastered','Proven Mastered')
        and not english.focus_conflicts_with_required_daily(p_user_id,q.question_id,p_batch_date)
    ), chosen as materialized (
      select * from variants
      where variant_pick=1
      order by priority_bucket,tier desc,due desc,
               case when question_attempts=0 then 0 else 1 end,
               question_attempts,days_since_revision desc nulls last,concept_id
      limit v_missing
    ), numbered as (
      select c.*,
        coalesce((select max(sequence) from english.daily_focus_items
                  where user_id=p_user_id and batch_date=p_batch_date and lane='phrasal'),0)
        + row_number() over(order by priority_bucket,tier desc,due desc,
                            case when question_attempts=0 then 0 else 1 end,
                            question_attempts,days_since_revision desc nulls last,concept_id)::int seq
      from chosen c
    )
    insert into english.daily_focus_items(
      user_id,batch_date,lane,sequence,question_id,concept_key,reasons,selection_snapshot
    )
    select
      p_user_id,p_batch_date,'phrasal',seq,question_id,concept_id,
      array['Phrasal CI',ci_reason]::text[],
      jsonb_strip_nulls(jsonb_build_object(
        'source','phrasal_intelligence','buildVersion','language_v1','domain','phrasal',
        'conceptId',concept_id,'word',word,'questionFamily',question_family,
        'preferredFamily',preferred_family,'ciReason',ci_reason,'priorityBucket',priority_bucket,
        'tier',tier,'state',state,'due',due,'nextReview',next_review,
        'neverRevised',never_revised,'daysSinceRevision',days_since_revision,
        'recallWeak',recall_weak,'confusionWeak',confusion_weak,'recognitionWeak',recognition_weak,
        'starred',starred,'difficult',difficult,'questionAttempts',question_attempts
      ))
    from numbered
    on conflict do nothing;
  end if;

  perform english.reconcile_daily_focus(p_user_id,p_batch_date);

  select count(*) into v_grammar
  from english.daily_focus_items
  where user_id=p_user_id and batch_date=p_batch_date and lane='grammar';
  select count(*) into v_phrasal
  from english.daily_focus_items
  where user_id=p_user_id and batch_date=p_batch_date and lane='phrasal';

  return jsonb_build_object(
    'ok',true,'batchDate',p_batch_date,
    'grammar',v_grammar,'phrasal',v_phrasal,'languageTotal',v_grammar+v_phrasal,
    'exactTarget',(v_grammar=15 and v_phrasal=15)
  );
end;
$function$;

-- Refill any active batch that was temporarily short after the stricter conflict guard.
do $refill$
declare r record;
begin
  for r in
    select user_id,batch_date from english.daily_focus_batches where status='active'
  loop
    perform english.ensure_daily_focus_language_lanes(r.user_id,r.batch_date);
  end loop;
end;
$refill$;
