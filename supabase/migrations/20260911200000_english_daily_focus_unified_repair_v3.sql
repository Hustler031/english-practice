-- Daily Focus v3: unified Repair execution lane fed by the canonical Learning Need Engine.
-- New batches only. Existing frozen batches remain untouched.

alter table english.daily_focus_batches
  drop constraint if exists daily_focus_batches_repair_target_check;
alter table english.daily_focus_batches
  add constraint daily_focus_batches_repair_target_check
  check (repair_target>=0 and repair_target<=70);
alter table english.daily_focus_batches
  alter column repair_target set default 70;

create or replace function english.learning_need_repair_selection(
  p_user_id uuid,p_batch_date date,p_limit integer default 70
)
returns table(
  concept_key text,question_id text,primary_need text,need_tier integer,priority_score integer,
  reasons text[],state text,targeted_kind text,targeted_reason text,saved boolean,starred boolean,
  never_revised boolean,neglect_days integer,difficult boolean,recent_failures integer,
  confusion_count integer,in_fast_track boolean,last_attempt timestamptz,selection_lane text
)
language sql
stable
security definer
set search_path='pg_catalog','english','auth'
as $function$
with allc as materialized (
  select * from english.learning_need_candidates(p_user_id,p_batch_date)
), eligible as materialized (
  select c.*
  from allc c
  where not english.focus_conflicts_with_required_daily(p_user_id,c.question_id,p_batch_date)
), critical as materialized (
  select e.* from eligible e
  where e.need_tier<=2
  order by e.need_tier,e.priority_score desc,e.last_attempt nulls first,e.concept_key
  limit least(50,greatest(0,least(70,coalesce(p_limit,70))))
), rotation as materialized (
  select e.* from eligible e
  where e.need_tier>=3
    and (e.saved or e.starred)
    and (e.never_revised or e.neglect_days>=7)
    and not exists(select 1 from critical c where c.concept_key=e.concept_key)
  order by e.never_revised desc,e.neglect_days desc,e.priority_score desc,e.last_attempt nulls first,e.concept_key
  limit least(15,greatest(0,least(70,coalesce(p_limit,70))-(select count(*) from critical)))
), selected_seed as materialized (
  select c.*,'critical'::text selection_lane from critical c
  union all
  select r.*,'rotation'::text selection_lane from rotation r
), fill as materialized (
  select e.*,'adaptive_fill'::text selection_lane
  from eligible e
  where not exists(select 1 from selected_seed s where s.concept_key=e.concept_key)
  order by e.need_tier,e.priority_score desc,e.last_attempt nulls first,e.concept_key
  limit greatest(0,least(70,coalesce(p_limit,70))-(select count(*) from selected_seed))
)
select * from selected_seed
union all
select * from fill;
$function$;

revoke all on function english.learning_need_repair_selection(uuid,date,integer) from public,anon,authenticated;

create or replace function english.learning_need_repair_preview(p_user_id uuid,p_batch_date date,p_limit integer default 70)
returns jsonb
language sql
stable
security definer
set search_path='pg_catalog','english','auth'
as $function$
with allc as materialized (
  select * from english.learning_need_candidates(p_user_id,p_batch_date)
), selected as materialized (
  select * from english.learning_need_repair_selection(p_user_id,p_batch_date,p_limit)
), current_repair as materialized (
  select concept_key from english.daily_focus_items
  where user_id=p_user_id and batch_date=p_batch_date and lane='repair'
)
select jsonb_build_object(
  'ok',true,'batchDate',p_batch_date,'mode','canonical','routingChanged',false,
  'candidateConcepts',(select count(*) from allc),
  'selectedConcepts',(select count(*) from selected),
  'selectedCritical',(select count(*) from selected where selection_lane='critical'),
  'selectedAntiStarvation',(select count(*) from selected where selection_lane='rotation'),
  'selectedAdaptiveFill',(select count(*) from selected where selection_lane='adaptive_fill'),
  'selectedTier1',(select count(*) from selected where need_tier=1),
  'selectedTier2',(select count(*) from selected where need_tier=2),
  'selectedTier3Plus',(select count(*) from selected where need_tier>=3),
  'selectedTargeted',(select count(*) from selected where targeted_kind is not null),
  'selectedSaved',(select count(*) from selected where saved),
  'selectedStarred',(select count(*) from selected where starred),
  'selectedPW',(select count(*) from selected where reasons @> array['Persistent Weak']::text[]),
  'selectedWeak',(select count(*) from selected where reasons @> array['Weak']::text[]),
  'selectedFragileRisk',(select count(*) from selected where reasons @> array['Fragile Risk']::text[]),
  'currentRepairOverlap',(select count(*) from selected s join current_repair c using(concept_key)),
  'rescuedVsCurrentRepair',(select count(*) from selected s where not exists(select 1 from current_repair c where c.concept_key=s.concept_key))
);
$function$;

create or replace function english.create_daily_focus_v3(p_user_id uuid,p_batch_date date)
returns jsonb
language plpgsql
security definer
set search_path='pg_catalog','english','auth','public'
as $function$
declare
  v_repair integer:=0;
  v_coverage integer:=0;
  v_fast integer:=0;
begin
  if p_user_id is null or p_batch_date is null then
    raise exception 'user and batch date are required';
  end if;

  insert into english.daily_focus_batches(user_id,batch_date,status,repair_target,coverage_target,fast_track_target)
  values(p_user_id,p_batch_date,'active',70,70,50)
  on conflict(user_id,batch_date) do nothing;

  if exists(select 1 from english.daily_focus_items where user_id=p_user_id and batch_date=p_batch_date) then
    select count(*) filter(where lane='repair'),count(*) filter(where lane='coverage'),count(*) filter(where lane='fast_track')
      into v_repair,v_coverage,v_fast
    from english.daily_focus_items where user_id=p_user_id and batch_date=p_batch_date;
    return jsonb_build_object('ok',true,'existing',true,'version','v3','repair',v_repair,'coverage',v_coverage,'fastTrack',v_fast);
  end if;

  -- REPAIR: one concept, one slot. Learning need owns selection; review-date alone never admits an item.
  insert into english.daily_focus_items(
    user_id,batch_date,lane,sequence,question_id,concept_key,reasons,selection_snapshot
  )
  select
    p_user_id,p_batch_date,'repair',
    row_number() over(order by
      case s.selection_lane when 'critical' then 1 when 'rotation' then 2 else 3 end,
      s.need_tier,s.priority_score desc,s.last_attempt nulls first,s.concept_key
    )::int,
    s.question_id,s.concept_key,s.reasons,
    jsonb_strip_nulls(jsonb_build_object(
      'source','learning_need_engine','buildVersion','v3','repairSource','canonical',
      'primaryNeed',s.primary_need,'needTier',s.need_tier,'priorityScore',s.priority_score,
      'selectionLane',s.selection_lane,'state',s.state,'targetedKind',s.targeted_kind,
      'targetedReason',s.targeted_reason,'saved',s.saved,'starred',s.starred,
      'neverRevised',s.never_revised,'neglectDays',s.neglect_days,
      'difficult',s.difficult,'recentFailures',s.recent_failures,'confusionCount',s.confusion_count
    ))
  from english.learning_need_repair_selection(p_user_id,p_batch_date,70) s
  on conflict do nothing;

  -- COVERAGE: up to 20 previously-seen concepts with an untouched sibling question.
  with seen_concepts as (
    select english.focus_concept_key(qs.question_id) concept_key,max(ss.last_attempt) last_seen
    from english.questions qs
    join english.question_state ss
      on ss.user_id=p_user_id and ss.question_id=qs.question_id and coalesce(ss.attempts,0)>0
    where english.is_genuine_bank_question(qs)
    group by english.focus_concept_key(qs.question_id)
  ), pending as (
    select q.question_id,english.focus_concept_key(q.question_id) concept_key,sc.last_seen,
           coalesce(ce.confidence_score,0) confidence_score,ce.coverage_state,
           row_number() over(partition by english.focus_concept_key(q.question_id) order by q.question_id) concept_pick
    from english.questions q
    join seen_concepts sc on sc.concept_key=english.focus_concept_key(q.question_id)
    left join english.question_state s on s.user_id=p_user_id and s.question_id=q.question_id
    left join english.concept_evidence ce on ce.user_id=p_user_id and ce.concept_id=sc.concept_key
    where english.is_genuine_bank_question(q)
      and coalesce(s.attempts,0)=0
      and not coalesce(s.mastered,false)
      and not english.focus_conflicts_with_required_daily(p_user_id,q.question_id,p_batch_date)
      and not exists(
        select 1 from english.daily_focus_items f
        where f.user_id=p_user_id and f.batch_date=p_batch_date and f.concept_key=sc.concept_key
      )
  ), chosen as (
    select * from pending where concept_pick=1
    order by confidence_score,last_seen nulls first,question_id limit 20
  )
  insert into english.daily_focus_items(user_id,batch_date,lane,sequence,question_id,concept_key,reasons,selection_snapshot)
  select p_user_id,p_batch_date,'coverage',
         row_number() over(order by confidence_score,last_seen nulls first,question_id)::int,
         question_id,concept_key,array['Previously Seen Concept','Pending Sibling Question'],
         jsonb_strip_nulls(jsonb_build_object(
           'source','central_intelligence','buildVersion','v3','coverageKind','familiar_pending_sibling',
           'conceptCoverage',coverage_state,'conceptConfidence',confidence_score,'lastConceptExposure',last_seen
         ))
  from chosen
  on conflict do nothing;

  -- COVERAGE: 50 genuinely new canonical concepts, category-balanced.
  with current_new as (
    select coalesce(nullif(f.selection_snapshot->>'category',''),english.learning_category(q.topic)) category,count(*)::int cnt
    from english.daily_focus_items f
    join english.questions q on q.question_id=f.question_id
    where f.user_id=p_user_id and f.batch_date=p_batch_date and f.lane='coverage'
      and f.selection_snapshot->>'coverageKind'='new'
    group by 1
  ), raw as (
    select q.question_id,english.focus_concept_key(q.question_id) concept_key,english.learning_category(q.topic) category,
           row_number() over(partition by english.focus_concept_key(q.question_id) order by q.question_id) concept_pick
    from english.questions q
    left join english.question_state s on s.user_id=p_user_id and s.question_id=q.question_id
    where english.is_genuine_bank_question(q)
      and coalesce(s.attempts,0)=0
      and not coalesce(s.mastered,false)
      and not english.focus_conflicts_with_required_daily(p_user_id,q.question_id,p_batch_date)
      and not exists(
        select 1 from english.daily_focus_items f
        where f.user_id=p_user_id and f.batch_date=p_batch_date
          and f.concept_key=english.focus_concept_key(q.question_id)
      )
      and not exists(
        select 1 from english.concept_evidence ce
        where ce.user_id=p_user_id and ce.concept_id=english.focus_concept_key(q.question_id) and coalesce(ce.attempts,0)>0
      )
      and not exists(
        select 1 from english.question_state s2
        where s2.user_id=p_user_id and coalesce(s2.attempts,0)>0
          and english.focus_concept_key(s2.question_id)=english.focus_concept_key(q.question_id)
      )
  ), deduped as (
    select * from raw where concept_pick=1
  ), ranked as (
    select d.*,coalesce(c.cnt,0) existing_category_count,
           row_number() over(partition by d.category order by d.question_id) category_rank
    from deduped d left join current_new c on c.category=d.category
  ), chosen as (
    select * from ranked
    order by existing_category_count+category_rank,category,question_id limit 50
  ), numbered as (
    select *,coalesce((select max(sequence) from english.daily_focus_items
                       where user_id=p_user_id and batch_date=p_batch_date and lane='coverage'),0)
             +row_number() over(order by existing_category_count+category_rank,category,question_id)::int seq
    from chosen
  )
  insert into english.daily_focus_items(user_id,batch_date,lane,sequence,question_id,concept_key,reasons,selection_snapshot)
  select p_user_id,p_batch_date,'coverage',seq,question_id,concept_key,array['New Canonical Concept'],
         jsonb_build_object('source','central_intelligence','buildVersion','v3','coverageKind','new','category',category,
                            'balancedCategoryRank',category_rank,'existingCategoryCount',existing_category_count)
  from numbered where seq<=70
  on conflict do nothing;

  -- FAST TRACK: existing Central Intelligence mastery-verification queue; no local reinvention.
  with base as (
    select r.question_id,english.focus_concept_key(r.question_id) concept_key,r.fast_track_status,r.origins,
           r.last_route_reason,r.next_fast_track_check,r.updated_at,
           coalesce(ce.coverage_state,'unseen') concept_state,coalesce(ce.confidence_score,0) concept_confidence,
           case when r.fast_track_status='retention_watch' then 0 when r.fast_track_status='ready' then 1 else 2 end wait_ord
    from english.learning_route_state r
    join english.questions q on q.question_id=r.question_id and q.active
    left join english.concept_evidence ce on ce.user_id=p_user_id and ce.concept_id=english.focus_concept_key(r.question_id)
    where r.user_id=p_user_id and r.route='fast_track' and r.fast_track_status<>'mastered'
      and (r.fast_track_status='ready' or (r.fast_track_status in ('waiting','retention_watch') and r.next_fast_track_check<=now()))
      and nullif(english.route_targeted_reason(p_user_id,r.question_id),'') is null
      and not english.focus_conflicts_with_required_daily(p_user_id,r.question_id,p_batch_date)
      and not exists(
        select 1 from english.daily_focus_items f
        where f.user_id=p_user_id and f.batch_date=p_batch_date
          and (f.question_id=r.question_id or f.concept_key=english.focus_concept_key(r.question_id))
      )
  ), deduped as (
    select *,row_number() over(partition by concept_key order by
      case concept_state when 'weak' then 5 when 'retention_risk' then 4 when 'seen' then 3 when 'secure' then 2 when 'exam_ready' then 1 else 3 end desc,
      wait_ord,next_fast_track_check nulls first,updated_at,question_id) concept_pick
    from base
  ), chosen as (
    select * from deduped where concept_pick=1 order by
      case concept_state when 'weak' then 5 when 'retention_risk' then 4 when 'seen' then 3 when 'secure' then 2 when 'exam_ready' then 1 else 3 end desc,
      wait_ord,next_fast_track_check nulls first,updated_at,question_id limit 50
  )
  insert into english.daily_focus_items(user_id,batch_date,lane,sequence,question_id,concept_key,reasons,selection_snapshot)
  select p_user_id,p_batch_date,'fast_track',row_number() over(order by
      case concept_state when 'weak' then 5 when 'retention_risk' then 4 when 'seen' then 3 when 'secure' then 2 when 'exam_ready' then 1 else 3 end desc,
      wait_ord,next_fast_track_check nulls first,updated_at,question_id)::int,
    question_id,concept_key,array['Fast Track Mastery'],
    jsonb_build_object('source','existing_fast_track','buildVersion','v3','fastTrackStatus',fast_track_status,
                       'origins',origins,'reason',last_route_reason,'conceptCoverage',concept_state,'conceptConfidence',concept_confidence)
  from chosen
  on conflict do nothing;

  select count(*) filter(where lane='repair'),count(*) filter(where lane='coverage'),count(*) filter(where lane='fast_track')
    into v_repair,v_coverage,v_fast
  from english.daily_focus_items where user_id=p_user_id and batch_date=p_batch_date;

  update english.daily_focus_batches
  set repair_target=v_repair,coverage_target=v_coverage,fast_track_target=v_fast,updated_at=now()
  where user_id=p_user_id and batch_date=p_batch_date;

  return jsonb_build_object(
    'ok',true,'existing',false,'version','v3','repair',v_repair,'coverage',v_coverage,
    'fastTrack',v_fast,'total',v_repair+v_coverage+v_fast
  );
end;
$function$;

revoke all on function english.create_daily_focus_v3(uuid,date) from public,anon,authenticated;

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

  perform english.reconcile_daily_focus(p_user_id,v_batch.batch_date);
  return english.daily_focus_summary(p_user_id);
end;
$function$;

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
begin
  select * into v_batch
  from english.daily_focus_batches
  where user_id=p_user_id
  order by batch_date desc limit 1;

  if not found then return jsonb_build_object('ok',false,'reason','no-batch'); end if;

  select count(*),count(*) filter(where status='Completed'),
         count(*) filter(where lane='repair'),count(*) filter(where lane='repair' and status='Completed'),
         count(*) filter(where lane='coverage'),count(*) filter(where lane='coverage' and status='Completed'),
         count(*) filter(where lane='fast_track'),count(*) filter(where lane='fast_track' and status='Completed')
    into v_total,v_done,v_repair_total,v_repair_done,v_coverage_total,v_coverage_done,v_fast_total,v_fast_done
  from english.daily_focus_items
  where user_id=p_user_id and batch_date=v_batch.batch_date;

  return jsonb_build_object(
    'ok',true,'today',v_today,'batchDate',v_batch.batch_date,
    'carryover',(v_batch.batch_date<v_today and v_batch.status='active'),'status',v_batch.status,
    'total',v_total,'completed',v_done,'remaining',greatest(0,v_total-v_done),'nominalTarget',190,
    'lanes',jsonb_build_object(
      'repair',jsonb_build_object('target',v_repair_total,'nominalTarget',70,'completed',v_repair_done,
        'remaining',greatest(0,v_repair_total-v_repair_done),'done',(v_repair_total>0 and v_repair_done=v_repair_total)),
      'coverage',jsonb_build_object('target',v_coverage_total,'nominalTarget',70,'completed',v_coverage_done,
        'remaining',greatest(0,v_coverage_total-v_coverage_done),'done',(v_coverage_total>0 and v_coverage_done=v_coverage_total)),
      'fastTrack',jsonb_build_object('target',v_fast_total,'nominalTarget',50,'completed',v_fast_done,
        'remaining',greatest(0,v_fast_total-v_fast_done),'done',(v_fast_total>0 and v_fast_done=v_fast_total))
    )
  );
end;
$function$;
