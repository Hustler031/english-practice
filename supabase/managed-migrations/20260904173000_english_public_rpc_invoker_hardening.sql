-- Remove public-schema SECURITY DEFINER exposure for the two audited RPCs.
-- Public functions remain the stable API surface but run as SECURITY INVOKER;
-- privileged implementation lives in the non-exposed english schema.
-- Internal functions also bind p_user_id to auth.uid() so a caller cannot
-- spoof another learner even if the internal schema is exposed in future.

create or replace function english.get_today_extra_batch_internal(
  p_user_id uuid,
  p_count integer default 20
) returns jsonb
language plpgsql
stable
security definer
set search_path to 'pg_catalog','english','auth'
as $$
declare
  caller uuid:=auth.uid();
  uid uuid:=p_user_id;
  n integer:=greatest(1,least(30,coalesce(p_count,20)));
  d date:=(now() at time zone 'Asia/Kolkata')::date;
  outv jsonb;
begin
  if caller is null or uid is null or uid is distinct from caller then
    raise exception 'Authentication required';
  end if;

  with base as (
    select q.question_id,
      coalesce(s.status,'New') status,coalesce(s.attempts,0) attempts,coalesce(s.wrong,0) wrong,
      coalesce(s.last_marked,false) starred,coalesce(ds.difficult,false) difficult,s.last_attempt,s.next_review,
      (s.next_review is not null and s.next_review <= ((d+1)::timestamp at time zone 'Asia/Kolkata')) due,
      exists(
        select 1 from english.attempts a
        where a.user_id=uid and a.question_id=q.question_id
          and (a.attempted_at at time zone 'Asia/Kolkata')::date=d and not a.correct
      ) today_wrong,
      (coalesce(ds.difficult,false) and (ds.updated_at at time zone 'Asia/Kolkata')::date=d) today_difficult,
      exists(
        select 1 from english.star_events se
        where se.user_id=uid and se.question_id=q.question_id and se.starred_date=d and se.action='STAR'
          and not exists(
            select 1 from english.star_events later
            where later.user_id=se.user_id and later.question_id=se.question_id
              and later.event_at>se.event_at and later.action='UNSTAR'
          )
      ) today_starred
    from english.questions q
    left join english.question_state s on s.user_id=uid and s.question_id=q.question_id
    left join english.difficult_state ds on ds.user_id=uid and ds.question_id=q.question_id
    where q.active and english.question_visible_to_user(uid,q.question_id) and not coalesce(s.mastered,false)
  ), eligible as (
    select *,case
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
      else 0 end priority
    from base
    where today_wrong or today_difficult or today_starred
       or status in ('Persistent Weak','Weak','Fragile') or due or difficult
  ), ranked as (
    select *,row_number() over(order by
      priority desc,wrong desc,coalesce(next_review,'infinity'::timestamptz),
      coalesce(last_attempt,'epoch'::timestamptz),question_id
    )::int ord
    from eligible
  ), chosen as (
    select * from ranked order by ord limit n
  )
  select coalesce(jsonb_agg(
    english.question_payload(uid,c.question_id)||jsonb_build_object(
      'selectionReason',case
        when c.today_wrong then 'Today''s wrong answer'
        when c.today_difficult then 'Marked Difficult today'
        when c.today_starred then 'Marked for revision today'
        when c.status='Persistent Weak' then 'Persistent Weak'
        when c.status='Weak' then 'Weak'
        when c.status='Fragile' then 'Fragile'
        when c.due then 'Due spaced revision'
        when c.difficult then 'Difficult'
        else 'Smart extra practice' end,
      'extraPractice',true
    ) order by c.ord
  ),'[]'::jsonb) into outv
  from chosen c;
  return outv;
end $$;

create or replace function public.english_get_today_extra_batch(p_count integer default 20)
returns jsonb
language plpgsql
stable
security invoker
set search_path to 'pg_catalog','public','english','auth'
as $$
declare uid uuid:=auth.uid();
begin
  if uid is null then raise exception 'Authentication required'; end if;
  return english.get_today_extra_batch_internal(uid,p_count);
end $$;

create or replace function english.set_hindu_vocab_internal(
  p_user_id uuid,
  p_hindu_id text,
  p_in_vocab boolean
) returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','public','english','auth'
as $$
declare
  caller uuid:=auth.uid();
  uid uuid:=p_user_id;
  raw text:=regexp_replace(btrim(coalesce(p_hindu_id,'')),'^HINDU_','','i');
  v_sid text;
begin
  if caller is null or uid is null or uid is distinct from caller then
    raise exception 'Authentication required';
  end if;

  if coalesce(p_in_vocab,false) then return public.english_add_hindu_to_vocab(raw); end if;

  select saved_id into v_sid
  from english.hindu_vocab_registry
  where user_id=uid and hindu_id=raw;

  update english.hindu_vocab_registry
  set in_vocab=false,updated_at=now()
  where user_id=uid and hindu_id=raw;

  if nullif(btrim(coalesce(v_sid,'')),'') is not null then
    update english.saved_items
    set active=false,updated_at=now()
    where user_id=uid and saved_id=v_sid and active;
  end if;

  return jsonb_build_object(
    'ok',true,'hinduId',raw,'inVocab',false,'removedOwnedSavedItem',v_sid is not null
  );
end $$;

create or replace function public.english_set_hindu_vocab(p_hindu_id text,p_in_vocab boolean)
returns jsonb
language plpgsql
security invoker
set search_path to 'pg_catalog','public','english','auth'
as $$
declare uid uuid:=auth.uid();
begin
  if uid is null then raise exception 'Authentication required'; end if;
  return english.set_hindu_vocab_internal(uid,p_hindu_id,p_in_vocab);
end $$;

revoke all on function english.get_today_extra_batch_internal(uuid,integer) from public,anon;
revoke all on function english.set_hindu_vocab_internal(uuid,text,boolean) from public,anon;
grant execute on function english.get_today_extra_batch_internal(uuid,integer) to authenticated;
grant execute on function english.set_hindu_vocab_internal(uuid,text,boolean) to authenticated;

revoke execute on function public.english_get_today_extra_batch(integer) from public,anon;
revoke execute on function public.english_set_hindu_vocab(text,boolean) from public,anon;
grant execute on function public.english_get_today_extra_batch(integer) to authenticated;
grant execute on function public.english_set_hindu_vocab(text,boolean) to authenticated;
