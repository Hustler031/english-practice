-- Final pre-production English V2 behaviour batch.
-- Intentionally staged in supabase/migrations; apply only during the single release cutover.

alter table english.hindu_vocab_registry add column if not exists saved_id text;

create or replace function public.english_add_hindu_to_vocab(p_hindu_id text)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','public','english','auth'
as $function$
declare
  uid uuid:=auth.uid();
  raw text:=regexp_replace(btrim(coalesce(p_hindu_id,'')),'^HINDU_','','i');
  h english.hindu_words%rowtype;
  v_qid text;
  v_saved jsonb;
  v_sid text;
  v_duplicate boolean:=false;
  v_enrich jsonb;
  v_promote jsonb;
begin
  if uid is null then raise exception 'Authentication required'; end if;
  select * into h from english.hindu_words where hindu_id=raw and active;
  if not found then raise exception 'Hindu word not found'; end if;
  v_qid:=english.resolve_hindu_question_id(uid,raw);

  insert into english.hindu_vocab_registry(user_id,hindu_id,question_id,added_date,marked,in_vocab,active,updated_at)
  values(uid,raw,v_qid,(now() at time zone 'Asia/Kolkata')::date,false,true,true,now())
  on conflict(user_id,hindu_id) do update set
    question_id=coalesce(english.hindu_vocab_registry.question_id,excluded.question_id),
    added_date=coalesce(english.hindu_vocab_registry.added_date,excluded.added_date),
    in_vocab=true,active=true,updated_at=now();

  v_saved:=public.english_save_word(h.word,coalesce(nullif(h.usage_note,''),h.example_sentence,''),coalesce(v_qid,''),'The Hindu','The Hindu','AUTO');
  v_sid:=v_saved->>'id';
  v_duplicate:=coalesce((v_saved->>'duplicate')::boolean,false);

  -- Only own a saved row when this Hindu action created it. If english_save_word
  -- reused an existing manual item, leave saved_id null so an Unsave can never
  -- deactivate a pre-existing personal capture.
  update english.hindu_vocab_registry
  set saved_id=case when not v_duplicate then nullif(v_sid,'') else null end,updated_at=now()
  where user_id=uid and hindu_id=raw;

  v_enrich:=public.english_set_saved_enrichment(v_sid,coalesce(h.meaning,''),coalesce(h.part_of_speech,''),coalesce(h.synonyms,''),coalesce(h.antonyms,''),coalesce(h.example_sentence,''),concat_ws(E'\n',nullif(h.meaning,''),nullif(h.usage_note,''),nullif(h.tip,'')),'','','','','','','The Hindu','Ready');
  begin v_promote:=public.english_promote_saved_item(v_sid); exception when others then v_promote:=jsonb_build_object('ok',false,'error',sqlerrm); end;
  return jsonb_build_object('ok',true,'hinduId',raw,'questionId',v_qid,'saved',v_saved,'enrichment',v_enrich,'promoted',v_promote);
end;
$function$;

create or replace function public.english_set_hindu_vocab(p_hindu_id text,p_in_vocab boolean)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','public','english','auth'
as $function$
declare
  uid uuid:=auth.uid();
  raw text:=regexp_replace(btrim(coalesce(p_hindu_id,'')),'^HINDU_','','i');
  v_sid text;
begin
  if uid is null then raise exception 'Authentication required'; end if;
  if coalesce(p_in_vocab,false) then return public.english_add_hindu_to_vocab(raw); end if;

  select saved_id into v_sid from english.hindu_vocab_registry where user_id=uid and hindu_id=raw;
  update english.hindu_vocab_registry set in_vocab=false,updated_at=now() where user_id=uid and hindu_id=raw;

  if nullif(btrim(coalesce(v_sid,'')),'') is not null then
    update english.saved_items set active=false,updated_at=now() where user_id=uid and saved_id=v_sid and active;
  end if;

  return jsonb_build_object('ok',true,'hinduId',raw,'inVocab',false,'removedOwnedSavedItem',v_sid is not null);
end;
$function$;

create or replace function public.english_get_today_extra_batch(p_count integer default 20)
returns jsonb
language plpgsql
stable security definer
set search_path to 'pg_catalog','public','english','auth'
as $function$
declare
  uid uuid:=auth.uid();
  n integer:=greatest(1,least(30,coalesce(p_count,20)));
  d date:=(now() at time zone 'Asia/Kolkata')::date;
  out jsonb;
begin
  if uid is null then raise exception 'Authentication required'; end if;

  with base as (
    select q.question_id,
      coalesce(s.status,'New') status,coalesce(s.attempts,0) attempts,coalesce(s.wrong,0) wrong,
      coalesce(s.last_marked,false) starred,coalesce(ds.difficult,false) difficult,s.last_attempt,s.next_review,
      (s.next_review is not null and s.next_review <= ((d+1)::timestamp at time zone 'Asia/Kolkata')) due,
      exists(select 1 from english.attempts a where a.user_id=uid and a.question_id=q.question_id and (a.attempted_at at time zone 'Asia/Kolkata')::date=d and not a.correct) today_wrong,
      (coalesce(ds.difficult,false) and (ds.updated_at at time zone 'Asia/Kolkata')::date=d) today_difficult,
      exists(
        select 1 from english.star_events se
        where se.user_id=uid and se.question_id=q.question_id and se.starred_date=d and se.action='STAR'
          and not exists(select 1 from english.star_events later where later.user_id=se.user_id and later.question_id=se.question_id and later.event_at>se.event_at and later.action='UNSTAR')
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
    where today_wrong or today_difficult or today_starred or status in ('Persistent Weak','Weak','Fragile') or due or difficult
  ), ranked as (
    select *,row_number() over(order by priority desc,wrong desc,coalesce(next_review,'infinity'::timestamptz),coalesce(last_attempt,'epoch'::timestamptz),question_id)::int ord
    from eligible
  ), chosen as (select * from ranked order by ord limit n)
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
  ),'[]'::jsonb) into out from chosen c;
  return out;
end;
$function$;

revoke all on function public.english_set_hindu_vocab(text,boolean) from public;
revoke all on function public.english_get_today_extra_batch(integer) from public;
grant execute on function public.english_set_hindu_vocab(text,boolean) to authenticated;
grant execute on function public.english_get_today_extra_batch(integer) to authenticated;
