-- Repair shadow policy: 50 critical learning needs + up to 15 true anti-starvation items + adaptive fill to 70.
-- Rotation deliberately excludes tier 1/2 so old Saved/Starred items cannot be crowded out by risk items already represented in critical selection.

create or replace function english.learning_need_repair_preview(p_user_id uuid,p_batch_date date,p_limit integer default 70)
returns jsonb
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
  select *, 'critical'::text selection_lane from critical
  union all
  select *, 'rotation'::text selection_lane from rotation
), fill as materialized (
  select e.*, 'adaptive_fill'::text selection_lane
  from eligible e
  where not exists(select 1 from selected_seed s where s.concept_key=e.concept_key)
  order by e.need_tier,e.priority_score desc,e.last_attempt nulls first,e.concept_key
  limit greatest(0,least(70,coalesce(p_limit,70))-(select count(*) from selected_seed))
), selected as materialized (
  select * from selected_seed
  union all
  select * from fill
), current_repair as materialized (
  select concept_key from english.daily_focus_items
  where user_id=p_user_id and batch_date=p_batch_date and lane='repair'
)
select jsonb_build_object(
  'ok',true,
  'batchDate',p_batch_date,
  'mode','shadow',
  'routingChanged',false,
  'candidateConcepts',(select count(*) from allc),
  'eligibleConcepts',(select count(*) from eligible),
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
  'rescuedVsCurrentRepair',(select count(*) from selected s where not exists(select 1 from current_repair c where c.concept_key=s.concept_key)),
  'selection',coalesce((
    select jsonb_agg(jsonb_build_object(
      'conceptKey',s.concept_key,'questionId',s.question_id,'primaryNeed',s.primary_need,
      'tier',s.need_tier,'score',s.priority_score,'reasons',s.reasons,
      'selectionLane',s.selection_lane,
      'targetedKind',s.targeted_kind,'saved',s.saved,'starred',s.starred,
      'neverRevised',s.never_revised,'neglectDays',s.neglect_days
    ) order by
      case s.selection_lane when 'critical' then 1 when 'rotation' then 2 else 3 end,
      s.need_tier,s.priority_score desc,s.concept_key)
    from selected s
  ),'[]'::jsonb)
);
$function$;
