-- Canonical Learning Need Engine (shadow only).
-- It centralizes Weak/PW/Fragile, Targeted, Saved and Starred signals without using due-today as an admission rule.

create or replace function english.learning_need_candidates(p_user_id uuid,p_batch_date date)
returns table(
  concept_key text,
  question_id text,
  primary_need text,
  need_tier integer,
  priority_score integer,
  reasons text[],
  state text,
  targeted_kind text,
  targeted_reason text,
  saved boolean,
  starred boolean,
  never_revised boolean,
  neglect_days integer,
  difficult boolean,
  recent_failures integer,
  confusion_count integer,
  in_fast_track boolean,
  last_attempt timestamptz
)
language sql
stable
security definer
set search_path='pg_catalog','english','auth'
as $function$
with saved as materialized (
  select * from english.saved_revision_candidates_all(p_user_id)
), starred as materialized (
  select * from english.starred_revision_candidates(p_user_id)
), raw as materialized (
  select
    q.question_id,
    english.focus_concept_key(q.question_id) concept_key,
    coalesce(s.status,'New') state,
    coalesce(s.attempts,0) attempts,
    coalesce(s.wrong,0) wrong,
    coalesce(s.accuracy,0) accuracy,
    s.last_attempt,
    coalesce(s.mastered,false) mastered,
    coalesce(d.difficult,false) difficult,
    (sv.question_id is not null) saved,
    (st.question_id is not null) starred,
    coalesce(sv.never_revised,false) saved_never,
    coalesce(st.never_revised,false) starred_never,
    sv.days_since_revision saved_days,
    st.days_since_revision starred_days,
    coalesce(r.route,'') route,
    coalesce(r.fast_track_status,'') fast_track_status,
    coalesce(r.pending_failure_decision,false) pending_failure_decision,
    coalesce(r.kept_failure_count,0) kept_failure_count,
    r.last_failure_at,
    case when r.route='targeted' then english.targeted_route_kind(r.metadata,r.origins) end targeted_kind,
    case when r.route='targeted' then coalesce(nullif(r.last_route_reason,''),'Targeted') end targeted_reason,
    coalesce(ce.recent_failures,0) recent_failures,
    coalesce(ce.confusion_count,0) confusion_count,
    coalesce(ce.confidence_score,0) concept_confidence
  from english.questions q
  left join english.question_state s on s.user_id=p_user_id and s.question_id=q.question_id
  left join english.difficult_state d on d.user_id=p_user_id and d.question_id=q.question_id
  left join english.learning_route_state r on r.user_id=p_user_id and r.question_id=q.question_id
  left join saved sv on sv.question_id=q.question_id
  left join starred st on st.question_id=q.question_id
  left join english.concept_evidence ce
    on ce.user_id=p_user_id and ce.concept_id=english.focus_concept_key(q.question_id)
  where q.active
    and english.question_visible_to_user(p_user_id,q.question_id)
    and not coalesce(s.mastered,false)
), eligible as materialized (
  select r.*,
    greatest(coalesce(r.saved_days,0),coalesce(r.starred_days,0)) neglect_days,
    (r.saved_never or r.starred_never) never_revised,
    (
      r.route='fast_track'
      and (
        r.pending_failure_decision
        or r.kept_failure_count>0
        or (r.last_failure_at is not null and r.last_failure_at>=now()-interval '7 days')
        or nullif(english.route_targeted_reason(p_user_id,r.question_id),'') is not null
      )
    ) fast_track_failure,
    (
      r.state='Fragile'
      and (
        r.wrong>=2
        or r.recent_failures>0
        or r.confusion_count>0
        or r.route='targeted'
        or r.saved
        or r.starred
        or r.difficult
      )
    ) fragile_learning_risk,
    (
      (r.saved or r.starred)
      and r.route<>'fast_track'
      and (
        r.saved_never or r.starred_never
        or greatest(coalesce(r.saved_days,0),coalesce(r.starred_days,0))>=7
        or r.difficult
        or r.state in ('Persistent Weak','Weak','Fragile','Learning','New')
      )
    ) intent_learning_need
  from raw r
  where
    r.state in ('Persistent Weak','Weak')
    or r.route='targeted'
    or (
      r.route='fast_track'
      and (
        r.pending_failure_decision
        or r.kept_failure_count>0
        or (r.last_failure_at is not null and r.last_failure_at>=now()-interval '7 days')
        or nullif(english.route_targeted_reason(p_user_id,r.question_id),'') is not null
      )
    )
    or (
      r.state='Fragile'
      and (
        r.wrong>=2 or r.recent_failures>0 or r.confusion_count>0
        or r.saved or r.starred or r.difficult
      )
    )
    or (
      (r.saved or r.starred)
      and r.route<>'fast_track'
      and r.state<>'Proven Mastered'
      and (
        r.saved_never or r.starred_never
        or greatest(coalesce(r.saved_days,0),coalesce(r.starred_days,0))>=7
        or r.difficult
        or r.state in ('Persistent Weak','Weak','Fragile','Learning','New')
      )
    )
), scored as materialized (
  select e.*,
    case
      when e.route='targeted' and e.targeted_kind='confusion' then 1
      when e.state='Persistent Weak' then 1
      when e.fast_track_failure then 1
      when e.recent_failures>=2 then 1
      when e.state='Weak' then 2
      when e.route='targeted' and e.targeted_kind in ('transfer_check','need_learning') then 2
      when e.fragile_learning_risk then 2
      when e.never_revised and (e.saved or e.starred) then 3
      when e.neglect_days>=14 and (e.saved or e.starred) then 3
      when e.difficult and (e.saved or e.starred) then 3
      else 4
    end need_tier,
    (
      case
        when e.route='targeted' and e.targeted_kind='confusion' then 1180
        when e.state='Persistent Weak' then 1160
        when e.fast_track_failure then 1140
        when e.recent_failures>=2 then 1120
        when e.state='Weak' then 1060
        when e.route='targeted' and e.targeted_kind='transfer_check' then 1040
        when e.route='targeted' and e.targeted_kind='need_learning' then 1020
        when e.fragile_learning_risk then 960
        when e.never_revised and (e.saved or e.starred) then 900
        when e.neglect_days>=14 and (e.saved or e.starred) then 860
        when e.difficult and (e.saved or e.starred) then 830
        when e.neglect_days>=7 and (e.saved or e.starred) then 780
        else 700
      end
      + least(80,greatest(0,e.recent_failures)*20)
      + least(60,greatest(0,e.confusion_count)*15)
      + case when e.saved and e.starred then 25 when e.saved or e.starred then 10 else 0 end
      + case when e.never_revised then 35 else least(35,greatest(0,e.neglect_days)) end
    )::int priority_score
  from eligible e
), concepts as materialized (
  select
    s.concept_key,
    min(s.need_tier) need_tier,
    max(s.priority_score) priority_score,
    bool_or(s.state='Persistent Weak') has_pw,
    bool_or(s.state='Weak') has_weak,
    bool_or(s.fragile_learning_risk) has_fragile_risk,
    bool_or(s.fast_track_failure) has_fast_failure,
    bool_or(s.route='targeted' and s.targeted_kind='confusion') has_confusion,
    bool_or(s.route='targeted' and s.targeted_kind='transfer_check') has_transfer,
    bool_or(s.route='targeted' and s.targeted_kind='need_learning') has_targeted_learning,
    bool_or(s.saved) saved,
    bool_or(s.starred) starred,
    bool_or(s.never_revised) never_revised,
    max(s.neglect_days) neglect_days,
    bool_or(s.difficult) difficult,
    max(s.recent_failures) recent_failures,
    max(s.confusion_count) confusion_count,
    bool_or(s.route='fast_track') in_fast_track,
    max(s.last_attempt) last_attempt,
    coalesce((array_agg(s.targeted_kind order by
      case s.targeted_kind when 'confusion' then 1 when 'transfer_check' then 2 when 'need_learning' then 3 when 'retention_check' then 4 else 5 end,
      s.priority_score desc) filter(where s.route='targeted'))[1],null) targeted_kind,
    coalesce((array_agg(s.targeted_reason order by
      case s.targeted_kind when 'confusion' then 1 when 'transfer_check' then 2 when 'need_learning' then 3 when 'retention_check' then 4 else 5 end,
      s.priority_score desc) filter(where s.route='targeted'))[1],null) targeted_reason
  from scored s
  group by s.concept_key
), representatives as materialized (
  select distinct on (s.concept_key)
    s.concept_key,s.question_id,s.state
  from scored s
  order by s.concept_key,
    case
      when s.route='targeted' and s.targeted_kind='confusion' then 0
      when s.route='targeted' then 1
      when s.state='Persistent Weak' then 2
      when s.state='Weak' then 3
      when s.fast_track_failure then 4
      when s.never_revised then 5
      else 6
    end,
    s.priority_score desc,
    s.last_attempt nulls first,
    s.question_id
)
select
  c.concept_key,
  r.question_id,
  case
    when c.has_confusion then 'Targeted Confusion'
    when c.has_pw then 'Persistent Weak'
    when c.has_fast_failure then 'Fast Track Failure'
    when c.has_weak then 'Weak'
    when c.has_transfer then 'Targeted Transfer'
    when c.has_targeted_learning then 'Targeted Learning'
    when c.has_fragile_risk then 'Fragile Risk'
    when c.never_revised and c.saved and c.starred then 'Saved + Starred Never Revised'
    when c.never_revised and c.saved then 'Saved Never Revised'
    when c.never_revised and c.starred then 'Starred Never Revised'
    when c.saved and c.starred then 'Saved + Starred Neglect'
    when c.saved then 'Saved Neglect'
    when c.starred then 'Starred Neglect'
    else 'Learning Need'
  end primary_need,
  c.need_tier,
  c.priority_score,
  array_remove(array[
    case when c.has_pw then 'Persistent Weak' end,
    case when c.has_weak then 'Weak' end,
    case when c.has_fragile_risk then 'Fragile Risk' end,
    case when c.has_confusion then 'Targeted Confusion' end,
    case when c.has_transfer then 'Targeted Transfer' end,
    case when c.has_targeted_learning then 'Targeted Learning' end,
    case when c.has_fast_failure then 'Fast Track Failure' end,
    case when c.saved then 'My Saved' end,
    case when c.starred then 'Starred' end,
    case when c.never_revised then 'Never Revised' end,
    case when c.neglect_days>=14 then 'Neglected 14d+' when c.neglect_days>=7 then 'Neglected 7d+' end,
    case when c.difficult then 'Difficult' end
  ],null) reasons,
  r.state,
  c.targeted_kind,
  c.targeted_reason,
  c.saved,
  c.starred,
  c.never_revised,
  c.neglect_days,
  c.difficult,
  c.recent_failures,
  c.confusion_count,
  c.in_fast_track,
  c.last_attempt
from concepts c
join representatives r using(concept_key)
order by c.need_tier,c.priority_score desc,c.last_attempt nulls first,c.concept_key;
$function$;

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
  where (e.saved or e.starred)
    and (e.never_revised or e.neglect_days>=7)
    and not exists(select 1 from critical c where c.concept_key=e.concept_key)
  order by e.never_revised desc,e.neglect_days desc,e.priority_score desc,e.concept_key
  limit least(15,greatest(0,least(70,coalesce(p_limit,70))-(select count(*) from critical)))
), selected_seed as materialized (
  select * from critical
  union all
  select * from rotation
), fill as materialized (
  select e.*
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
  'selectedTier1',(select count(*) from selected where need_tier=1),
  'selectedTier2',(select count(*) from selected where need_tier=2),
  'selectedRotation',(select count(*) from selected where (saved or starred) and (never_revised or neglect_days>=7)),
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
      'targetedKind',s.targeted_kind,'saved',s.saved,'starred',s.starred,
      'neverRevised',s.never_revised,'neglectDays',s.neglect_days
    ) order by s.need_tier,s.priority_score desc,s.concept_key)
    from selected s
  ),'[]'::jsonb)
);
$function$;

revoke all on function english.learning_need_candidates(uuid,date) from public,anon,authenticated;
revoke all on function english.learning_need_repair_preview(uuid,date,integer) from public,anon,authenticated;
