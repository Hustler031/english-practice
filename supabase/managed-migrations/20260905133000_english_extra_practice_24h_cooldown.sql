-- Practice More / Smart Extra Practice freshness hardening.
-- Goal:
-- 1) avoid the exact same question for 24h when fresh alternatives exist;
-- 2) allow a same-concept repair using a different question/variant first;
-- 3) keep a 90-minute minimum before an exact same-day wrong question can even be a fallback;
-- 4) preserve learning priority and relax freshness only when the eligible pool is genuinely short;
-- 5) make direct RPC callers use the same audited fresh-session gateway as the web client.

create or replace function english.extra_practice_candidates(
  p_user_id uuid,
  p_count integer default 60
) returns jsonb
language plpgsql stable security definer
set search_path='pg_catalog','english','auth'
as $function$
declare
  n integer:=greatest(1,least(100,coalesce(p_count,60)));
  d date:=(now() at time zone 'Asia/Kolkata')::date;
  seed_n integer:=least(100,greatest(40,n*2));
  outv jsonb;
begin
  if p_user_id is null then raise exception 'Authentication required'; end if;

  with base as (
    select
      q.question_id,
      coalesce(m.concept_id,nullif(q.concept_id,''),q.question_id) concept_key,
      m.concept_id,
      coalesce(s.status,'New') status,
      coalesce(s.wrong,0) wrong,
      coalesce(s.last_marked,false) starred,
      coalesce(ds.difficult,false) difficult,
      s.last_attempt,
      s.next_review,
      (s.next_review is not null and s.next_review <= ((d+1)::timestamp at time zone 'Asia/Kolkata')) due,
      exists(
        select 1 from english.attempts a
        where a.user_id=p_user_id
          and a.question_id=q.question_id
          and (a.attempted_at at time zone 'Asia/Kolkata')::date=d
          and not a.correct
      ) today_wrong,
      (coalesce(ds.difficult,false) and (ds.updated_at at time zone 'Asia/Kolkata')::date=d) today_difficult,
      exists(
        select 1 from english.star_events se
        where se.user_id=p_user_id
          and se.question_id=q.question_id
          and se.starred_date=d
          and se.action='STAR'
          and not exists(
            select 1 from english.star_events later
            where later.user_id=se.user_id
              and later.question_id=se.question_id
              and later.event_at>se.event_at
              and later.action='UNSTAR'
          )
      ) today_starred
    from english.questions q
    left join english.question_state s
      on s.user_id=p_user_id and s.question_id=q.question_id
    left join english.difficult_state ds
      on ds.user_id=p_user_id and ds.question_id=q.question_id
    left join english.question_concept_mappings m
      on m.question_id=q.question_id
    where q.active
      and english.question_visible_to_user(p_user_id,q.question_id)
      and not coalesce(s.mastered,false)
  ), eligible as (
    select *,
      case
        when today_wrong and today_difficult then 120
        when today_wrong then 115
        when today_difficult then 110
        when today_starred then 105
        when status='Persistent Weak' and due then 95
        when status='Persistent Weak' then 90
        when status='Weak' and due then 85
        when status='Weak' then 80
        when status='Fragile' and due then 75
        when due then 70
        when status='Fragile' then 65
        when difficult then 60
        else 0
      end priority,
      case
        when today_wrong then 'Today''s wrong answer'
        when today_difficult then 'Marked Difficult today'
        when today_starred then 'Marked for revision today'
        when status='Persistent Weak' then 'Persistent Weak'
        when status='Weak' then 'Weak'
        when status='Fragile' then 'Fragile'
        when due then 'Due spaced revision'
        when difficult then 'Difficult'
        else 'Smart extra practice'
      end selection_reason
    from base
    where today_wrong or today_difficult or today_starred
       or status in ('Persistent Weak','Weak','Fragile') or due or difficult
  ), seeds as (
    select *
    from eligible
    order by
      priority desc,
      wrong desc,
      coalesce(next_review,'infinity'::timestamptz),
      coalesce(last_attempt,'epoch'::timestamptz),
      question_id
    limit seed_n
  ), variant_pool as (
    select
      s.question_id source_question_id,
      s.concept_key,
      s.concept_id,
      s.priority,
      s.selection_reason,
      s.wrong,
      s.next_review,
      s.today_wrong,
      q2.question_id candidate_question_id,
      (q2.question_id=s.question_id) is_primary,
      st2.last_attempt candidate_last_attempt,
      exists(
        select 1
        from english.quiz_session_exposures x
        where x.user_id=p_user_id
          and x.lane='extra'
          and x.question_id=q2.question_id
          and x.served_at>=now()-interval '24 hours'
      ) extra_exposed_24h,
      row_number() over(
        partition by s.question_id
        order by
          (q2.question_id=s.question_id) desc,
          coalesce(st2.last_attempt,'epoch'::timestamptz),
          q2.question_id
      ) variant_ord
    from seeds s
    join english.questions q2 on q2.active
    left join english.question_state st2
      on st2.user_id=p_user_id and st2.question_id=q2.question_id
    left join english.question_concept_mappings m2
      on m2.question_id=q2.question_id
    where english.question_visible_to_user(p_user_id,q2.question_id)
      and not coalesce(st2.mastered,false)
      and (
        q2.question_id=s.question_id
        or (s.concept_id is not null and m2.concept_id=s.concept_id)
      )
  ), variants as (
    select *
    from variant_pool
    where variant_ord<=5
  ), scored as (
    select *,
      case
        -- A same-day wrong item may become an exact-question fallback only after
        -- 90 minutes, and only when it has not already been served in Extra.
        when is_primary
         and today_wrong
         and coalesce(candidate_last_attempt,'epoch'::timestamptz) < now()-interval '90 minutes'
         and not extra_exposed_24h
          then 1
        -- Normal exact-question cooldown is 24h across English attempts, plus
        -- 24h for an Extra exposure even if the learner opened it but did not answer.
        when coalesce(candidate_last_attempt,'epoch'::timestamptz) >= now()-interval '24 hours'
          or extra_exposed_24h
          then 2
        else 0
      end fresh_class
    from variants
  ), one_per_concept as (
    select *,
      row_number() over(
        partition by concept_key
        order by
          fresh_class,
          is_primary desc,
          coalesce(candidate_last_attempt,'epoch'::timestamptz),
          candidate_question_id
      ) concept_ord
    from scored
  ), ranked as (
    select *,
      row_number() over(
        order by
          fresh_class,
          priority desc,
          wrong desc,
          coalesce(next_review,'infinity'::timestamptz),
          coalesce(candidate_last_attempt,'epoch'::timestamptz),
          candidate_question_id
      )::int ord
    from one_per_concept
    where concept_ord=1
  ), chosen as (
    select * from ranked order by ord limit n
  )
  select coalesce(jsonb_agg(
    english.question_payload(p_user_id,c.candidate_question_id)
    ||jsonb_build_object(
      'selectionReason',case
        when not c.is_primary then 'Fresh variant · '||c.selection_reason
        else c.selection_reason
      end,
      'extraPractice',true,
      'extraFreshVariant',not c.is_primary,
      'sourceQuestionId',c.source_question_id,
      'freshnessClass',c.fresh_class
    ) order by c.ord
  ),'[]'::jsonb)
  into outv
  from chosen c;

  return outv;
end
$function$;

revoke all on function english.extra_practice_candidates(uuid,integer) from public,anon,authenticated;
grant execute on function english.extra_practice_candidates(uuid,integer) to service_role;

-- Keep the private helper aligned with the same candidate source.
create or replace function english.get_today_extra_batch_internal(
  p_user_id uuid,
  p_count integer default 20
) returns jsonb
language plpgsql stable security definer
set search_path='pg_catalog','english','auth'
as $function$
declare
  caller uuid:=auth.uid();
  uid uuid:=p_user_id;
  n integer:=greatest(1,least(30,coalesce(p_count,20)));
begin
  if caller is null or uid is null or uid is distinct from caller then
    raise exception 'Authentication required';
  end if;
  return english.extra_practice_candidates(uid,n);
end
$function$;

revoke all on function english.get_today_extra_batch_internal(uuid,integer) from public,anon,authenticated;
grant execute on function english.get_today_extra_batch_internal(uuid,integer) to service_role;

-- Direct callers must use the same fresh-session/exposure ledger as the web client.
create or replace function public.english_get_today_extra_batch(
  p_count integer default 20
) returns jsonb
language plpgsql volatile
set search_path='pg_catalog','public','english','auth'
as $function$
declare
  uid uuid:=auth.uid();
  n integer:=greatest(1,least(30,coalesce(p_count,20)));
begin
  if uid is null then raise exception 'Authentication required'; end if;
  return public.english_start_fresh_session(
    'english_get_today_extra_batch',
    jsonb_build_object('p_count',n),
    '{}'::text[]
  );
end
$function$;

revoke execute on function public.english_get_today_extra_batch(integer) from public,anon;
grant execute on function public.english_get_today_extra_batch(integer) to authenticated,service_role;
