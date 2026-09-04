-- Targeted Focused Practice must rank genuinely due concepts before waiting lanes.
-- Previously english_get_targeted_batch limited to 30 before the due-only gateway filtered,
-- so non-due transfer/retention rows could consume the candidate window and underfill a 15-item set.

create or replace function public.english_get_targeted_batch(p_count integer default 15, p_kind text default null::text, p_confusion_id uuid default null::uuid)
returns jsonb
language plpgsql
stable security definer
set search_path to 'pg_catalog', 'public', 'english', 'auth'
as $function$
declare uid uuid:=auth.uid(); n int:=greatest(1,least(30,coalesce(p_count,15))); k text:=lower(nullif(trim(coalesce(p_kind,'')),'')); session_nonce text:=nullif(current_setting('english.targeted_session_nonce',true),''); outv jsonb;
begin
  if uid is null then raise exception 'Authentication required'; end if;
  with focus as(
    select * from english.learner_confusions where user_id=uid and p_confusion_id is not null and confusion_id=p_confusion_id
  ), routed as(
    select r.question_id,m.concept_id,r.metadata,r.origins,r.last_route_reason,r.updated_at,ce.coverage_state,ce.confidence_score,ce.next_review,
      english.targeted_route_kind(r.metadata,r.origins) kind,coalesce(qm.too_easy,false) question_too_easy,coalesce(qm.observed_difficulty,0.5) question_observed_difficulty
    from english.learning_route_state r join english.questions q on q.question_id=r.question_id and q.active and english.question_visible_to_user(uid,q.question_id)
    left join english.question_concept_mappings m on m.question_id=r.question_id left join english.concept_evidence ce on ce.user_id=uid and ce.concept_id=m.concept_id
    left join english.question_quality_metrics qm on qm.user_id=uid and qm.question_id=r.question_id
    where r.user_id=uid and r.route='targeted'
  ), filtered as(
    select x.* from routed x where (p_confusion_id is null or exists(select 1 from focus f where x.concept_id=f.primary_concept_id or x.concept_id=f.related_concept_id or x.question_id=f.primary_question_id or x.question_id=f.related_question_id)) and (k is null or x.kind=k)
  ), delivery as(
    select f.*,coalesce(alt.question_id,f.question_id) delivery_question_id,row_number() over(partition by coalesce(f.concept_id,f.question_id)
      order by case f.kind when 'confusion' then 1 when 'transfer_check' then 2 when 'retention_check' then 3 else 4 end,f.updated_at desc) concept_pick
    from filtered f left join lateral(
      select q2.question_id from english.questions q2 join english.question_concept_mappings m2 on m2.question_id=q2.question_id
      left join english.question_state s2 on s2.user_id=uid and s2.question_id=q2.question_id
      left join english.question_quality_metrics qm2 on qm2.user_id=uid and qm2.question_id=q2.question_id
      where f.kind in('transfer_check','confusion') and not (f.kind='transfer_check' and ('AI Transfer'=any(coalesce(f.origins,'{}'::text[]))
        or exists(select 1 from english.question_origins qo where qo.question_id=f.question_id and qo.origin_kind='targeted_generated' and qo.owner_user_id=uid)))
        and f.concept_id is not null and m2.concept_id=f.concept_id and q2.question_id<>f.question_id and q2.active
        and english.question_visible_to_user(uid,q2.question_id) and not coalesce(s2.mastered,false)
      order by coalesce(qm2.too_easy,false),coalesce(qm2.observed_difficulty,0.5) desc,coalesce(s2.last_attempt,'epoch'::timestamptz),
        case when session_nonce is null then q2.question_id else md5(session_nonce||'|'||q2.question_id) end limit 1
    ) alt on true
  ), chosen as(
    select * from delivery where concept_pick=1 order by
      case when kind='confusion' or next_review is null or next_review<=now() then 0 else 1 end,
      case when kind='confusion' then 1 when kind='transfer_check' then 2 when kind='retention_check' then 3 when kind='need_learning' then 4 else 5 end,
      case when kind='need_learning' and question_too_easy then 1 else 0 end,question_observed_difficulty desc,
      case when session_nonce is not null then md5(session_nonce||'|'||coalesce(concept_id,question_id)) else '' end,coalesce(next_review,'epoch'::timestamptz),updated_at desc limit n
  )
  select coalesce(jsonb_agg(english.question_payload(uid,c.delivery_question_id)||jsonb_build_object(
    'learningRoute','targeted','targetedKind',c.kind,'targetedReason',c.last_route_reason,'sourceQuestionId',c.question_id,'conceptId',c.concept_id,
    'conceptCoverage',coalesce(c.coverage_state,'unseen'),'conceptConfidence',coalesce(c.confidence_score,0),'conceptNextReview',c.next_review,
    'observedDifficulty',c.question_observed_difficulty,'questionTooEasy',c.question_too_easy
  ) order by case when c.kind='confusion' then 1 when c.kind='transfer_check' then 2 when c.kind='retention_check' and (c.next_review is null or c.next_review<=now()) then 3 when c.kind='need_learning' then 4 else 5 end,
    case when c.kind='need_learning' and c.question_too_easy then 1 else 0 end,c.question_observed_difficulty desc,c.updated_at desc),'[]'::jsonb) into outv from chosen c;
  return outv;
end $function$;
