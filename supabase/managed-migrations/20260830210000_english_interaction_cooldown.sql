-- English V2 interaction-based fresh-session cooldown.
-- A question being generated into a batch is audit evidence only; it must not by itself
-- suppress Central Learning Intelligence eligibility in the next adaptive session.
-- Recent durable attempts (plus client-reported pending attempts) are the cooldown signal.

create or replace function english.rotate_fresh_session_batch(
  p_user_id uuid,
  p_lane text,
  p_rows jsonb,
  p_limit integer,
  p_strict_unseen boolean default false,
  p_client_exclude text[] default '{}'::text[],
  p_record boolean default true
) returns jsonb
language plpgsql volatile security definer
set search_path='pg_catalog','english','auth'
as $$
declare
  v_lane text:=lower(btrim(coalesce(p_lane,'fresh')));
  v_limit integer:=greatest(1,least(1000,coalesce(p_limit,20)));
  v_session uuid:=gen_random_uuid();
  out jsonb;
begin
  if p_user_id is null then raise exception 'Authentication required'; end if;
  if v_lane='' then v_lane:='fresh'; end if;

  with expanded as (
    select e.value j,e.ordinality::int ord,
      coalesce(nullif(e.value->>'id',''),nullif(e.value->>'question_id',''),nullif(e.value->>'questionId','')) qid
    from jsonb_array_elements(coalesce(p_rows,'[]'::jsonb)) with ordinality e(value,ordinality)
  ), dedup as (
    select distinct on (qid) qid,j,ord
    from expanded
    where qid is not null
    order by qid,ord
  ), annotated as (
    select d.qid,d.j,d.ord,
      coalesce(s.attempts,0) attempts,
      s.last_attempt,
      (
        d.qid=any(coalesce(p_client_exclude,'{}'::text[]))
        or coalesce(s.last_attempt >= now()-interval '90 minutes',false)
      ) hard_recent,
      ((d.ord-1)/v_limit)::int priority_band
    from dedup d
    left join english.question_state s on s.user_id=p_user_id and s.question_id=d.qid
  ), eligible as (
    select * from annotated
    where not (
      p_strict_unseen
      and (
        attempts>0
        or qid=any(coalesce(p_client_exclude,'{}'::text[]))
      )
    )
  ), ordered as (
    select *,row_number() over(order by
      hard_recent asc,
      priority_band asc,
      coalesce(last_attempt,'epoch'::timestamptz) asc,
      ord asc,
      qid
    )::int pick_ord
    from eligible
  ), picked as (
    select * from ordered where pick_ord<=v_limit
  ), session_row as (
    insert into english.quiz_sessions(session_id,user_id,lane,requested_count,served_count,strict_unseen)
    select v_session,p_user_id,v_lane,v_limit,count(*)::int,p_strict_unseen
    from picked
    having p_record and count(*)>0
    returning session_id
  ), exposure_rows as (
    insert into english.quiz_session_exposures(user_id,session_id,lane,question_id,strict_unseen)
    select p_user_id,v_session,v_lane,p.qid,p_strict_unseen
    from picked p cross join session_row s
    on conflict (user_id,session_id,question_id) do nothing
    returning exposure_id
  ), marker as (
    select count(*) recorded from exposure_rows
  )
  select coalesce(jsonb_agg(
    p.j || case when p_record then jsonb_build_object('freshSessionId',v_session::text) else '{}'::jsonb end
    order by p.pick_ord
  ),'[]'::jsonb)
  into out
  from picked p cross join marker;

  return coalesce(out,'[]'::jsonb);
end $$;

revoke all on function english.rotate_fresh_session_batch(uuid,text,jsonb,integer,boolean,text[],boolean) from public,anon,authenticated;
grant execute on function english.rotate_fresh_session_batch(uuid,text,jsonb,integer,boolean,text[],boolean) to service_role;
