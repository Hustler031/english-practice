create or replace function public.english_get_home_snapshot()
returns jsonb
language sql stable security definer
set search_path=pg_catalog,public,english,auth
as $$
select case when auth.uid() is null then jsonb_build_object('ok',false,'error','Authentication required') else jsonb_build_object(
  'ok',true,
  'studyDay',greatest(1, ((now() at time zone 'Asia/Kolkata')::date - date '2026-08-14') + 1),
  'summary',public.english_dashboard_summary(),
  'intelligence',public.english_get_central_intelligence(),
  'phrasal',public.english_get_phrasal_hub(),
  'bank',public.english_get_bank_coverage_hub(),
  'saved',public.english_get_saved_revision_hub(),
  'starred',public.english_get_starred_hub(null,null),
  'hindu',public.english_get_hindu_today()
) end;
$$;
revoke execute on function public.english_get_home_snapshot() from public,anon;
grant execute on function public.english_get_home_snapshot() to authenticated,service_role;

create or replace function public.english_get_hindu_quiz()
returns jsonb
language plpgsql stable security definer
set search_path=pg_catalog,public,english,auth
as $$
declare
  uid uuid:=auth.uid();
  v_today date:=(now() at time zone 'Asia/Kolkata')::date;
  out jsonb;
begin
  if uid is null then raise exception 'Authentication required'; end if;
  select coalesce(jsonb_agg(
    english.question_payload(uid,cx.question_id) || jsonb_build_object(
      'id','HINDU_'||h.hindu_id,
      'hinduId',h.hindu_id,
      'centralQuestionId',cx.question_id,
      'category','HINDU_VOCAB',
      'topic','The Hindu Vocabulary',
      'word',h.word,
      'hinduMeaning',coalesce(h.meaning,''),
      'article',coalesce(h.article_title,''),
      'sourceUrl',coalesce(nullif(h.source_url,''),(english.question_payload(uid,cx.question_id)->>'sourceUrl'),''),
      'sourceName',coalesce(h.source_name,'The Hindu'),
      'family',coalesce(h.word_family,''),
      'marked',coalesce(r.marked,false),
      'inVocab',coalesce(r.in_vocab,false)
    ) order by h.hindu_id
  ),'[]'::jsonb) into out
  from english.hindu_words h
  left join english.hindu_vocab_registry r on r.user_id=uid and r.hindu_id=h.hindu_id
  left join lateral (select english.resolve_hindu_question_id(uid,h.hindu_id) question_id) cx on true
  where h.active
    and h.word_date=v_today
    and nullif(btrim(coalesce(h.word,'')),'') is not null
    and cx.question_id is not null;
  return out;
end;
$$;
revoke execute on function public.english_get_hindu_quiz() from public,anon;
grant execute on function public.english_get_hindu_quiz() to authenticated,service_role;

create or replace function public.english_submit_hindu_answer(
  p_hindu_id text,
  p_selected_key text,
  p_time_seconds numeric default 0,
  p_attempt_id text default null
)
returns jsonb
language plpgsql security definer
set search_path=pg_catalog,public,english,auth
as $$
declare
  uid uuid:=auth.uid();
  raw text:=regexp_replace(btrim(coalesce(p_hindu_id,'')),'^HINDU_','','i');
  v_qid text;
  q english.questions%rowtype;
  v_key text:=upper(btrim(coalesce(p_selected_key,'')));
  v_correct_key text;
  v_correct boolean;
  v_id text;
  v_rows integer;
  v_state jsonb;
begin
  if uid is null then raise exception 'Authentication required'; end if;
  if v_key not in ('A','B','C','D') then raise exception 'Invalid answer'; end if;
  v_qid:=english.resolve_hindu_question_id(uid,raw);
  if v_qid is null then return jsonb_build_object('ok',false,'reason','not-linked','hindu_id',raw); end if;
  select * into q from english.questions where question_id=v_qid and active;
  if not found then return jsonb_build_object('ok',false,'reason','not-linked','hindu_id',raw); end if;
  v_correct_key:=upper(btrim(coalesce(q.correct,'')));
  if v_correct_key not in ('A','B','C','D') then raise exception 'Canonical Hindu question has invalid correct key'; end if;
  v_correct:=(v_key=v_correct_key);
  v_id:=coalesce(nullif(btrim(p_attempt_id),''),v_qid||'-HINDU-'||floor(extract(epoch from clock_timestamp())*1000)::bigint||'-'||substr(replace(gen_random_uuid()::text,'-',''),1,6));
  insert into english.attempts(attempt_id,user_id,question_id,attempted_at,selected_answer,correct,time_seconds,marked_revision,topic,concept_id,module,submission_key,created_at)
  values(v_id,uid,v_qid,now(),v_key,v_correct,least(180,greatest(0,coalesce(p_time_seconds,0))),false,q.topic,q.concept_id,'hindu',v_id,now())
  on conflict do nothing;
  get diagnostics v_rows=row_count;
  select english.recompute_question_state(uid,v_qid) into v_state;
  return jsonb_build_object(
    'ok',true,'durable',true,'deduped',(v_rows=0),'correct',v_correct,
    'correctKey',v_correct_key,'correct_key',v_correct_key,
    'questionId',v_qid,'attemptId',v_id,'state',v_state
  );
end;
$$;
revoke execute on function public.english_submit_hindu_answer(text,text,numeric,text) from public,anon;
grant execute on function public.english_submit_hindu_answer(text,text,numeric,text) to authenticated,service_role;

create index if not exists english_attempts_question_id_idx on english.attempts(question_id);
create index if not exists english_daily_current_question_id_idx on english.daily_current(question_id);
create index if not exists english_daily_history_question_id_idx on english.daily_history(question_id);
create index if not exists english_difficult_state_question_id_idx on english.difficult_state(question_id);
create index if not exists english_hindu_vocab_registry_question_id_idx on english.hindu_vocab_registry(question_id);
create index if not exists english_mastery_events_question_id_idx on english.mastery_events(question_id);
create index if not exists english_practice_set_items_question_id_idx on english.practice_set_items(question_id);
create index if not exists english_question_state_question_id_idx on english.question_state(question_id);
create index if not exists english_recall_checks_existing_question_id_idx on english.recall_checks(existing_question_id);
create index if not exists english_saved_item_types_saved_id_idx on english.saved_item_types(saved_id);
create index if not exists english_star_events_question_id_idx on english.star_events(question_id);
