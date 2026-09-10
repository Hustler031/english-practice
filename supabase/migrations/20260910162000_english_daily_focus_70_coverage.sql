-- Daily Focus coverage v2
-- Keep Repair 50 and Fast Track 50 unchanged.
-- Bank Coverage becomes 70: 20 pending sibling questions from previously seen
-- canonical concepts + 50 genuinely new canonical concepts.

alter table english.daily_focus_batches
  drop constraint if exists daily_focus_batches_coverage_target_check;
alter table english.daily_focus_batches
  add constraint daily_focus_batches_coverage_target_check
  check (coverage_target between 0 and 70);
alter table english.daily_focus_batches
  alter column coverage_target set default 70;

alter table english.daily_focus_items
  drop constraint if exists daily_focus_items_sequence_check;
alter table english.daily_focus_items
  add constraint daily_focus_items_sequence_check
  check (sequence between 1 and 70);

create or replace function english.rebalance_daily_focus_coverage_v2(
  p_user_id uuid,
  p_batch_date date
)
returns jsonb
language plpgsql
security definer
set search_path='pg_catalog','english','auth','public'
as $function$
declare
  v_total integer:=0;
  v_completed integer:=0;
  v_familiar integer:=0;
  v_new integer:=0;
  v_new_need integer:=0;
begin
  if p_user_id is null or p_batch_date is null then
    raise exception 'user and batch date are required';
  end if;

  if not exists(
    select 1 from english.daily_focus_batches
    where user_id=p_user_id and batch_date=p_batch_date
  ) then
    return jsonb_build_object('ok',false,'reason','no-batch');
  end if;

  -- Do not rewrite historical completed batches. Current/active batches are eligible.
  if p_batch_date < date '2026-09-10'
     and exists(
       select 1 from english.daily_focus_batches
       where user_id=p_user_id and batch_date=p_batch_date and status='completed'
     ) then
    return jsonb_build_object('ok',true,'unchanged',true,'reason','historical-complete');
  end if;

  select count(*),count(*) filter(where status='Completed')
    into v_total,v_completed
  from english.daily_focus_items
  where user_id=p_user_id and batch_date=p_batch_date and lane='coverage';

  -- Fresh batches can be safely rebuilt before the learner starts them. This fixes
  -- the original familiar selection, which selected an already-attempted question
  -- instead of an unattempted sibling from the same previously seen concept.
  if v_total>0 and v_completed=0 then
    delete from english.daily_focus_items
    where user_id=p_user_id and batch_date=p_batch_date and lane='coverage';

    with seen_concepts as (
      select english.focus_concept_key(qs.question_id) concept_key,
             max(ss.last_attempt) last_seen
      from english.questions qs
      join english.question_state ss
        on ss.user_id=p_user_id
       and ss.question_id=qs.question_id
       and coalesce(ss.attempts,0)>0
      where english.is_genuine_bank_question(qs)
      group by english.focus_concept_key(qs.question_id)
    ), pending as (
      select q.question_id,
             english.focus_concept_key(q.question_id) concept_key,
             sc.last_seen,
             coalesce(ce.confidence_score,0) confidence_score,
             ce.coverage_state,
             row_number() over(
               partition by english.focus_concept_key(q.question_id)
               order by q.question_id
             ) concept_pick
      from english.questions q
      join seen_concepts sc
        on sc.concept_key=english.focus_concept_key(q.question_id)
      left join english.question_state s
        on s.user_id=p_user_id and s.question_id=q.question_id
      left join english.concept_evidence ce
        on ce.user_id=p_user_id and ce.concept_id=sc.concept_key
      where english.is_genuine_bank_question(q)
        and coalesce(s.attempts,0)=0
        and not coalesce(s.mastered,false)
        and not english.focus_conflicts_with_required_daily(p_user_id,q.question_id,p_batch_date)
        and not exists(
          select 1 from english.daily_focus_items f
          where f.user_id=p_user_id
            and f.batch_date=p_batch_date
            and f.lane<>'coverage'
            and f.concept_key=sc.concept_key
        )
    ), chosen as (
      select *
      from pending
      where concept_pick=1
      order by confidence_score,last_seen nulls first,question_id
      limit 20
    )
    insert into english.daily_focus_items(
      user_id,batch_date,lane,sequence,question_id,concept_key,reasons,selection_snapshot
    )
    select p_user_id,p_batch_date,'coverage',
           row_number() over(order by confidence_score,last_seen nulls first,question_id)::int,
           question_id,concept_key,
           array['Previously Seen Concept','Pending Sibling Question'],
           jsonb_strip_nulls(jsonb_build_object(
             'source','central_intelligence',
             'coverageKind','familiar_pending_sibling',
             'conceptCoverage',coverage_state,
             'conceptConfidence',confidence_score,
             'lastConceptExposure',last_seen
           ))
    from chosen
    on conflict do nothing;
  end if;

  select count(*) filter(
           where selection_snapshot->>'coverageKind' in ('familiar','familiar_pending_sibling')
         ),
         count(*) filter(where selection_snapshot->>'coverageKind'='new')
    into v_familiar,v_new
  from english.daily_focus_items
  where user_id=p_user_id and batch_date=p_batch_date and lane='coverage';

  -- Existing in-progress/completed-today v1 batches are preserved. We only append
  -- enough genuinely new concepts to move the new-concept quota from 30 to 50.
  v_new_need:=greatest(0,50-v_new);

  if v_new_need>0 then
    with current_new as (
      select coalesce(
               nullif(f.selection_snapshot->>'category',''),
               english.learning_category(q.topic)
             ) category,
             count(*)::int cnt
      from english.daily_focus_items f
      join english.questions q on q.question_id=f.question_id
      where f.user_id=p_user_id
        and f.batch_date=p_batch_date
        and f.lane='coverage'
        and f.selection_snapshot->>'coverageKind'='new'
      group by 1
    ), raw as (
      select q.question_id,
             english.focus_concept_key(q.question_id) concept_key,
             english.learning_category(q.topic) category,
             row_number() over(
               partition by english.focus_concept_key(q.question_id)
               order by q.question_id
             ) concept_pick
      from english.questions q
      left join english.question_state s
        on s.user_id=p_user_id and s.question_id=q.question_id
      where english.is_genuine_bank_question(q)
        and coalesce(s.attempts,0)=0
        and not coalesce(s.mastered,false)
        and not english.focus_conflicts_with_required_daily(p_user_id,q.question_id,p_batch_date)
        and not exists(
          select 1 from english.daily_focus_items f
          where f.user_id=p_user_id
            and f.batch_date=p_batch_date
            and f.concept_key=english.focus_concept_key(q.question_id)
        )
        and not exists(
          select 1 from english.concept_evidence ce
          where ce.user_id=p_user_id
            and ce.concept_id=english.focus_concept_key(q.question_id)
            and coalesce(ce.attempts,0)>0
        )
        and not exists(
          select 1 from english.question_state s2
          where s2.user_id=p_user_id
            and coalesce(s2.attempts,0)>0
            and english.focus_concept_key(s2.question_id)=english.focus_concept_key(q.question_id)
        )
    ), deduped as (
      select * from raw where concept_pick=1
    ), ranked as (
      select d.*,
             coalesce(c.cnt,0) existing_category_count,
             row_number() over(partition by d.category order by d.question_id) category_rank
      from deduped d
      left join current_new c on c.category=d.category
    ), chosen as (
      select *
      from ranked
      order by existing_category_count+category_rank,category,question_id
      limit v_new_need
    ), numbered as (
      select *,
             coalesce((
               select max(sequence)
               from english.daily_focus_items
               where user_id=p_user_id and batch_date=p_batch_date and lane='coverage'
             ),0)
             + row_number() over(
                 order by existing_category_count+category_rank,category,question_id
               )::int seq
      from chosen
    )
    insert into english.daily_focus_items(
      user_id,batch_date,lane,sequence,question_id,concept_key,reasons,selection_snapshot
    )
    select p_user_id,p_batch_date,'coverage',seq,question_id,concept_key,
           array['New Canonical Concept'],
           jsonb_build_object(
             'source','central_intelligence',
             'coverageKind','new',
             'category',category,
             'balancedCategoryRank',category_rank,
             'existingCategoryCount',existing_category_count
           )
    from numbered
    where seq<=70
    on conflict do nothing;
  end if;

  select count(*),
         count(*) filter(
           where selection_snapshot->>'coverageKind' in ('familiar','familiar_pending_sibling')
         ),
         count(*) filter(where selection_snapshot->>'coverageKind'='new')
    into v_total,v_familiar,v_new
  from english.daily_focus_items
  where user_id=p_user_id and batch_date=p_batch_date and lane='coverage';

  update english.daily_focus_batches b
  set coverage_target=v_total,
      status=case
        when exists(
          select 1 from english.daily_focus_items f
          where f.user_id=b.user_id and f.batch_date=b.batch_date and f.status='New'
        ) then 'active' else 'completed' end,
      completed_at=case
        when exists(
          select 1 from english.daily_focus_items f
          where f.user_id=b.user_id and f.batch_date=b.batch_date and f.status='New'
        ) then null else coalesce(b.completed_at,now()) end,
      updated_at=now()
  where b.user_id=p_user_id and b.batch_date=p_batch_date;

  return jsonb_build_object(
    'ok',true,
    'coverageTotal',v_total,
    'familiar',v_familiar,
    'newCanonical',v_new
  );
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
  order by batch_date desc
  limit 1;

  if not found then
    return jsonb_build_object('ok',false,'reason','no-batch');
  end if;

  select count(*),count(*) filter(where status='Completed'),
         count(*) filter(where lane='repair'),count(*) filter(where lane='repair' and status='Completed'),
         count(*) filter(where lane='coverage'),count(*) filter(where lane='coverage' and status='Completed'),
         count(*) filter(where lane='fast_track'),count(*) filter(where lane='fast_track' and status='Completed')
    into v_total,v_done,v_repair_total,v_repair_done,v_coverage_total,v_coverage_done,v_fast_total,v_fast_done
  from english.daily_focus_items
  where user_id=p_user_id and batch_date=v_batch.batch_date;

  return jsonb_build_object(
    'ok',true,
    'today',v_today,
    'batchDate',v_batch.batch_date,
    'carryover',(v_batch.batch_date<v_today and v_batch.status='active'),
    'status',v_batch.status,
    'total',v_total,
    'completed',v_done,
    'remaining',greatest(0,v_total-v_done),
    'nominalTarget',170,
    'lanes',jsonb_build_object(
      'repair',jsonb_build_object(
        'target',v_repair_total,'nominalTarget',50,'completed',v_repair_done,
        'remaining',greatest(0,v_repair_total-v_repair_done),
        'done',(v_repair_total>0 and v_repair_done=v_repair_total)
      ),
      'coverage',jsonb_build_object(
        'target',v_coverage_total,'nominalTarget',70,'completed',v_coverage_done,
        'remaining',greatest(0,v_coverage_total-v_coverage_done),
        'done',(v_coverage_total>0 and v_coverage_done=v_coverage_total)
      ),
      'fastTrack',jsonb_build_object(
        'target',v_fast_total,'nominalTarget',50,'completed',v_fast_done,
        'remaining',greatest(0,v_fast_total-v_fast_done),
        'done',(v_fast_total>0 and v_fast_done=v_fast_total)
      )
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
begin
  if p_user_id is null then
    raise exception 'Authentication required';
  end if;

  perform pg_advisory_xact_lock(
    hashtext('english.ensure_daily_focus'),
    hashtext(p_user_id::text)
  );

  select * into v_batch
  from english.daily_focus_batches
  where user_id=p_user_id
  order by batch_date desc
  limit 1;

  if not found then
    perform english.create_daily_focus(p_user_id,v_today);
  else
    perform english.reconcile_daily_focus(p_user_id,v_batch.batch_date);
    select * into v_batch
    from english.daily_focus_batches
    where user_id=p_user_id and batch_date=v_batch.batch_date;

    if v_batch.status='completed' and v_batch.batch_date<v_today then
      perform english.create_daily_focus(p_user_id,v_today);
    end if;
  end if;

  select * into v_batch
  from english.daily_focus_batches
  where user_id=p_user_id
  order by batch_date desc
  limit 1;

  perform english.rebalance_daily_focus_coverage_v2(p_user_id,v_batch.batch_date);
  perform english.reconcile_daily_focus(p_user_id,v_batch.batch_date);

  return english.daily_focus_summary(p_user_id);
end;
$function$;
