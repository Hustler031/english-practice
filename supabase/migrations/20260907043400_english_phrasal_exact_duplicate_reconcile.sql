-- Consolidate exact Phrasal Daily snapshot duplicates onto permanent question identities.
-- Attempt rows and learner events are preserved; duplicate question rows remain as
-- inactive historical shells so foreign-key history is not destroyed.

update english.attempts a
set question_id=x.canonical_question_id
from english.phrasal_question_aliases x
where a.question_id=x.alias_question_id;

update english.daily_current d
set question_id=x.canonical_question_id
from english.phrasal_question_aliases x
where d.question_id=x.alias_question_id
  and not exists(
    select 1 from english.daily_current z
    where z.user_id=d.user_id and z.question_id=x.canonical_question_id
  );

insert into english.question_concept_mappings(
  question_id,concept_id,mapping_confidence,mapping_method,review_status,relation_type
)
select distinct x.canonical_question_id,q.concept_id,1,'phrasal_identity_reconcile','mapped','primary'
from english.phrasal_question_aliases x
join english.questions q on q.question_id=x.canonical_question_id
join english.concepts c on c.concept_id=q.concept_id and c.active
where q.concept_id is not null
on conflict(question_id) do nothing;

insert into english.phrasal_question_variants(
  question_id,concept_id,sense_key,question_family,variant_key,variant_fingerprint,
  generator_provider,critic_provider,quality_score,critic_decision,repair_count,metadata,created_at
)
select x.canonical_question_id,v.concept_id,v.sense_key,v.question_family,v.variant_key,v.variant_fingerprint,
       v.generator_provider,v.critic_provider,v.quality_score,v.critic_decision,v.repair_count,
       coalesce(v.metadata,'{}'::jsonb)||jsonb_build_object('reconciledFrom',v.question_id),v.created_at
from english.phrasal_question_variants v
join english.phrasal_question_aliases x on x.alias_question_id=v.question_id
on conflict do nothing;

insert into english.difficult_state(user_id,question_id,difficult,updated_at)
select d.user_id,x.canonical_question_id,bool_or(d.difficult),max(d.updated_at)
from english.difficult_state d
join english.phrasal_question_aliases x on x.alias_question_id=d.question_id
group by d.user_id,x.canonical_question_id
on conflict(user_id,question_id) do update
set difficult=english.difficult_state.difficult or excluded.difficult,
    updated_at=greatest(english.difficult_state.updated_at,excluded.updated_at);

insert into english.star_events(user_id,question_id,event_at,starred_date,day_no,action,source_row)
select s.user_id,x.canonical_question_id,s.event_at,s.starred_date,s.day_no,s.action,s.source_row
from english.star_events s
join english.phrasal_question_aliases x on x.alias_question_id=s.question_id
on conflict(user_id,question_id,event_at,action) do nothing;

update english.mastery_events m
set question_id=x.canonical_question_id
from english.phrasal_question_aliases x
where m.question_id=x.alias_question_id;

update english.learning_route_events e
set question_id=x.canonical_question_id
from english.phrasal_question_aliases x
where e.question_id=x.alias_question_id;

with candidates as (
  select r.*,coalesce(x.canonical_question_id,r.question_id) canonical_question_id
  from english.learning_route_state r
  left join english.phrasal_question_aliases x on x.alias_question_id=r.question_id
  where x.alias_question_id is not null
     or exists(
       select 1 from english.phrasal_question_aliases y
       where y.canonical_question_id=r.question_id
     )
), best as (
  select distinct on(user_id,canonical_question_id)
    user_id,canonical_question_id,route,fast_track_status,origins,baseline_wrong,
    entered_fast_track_at,next_fast_track_check,fast_track_mastered_at,
    pending_failure_decision,kept_failure_count,last_failure_at,targeted_at,
    targeted_recovered_at,starred_resolved_at,last_route_reason,metadata,updated_at
  from candidates
  order by user_id,canonical_question_id,
           case route when 'targeted' then 3 when 'fast_track' then 2 else 1 end desc,
           updated_at desc
)
insert into english.learning_route_state(
  user_id,question_id,route,fast_track_status,origins,baseline_wrong,
  entered_fast_track_at,next_fast_track_check,fast_track_mastered_at,
  pending_failure_decision,kept_failure_count,last_failure_at,targeted_at,
  targeted_recovered_at,starred_resolved_at,last_route_reason,metadata,updated_at
)
select user_id,canonical_question_id,route,fast_track_status,origins,baseline_wrong,
       entered_fast_track_at,next_fast_track_check,fast_track_mastered_at,
       pending_failure_decision,kept_failure_count,last_failure_at,targeted_at,
       targeted_recovered_at,starred_resolved_at,last_route_reason,
       coalesce(metadata,'{}'::jsonb)||jsonb_build_object('phrasalIdentityReconciled',true),updated_at
from best
on conflict(user_id,question_id) do update set
  route=excluded.route,
  fast_track_status=excluded.fast_track_status,
  origins=excluded.origins,
  baseline_wrong=greatest(english.learning_route_state.baseline_wrong,excluded.baseline_wrong),
  entered_fast_track_at=coalesce(english.learning_route_state.entered_fast_track_at,excluded.entered_fast_track_at),
  next_fast_track_check=coalesce(excluded.next_fast_track_check,english.learning_route_state.next_fast_track_check),
  fast_track_mastered_at=coalesce(excluded.fast_track_mastered_at,english.learning_route_state.fast_track_mastered_at),
  pending_failure_decision=english.learning_route_state.pending_failure_decision or excluded.pending_failure_decision,
  kept_failure_count=greatest(english.learning_route_state.kept_failure_count,excluded.kept_failure_count),
  last_failure_at=greatest(english.learning_route_state.last_failure_at,excluded.last_failure_at),
  targeted_at=coalesce(english.learning_route_state.targeted_at,excluded.targeted_at),
  targeted_recovered_at=greatest(english.learning_route_state.targeted_recovered_at,excluded.targeted_recovered_at),
  starred_resolved_at=greatest(english.learning_route_state.starred_resolved_at,excluded.starred_resolved_at),
  last_route_reason=coalesce(excluded.last_route_reason,english.learning_route_state.last_route_reason),
  metadata=english.learning_route_state.metadata||excluded.metadata,
  updated_at=greatest(english.learning_route_state.updated_at,excluded.updated_at);

update english.learner_confidence_signals s
set question_id=x.canonical_question_id
from english.phrasal_question_aliases x
where s.question_id=x.alias_question_id;

update english.learner_context_notes n
set question_id=x.canonical_question_id
from english.phrasal_question_aliases x
where n.question_id=x.alias_question_id;

update english.question_revision_proposals p
set question_id=x.canonical_question_id
from english.phrasal_question_aliases x
where p.question_id=x.alias_question_id
  and not exists(
    select 1 from english.question_revision_proposals z
    where z.user_id=p.user_id
      and z.question_id=x.canonical_question_id
      and z.proposal_version=p.proposal_version
  );

-- Establish canonical question_state rows from the already consolidated attempts.
do $do$
declare r record;
begin
  for r in
    select distinct a.user_id,x.canonical_question_id question_id
    from english.attempts a
    join english.phrasal_question_aliases x on x.canonical_question_id=a.question_id
  loop
    perform english.recompute_question_state(r.user_id,r.question_id);
  end loop;
end
$do$;

-- Preserve manual-only state that is not derivable solely from attempts.
with agg as (
  select q.user_id,x.canonical_question_id,
         bool_or(coalesce(q.mastered,false)) mastered,
         max(q.mastered_on) mastered_on,
         max(q.repeat_suppressed_until) repeat_suppressed_until,
         sum(coalesce(q.recall_check_count,0))::int recall_check_count,
         bool_or(coalesce(q.last_marked,false)) last_marked
  from english.question_state q
  join english.phrasal_question_aliases x on x.alias_question_id=q.question_id
  group by q.user_id,x.canonical_question_id
)
update english.question_state c
set mastered=c.mastered or a.mastered,
    mastered_on=greatest(c.mastered_on,a.mastered_on),
    repeat_suppressed_until=greatest(c.repeat_suppressed_until,a.repeat_suppressed_until),
    recall_check_count=coalesce(c.recall_check_count,0)+a.recall_check_count,
    last_marked=c.last_marked or a.last_marked,
    updated_at=now()
from agg a
where c.user_id=a.user_id
  and c.question_id=a.canonical_question_id;

-- Final recompute gives one authoritative state row for the permanent question identity.
do $do$
declare r record;
begin
  for r in
    select distinct a.user_id,x.canonical_question_id question_id
    from english.attempts a
    join english.phrasal_question_aliases x on x.canonical_question_id=a.question_id
  loop
    perform english.recompute_question_state(r.user_id,r.question_id);
  end loop;
end
$do$;

delete from english.question_state q
using english.phrasal_question_aliases x
where q.question_id=x.alias_question_id;

delete from english.difficult_state d
using english.phrasal_question_aliases x
where d.question_id=x.alias_question_id;

delete from english.learning_route_state r
using english.phrasal_question_aliases x
where r.question_id=x.alias_question_id;

delete from english.phrasal_question_variants v
using english.phrasal_question_aliases x
where v.question_id=x.alias_question_id;

-- Keep alias rows for FK/history references but remove them from active selection.
update english.questions q
set active=false,
    content_status='Inactive',
    review_notes=concat_ws(' | ',nullif(q.review_notes,''),'Exact Phrasal snapshot alias -> '||x.canonical_question_id),
    updated_at=now()
from english.phrasal_question_aliases x
where q.question_id=x.alias_question_id;

-- Recompute concept evidence from all preserved attempts under their permanent IDs.
do $do$
declare r record;
begin
  for r in
    select distinct a.user_id,m.concept_id
    from english.attempts a
    join english.question_concept_mappings m on m.question_id=a.question_id
    where exists(
      select 1 from english.phrasal_question_aliases x
      where x.canonical_question_id=a.question_id
    )
  loop
    perform english.recompute_concept_evidence(r.user_id,r.concept_id);
  end loop;
end
$do$;
