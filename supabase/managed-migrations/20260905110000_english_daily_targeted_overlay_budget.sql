-- Stage 2 audit remediation: Targeted is a bounded priority overlay, not an additive quota
-- on top of Targeted-route concepts already selected by their base Daily reason.
-- Natural Weak/Fragile/PW/etc. selections satisfy the Targeted budget first; only the
-- remaining deficit may replace lower-priority untouched Daily rows.

create or replace function english.rebalance_daily_targeted(p_user_id uuid,p_batch_date date,p_target integer)
returns integer
language plpgsql
security definer
set search_path to 'pg_catalog','english','auth'
as $function$
declare
  wanted integer:=greatest(1,least(18,ceil(greatest(1,p_target)*.10)::int));
  existing_n integer;
  replace_n integer;
begin
  -- Count Targeted-route concepts that the deterministic base selector already chose.
  -- Mark at most the requested overlay budget for learner-facing/operational telemetry;
  -- additional naturally-selected Targeted-route rows keep only their base reason.
  with natural_targeted as (
    select d.question_id,d.sequence,
           row_number() over(order by
             case when lower(coalesce(d.status,''))='completed' then 0 else 1 end,
             d.priority desc,d.sequence asc,d.question_id) rn
    from english.daily_current d
    join english.learning_route_state r
      on r.user_id=p_user_id and r.question_id=d.question_id and r.route='targeted'
    where d.user_id=p_user_id and d.quiz_date=p_batch_date
      and (
        lower(coalesce(d.status,''))='completed'
        or english.daily_reason(p_user_id,d.question_id,p_batch_date)<>''
      )
  )
  update english.daily_current d
  set selection_signals=case
        when coalesce(d.selection_signals,'{}'::text[]) @> array['TARGET']::text[]
          then d.selection_signals
        else array_append(coalesce(d.selection_signals,'{}'::text[]),'TARGET')
      end,
      selection_snapshot=coalesce(d.selection_snapshot,'{}'::jsonb)
        || jsonb_build_object('targeted',true,'targetedNaturalSelection',true)
  from natural_targeted n
  where n.rn<=wanted
    and d.user_id=p_user_id and d.question_id=n.question_id and d.sequence=n.sequence;

  select count(*) into existing_n
  from english.daily_current d
  where d.user_id=p_user_id and d.quiz_date=p_batch_date
    and coalesce(d.selection_signals,'{}'::text[]) @> array['TARGET']::text[];

  replace_n:=greatest(0,wanted-existing_n);
  if replace_n=0 then return existing_n; end if;

  with targets as (
    select q.question_id,q.topic,m.concept_id,
           english.daily_reason(p_user_id,q.question_id,p_batch_date) base_reason,
           coalesce(ce.confidence_score,0) confidence,
           english.daily_signal_codes(
             english.daily_reason(p_user_id,q.question_id,p_batch_date),coalesce(s.status,'New'),
             s.next_review is not null and s.next_review<=((p_batch_date::timestamp+interval '1 day - 1 millisecond') at time zone 'Asia/Kolkata'),
             coalesce(s.last_marked,false),coalesce(ds.difficult,false),
             coalesce(s.attempts,0)=0 and english.is_genuine_bank_question(q)
           ) || array['TARGET']::text[] signals,
           row_number() over(
             partition by coalesce(m.concept_id,q.question_id)
             order by case coalesce(r.metadata->>'targeted_kind','need_learning')
               when 'confusion' then 1 when 'need_learning' then 2 when 'transfer_check' then 3 else 4 end,
               coalesce(ce.next_review,'epoch'::timestamptz),r.updated_at desc,q.question_id
           ) concept_pick
    from english.learning_route_state r
    join english.questions q on q.question_id=r.question_id and q.active
    left join english.question_concept_mappings m on m.question_id=q.question_id
    left join english.concept_evidence ce on ce.user_id=p_user_id and ce.concept_id=m.concept_id
    left join english.question_state s on s.user_id=p_user_id and s.question_id=q.question_id
    left join english.difficult_state ds on ds.user_id=p_user_id and ds.question_id=q.question_id
    where r.user_id=p_user_id and r.route='targeted'
      and english.question_visible_to_user(p_user_id,q.question_id)
      and not coalesce(s.mastered,false)
      and english.daily_reason(p_user_id,q.question_id,p_batch_date)<>''
      and not exists(
        select 1 from english.daily_current d
        left join english.question_concept_mappings dm on dm.question_id=d.question_id
        where d.user_id=p_user_id and d.quiz_date=p_batch_date
          and coalesce(dm.concept_id,d.question_id)=coalesce(m.concept_id,q.question_id)
      )
      and not exists(
        select 1 from english.attempts a
        left join english.question_concept_mappings am on am.question_id=a.question_id
        where a.user_id=p_user_id
          and (a.attempted_at at time zone 'Asia/Kolkata')::date=p_batch_date
          and coalesce(am.concept_id,a.question_id)=coalesce(m.concept_id,q.question_id)
      )
  ), pick as (
    select *,row_number() over(order by confidence asc,question_id) rn
    from targets where concept_pick=1
    order by confidence asc,question_id
    limit replace_n
  ), removable as (
    select d.question_id,d.sequence,
           row_number() over(order by
             case d.reason when 'Controlled New' then 1 when 'Learning' then 2
               when 'Marked Review' then 3 when 'Difficult Review' then 4
               when 'Due Spaced Revision' then 5 when 'Fragile' then 6
               when 'Weak' then 7 when 'Persistent Weak' then 8 else 9 end,
             d.priority asc,d.sequence desc) rn
    from english.daily_current d
    where d.user_id=p_user_id and d.quiz_date=p_batch_date
      and not (coalesce(d.selection_signals,'{}'::text[]) @> array['TARGET']::text[])
      and lower(coalesce(d.status,''))<>'completed'
      and not exists(
        select 1 from english.attempts a
        where a.user_id=p_user_id and a.question_id=d.question_id
          and (a.attempted_at at time zone 'Asia/Kolkata')::date=p_batch_date
      )
    order by
      case d.reason when 'Controlled New' then 1 when 'Learning' then 2
        when 'Marked Review' then 3 when 'Difficult Review' then 4
        when 'Due Spaced Revision' then 5 when 'Fragile' then 6
        when 'Weak' then 7 when 'Persistent Weak' then 8 else 9 end,
      d.priority asc,d.sequence desc
    limit replace_n
  ), pairs as (
    select r.question_id old_id,r.sequence,p.* from removable r join pick p using(rn)
  )
  update english.daily_current d
  set question_id=p.question_id,
      priority=greatest(d.priority,950),
      reason=p.base_reason,
      status='New',topic=p.topic,concept_id=p.concept_id,
      selection_signals=p.signals,
      selection_snapshot=jsonb_build_object(
        'selectedAt',now(),'batchDate',p_batch_date,'reason',p.base_reason,
        'conceptId',p.concept_id,'conceptConfidence',p.confidence,
        'targeted',true,'targetedNaturalSelection',false
      )
  from pairs p
  where d.user_id=p_user_id and d.question_id=p.old_id and d.sequence=p.sequence;

  select count(*) into existing_n
  from english.daily_current d
  where d.user_id=p_user_id and d.quiz_date=p_batch_date
    and coalesce(d.selection_signals,'{}'::text[]) @> array['TARGET']::text[];
  return existing_n;
end;
$function$;
