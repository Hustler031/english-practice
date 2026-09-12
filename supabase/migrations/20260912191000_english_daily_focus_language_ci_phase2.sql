-- Phase 2: add a CI-owned 15 Grammar + 15 Phrasal lane to Daily Focus without rebuilding existing core lanes.
-- Also make Daily Confusion reopen at the least-attempted item (first unanswered during an active round).

alter table english.daily_focus_items
  drop constraint if exists daily_focus_items_lane_check;
alter table english.daily_focus_items
  add constraint daily_focus_items_lane_check
  check (lane = any (array['repair'::text,'coverage'::text,'fast_track'::text,'grammar'::text,'phrasal'::text]));

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
        and not exists(
          select 1 from english.grammar_daily_items d
          where d.batch_date=p_batch_date
            and english.grammar_concept_id(d.rule_key)=english.grammar_concept_id(v.rule_key)
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
        and not exists(
          select 1 from english.phrasal_daily_items d
          where d.batch_date=p_batch_date and d.concept_id=c.concept_id
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

revoke all on function english.ensure_daily_focus_language_lanes(uuid,date) from public,anon,authenticated;

create or replace function english.daily_focus_summary(p_user_id uuid)
returns jsonb
language plpgsql
security definer
set search_path='pg_catalog','english','auth'
as $function$
declare
  v_today date:=(now() at time zone 'Asia/Kolkata')::date;
  v_batch english.daily_focus_batches%rowtype;
  v_done integer:=0; v_total integer:=0;
  v_repair_done integer:=0; v_repair_total integer:=0;
  v_coverage_done integer:=0; v_coverage_total integer:=0;
  v_fast_done integer:=0; v_fast_total integer:=0;
  v_grammar_done integer:=0; v_grammar_total integer:=0;
  v_phrasal_done integer:=0; v_phrasal_total integer:=0;
  v_is_v3 boolean:=false;
  v_base_target integer:=170;
begin
  select * into v_batch
  from english.daily_focus_batches
  where user_id=p_user_id
  order by batch_date desc limit 1;

  if not found then return jsonb_build_object('ok',false,'reason','no-batch'); end if;

  select count(*),count(*) filter(where status='Completed'),
         count(*) filter(where lane='repair'),count(*) filter(where lane='repair' and status='Completed'),
         count(*) filter(where lane='coverage'),count(*) filter(where lane='coverage' and status='Completed'),
         count(*) filter(where lane='fast_track'),count(*) filter(where lane='fast_track' and status='Completed'),
         count(*) filter(where lane='grammar'),count(*) filter(where lane='grammar' and status='Completed'),
         count(*) filter(where lane='phrasal'),count(*) filter(where lane='phrasal' and status='Completed')
    into v_total,v_done,v_repair_total,v_repair_done,v_coverage_total,v_coverage_done,v_fast_total,v_fast_done,
         v_grammar_total,v_grammar_done,v_phrasal_total,v_phrasal_done
  from english.daily_focus_items
  where user_id=p_user_id and batch_date=v_batch.batch_date;

  select exists(
    select 1 from english.daily_focus_items f
    where f.user_id=p_user_id and f.batch_date=v_batch.batch_date and f.lane='repair'
      and f.selection_snapshot->>'source'='learning_need_engine'
      and f.selection_snapshot->>'buildVersion'='v3'
  ) into v_is_v3;

  v_base_target:=case when v_is_v3 then 190 else 170 end;

  return jsonb_build_object(
    'ok',true,'today',v_today,'batchDate',v_batch.batch_date,
    'carryover',(v_batch.batch_date<v_today and v_batch.status='active'),'status',v_batch.status,
    'total',v_total,'completed',v_done,'remaining',greatest(0,v_total-v_done),
    'nominalTarget',v_base_target + case when (v_grammar_total+v_phrasal_total)>0 then 30 else 0 end,
    'buildVersion',case when v_is_v3 then 'v3' else 'legacy' end,
    'languageIntegrated',((v_grammar_total+v_phrasal_total)>0),
    'lanes',jsonb_build_object(
      'repair',jsonb_build_object('target',v_repair_total,'nominalTarget',case when v_is_v3 then 70 else 50 end,'completed',v_repair_done,
        'remaining',greatest(0,v_repair_total-v_repair_done),'done',(v_repair_total>0 and v_repair_done=v_repair_total)),
      'coverage',jsonb_build_object('target',v_coverage_total,'nominalTarget',70,'completed',v_coverage_done,
        'remaining',greatest(0,v_coverage_total-v_coverage_done),'done',(v_coverage_total>0 and v_coverage_done=v_coverage_total)),
      'fastTrack',jsonb_build_object('target',v_fast_total,'nominalTarget',50,'completed',v_fast_done,
        'remaining',greatest(0,v_fast_total-v_fast_done),'done',(v_fast_total>0 and v_fast_done=v_fast_total)),
      'grammar',jsonb_build_object('target',v_grammar_total,'nominalTarget',15,'completed',v_grammar_done,
        'remaining',greatest(0,v_grammar_total-v_grammar_done),'done',(v_grammar_total=15 and v_grammar_done=v_grammar_total)),
      'phrasal',jsonb_build_object('target',v_phrasal_total,'nominalTarget',15,'completed',v_phrasal_done,
        'remaining',greatest(0,v_phrasal_total-v_phrasal_done),'done',(v_phrasal_total=15 and v_phrasal_done=v_phrasal_total)),
      'language',jsonb_build_object('target',v_grammar_total+v_phrasal_total,'nominalTarget',30,'completed',v_grammar_done+v_phrasal_done,
        'remaining',greatest(0,(v_grammar_total+v_phrasal_total)-(v_grammar_done+v_phrasal_done)),
        'done',(v_grammar_total=15 and v_phrasal_total=15 and v_grammar_done=v_grammar_total and v_phrasal_done=v_phrasal_total))
    )
  );
end;
$function$;

create or replace function english.ensure_daily_focus(p_user_id uuid)
returns jsonb
language plpgsql
security definer
set search_path='pg_catalog','english','auth','public'
as $function$
declare
  v_today date:=(now() at time zone 'Asia/Kolkata')::date;
  v_batch english.daily_focus_batches%rowtype;
  v_is_v3 boolean:=false;
  v_legacy_familiar integer:=0;
  v_new_canonical integer:=0;
begin
  if p_user_id is null then raise exception 'Authentication required'; end if;

  perform pg_advisory_xact_lock(hashtext('english.ensure_daily_focus'),hashtext(p_user_id::text));

  select * into v_batch
  from english.daily_focus_batches
  where user_id=p_user_id
  order by batch_date desc limit 1;

  if not found then
    perform english.create_daily_focus_v3(p_user_id,v_today);
  else
    perform english.reconcile_daily_focus(p_user_id,v_batch.batch_date);
    select * into v_batch from english.daily_focus_batches
    where user_id=p_user_id and batch_date=v_batch.batch_date;

    if v_batch.status='completed' and v_batch.batch_date<v_today then
      perform english.create_daily_focus_v3(p_user_id,v_today);
    end if;
  end if;

  select * into v_batch
  from english.daily_focus_batches
  where user_id=p_user_id
  order by batch_date desc limit 1;

  select exists(
    select 1 from english.daily_focus_items f
    where f.user_id=p_user_id and f.batch_date=v_batch.batch_date and f.lane='repair'
      and f.selection_snapshot->>'source'='learning_need_engine'
      and f.selection_snapshot->>'buildVersion'='v3'
  ) into v_is_v3;

  if not v_is_v3 then
    select
      count(*) filter(where selection_snapshot->>'coverageKind'='familiar'),
      count(*) filter(where selection_snapshot->>'coverageKind'='new')
    into v_legacy_familiar,v_new_canonical
    from english.daily_focus_items
    where user_id=p_user_id and batch_date=v_batch.batch_date and lane='coverage';

    if coalesce(v_legacy_familiar,0)>0 or coalesce(v_new_canonical,0)<50 then
      perform english.rebalance_daily_focus_coverage_v2(p_user_id,v_batch.batch_date);
    end if;
  end if;

  perform english.ensure_daily_focus_language_lanes(p_user_id,v_batch.batch_date);
  perform english.reconcile_daily_focus(p_user_id,v_batch.batch_date);
  return english.daily_focus_summary(p_user_id);
end;
$function$;

create or replace function public.english_get_daily_focus_lane(p_lane text)
returns jsonb
language plpgsql
security definer
set search_path='pg_catalog','public','english','auth'
as $function$
declare
  uid uuid:=auth.uid();
  v_lane text:=lower(btrim(coalesce(p_lane,'')));
  v_summary jsonb;
  v_batch date;
  outv jsonb;
begin
  if uid is null then raise exception 'Authentication required'; end if;
  if v_lane not in ('repair','coverage','fast_track','grammar','phrasal','language') then
    raise exception 'Unknown Daily Focus lane';
  end if;

  v_summary:=english.ensure_daily_focus(uid);
  v_batch:=(v_summary->>'batchDate')::date;

  select coalesce(jsonb_agg(
    english.question_payload(uid,f.question_id)
    || jsonb_build_object(
      'dailyFocus',true,
      'dailyFocusLane',f.lane,
      'dailyFocusSequence',f.sequence,
      'dailyFocusBatchDate',f.batch_date,
      'dailyFocusReasons',f.reasons,
      'selectionReason',array_to_string(f.reasons,' · '),
      'dailyFocusSnapshot',f.selection_snapshot
    )
    || case when f.lane='fast_track' then jsonb_strip_nulls(jsonb_build_object(
      'fastTrack',true,
      'fastTrackStatus',r.fast_track_status,
      'fastTrackOrigins',r.origins,
      'fastTrackReason',r.last_route_reason,
      'fastTrackNextCheck',r.next_fast_track_check,
      'fastTrackFailureDecision',r.pending_failure_decision
    )) else '{}'::jsonb end
    order by
      case when v_lane='language' then f.sequence else f.sequence end,
      case f.lane when 'grammar' then 1 when 'phrasal' then 2 else 1 end
  ),'[]'::jsonb) into outv
  from english.daily_focus_items f
  left join english.learning_route_state r on r.user_id=f.user_id and r.question_id=f.question_id
  where f.user_id=uid and f.batch_date=v_batch and f.status='New'
    and ((v_lane='language' and f.lane in ('grammar','phrasal')) or (v_lane<>'language' and f.lane=v_lane));

  return outv;
end;
$function$;

create or replace function public.english_get_confusion_quiz()
returns jsonb
language plpgsql
stable security definer
set search_path='pg_catalog','public','english','auth'
as $function$
declare
  uid uuid:=auth.uid();
  v_day date:=(now() at time zone 'Asia/Kolkata')::date;
  outv jsonb;
begin
  if uid is null then raise exception 'Authentication required'; end if;

  with attempt_counts as (
    select a.question_id,count(*)::int attempt_count
    from english.attempts a
    where a.user_id=uid
      and lower(coalesce(a.module,''))='confusion'
      and (a.attempted_at at time zone 'Asia/Kolkata')::date=v_day
    group by a.question_id
  )
  select coalesce(jsonb_agg(
    english.question_payload(uid,i.question_id) || jsonb_build_object(
      'id',i.question_id,
      'centralQuestionId',i.question_id,
      'bankId',i.bank_id,
      'confusionCategory',i.category,
      'pairCluster',i.pair_cluster,
      'slot',i.slot,
      'confusionAttemptCount',coalesce(ac.attempt_count,0)
    ) order by coalesce(ac.attempt_count,0),i.slot
  ),'[]'::jsonb) into outv
  from english.daily_confusion_items i
  join english.questions q on q.question_id=i.question_id and q.active
  left join attempt_counts ac on ac.question_id=i.question_id
  where i.batch_date=v_day and i.active;

  return outv;
end;
$function$;

grant execute on function public.english_get_daily_focus_lane(text) to authenticated;
grant execute on function public.english_get_confusion_quiz() to authenticated;

-- Backfill only currently active Focus batches. Existing core rows and completion evidence are preserved.
do $backfill$
declare r record;
begin
  for r in
    select user_id,batch_date from english.daily_focus_batches where status='active'
  loop
    perform english.ensure_daily_focus_language_lanes(r.user_id,r.batch_date);
  end loop;
end;
$backfill$;
