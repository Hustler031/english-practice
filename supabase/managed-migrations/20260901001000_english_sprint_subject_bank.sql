-- User-selected SSC Sprint question bank.
-- Marking during an active Sprint stores only the selection; canonical promotion happens only after completion.
-- Wrong-answer Targeted routing remains independent from permanent Sprint Bank membership.

create table if not exists english.sprint_bank_items (
  user_id uuid not null references auth.users(id) on delete cascade,
  source_session_id uuid not null references english.sprint_sessions(session_id) on delete cascade,
  source_position integer not null,
  subject text not null check (subject in ('Grammar','Voice','Narration','Vocabulary','Phrasal Verbs','Idioms & OWS','Spelling & Usage')),
  question_id text references english.questions(question_id) on delete set null,
  saved_at timestamptz not null default now(),
  promoted_at timestamptz,
  primary key(user_id,source_session_id,source_position),
  foreign key(source_session_id,source_position) references english.sprint_items(session_id,position) on delete cascade
);

create unique index if not exists english_sprint_bank_question_user_idx
  on english.sprint_bank_items(user_id,question_id) where question_id is not null;
create index if not exists english_sprint_bank_subject_idx
  on english.sprint_bank_items(user_id,subject,saved_at desc);

alter table english.sprint_bank_items enable row level security;
revoke all on english.sprint_bank_items from public,anon,authenticated;
grant all on english.sprint_bank_items to service_role;

create or replace function english.sprint_bank_subject(p_category text,p_question_type text)
returns text language sql immutable as $$
select case
  when lower(coalesce(p_category,'')) like '%voice%' or lower(coalesce(p_question_type,'')) like '%voice%' or lower(coalesce(p_question_type,'')) like '%passive%' then 'Voice'
  when lower(coalesce(p_category,'')) like '%narration%' or lower(coalesce(p_question_type,'')) like '%direct%' or lower(coalesce(p_question_type,'')) like '%indirect%' then 'Narration'
  when lower(coalesce(p_category,'')) like '%phrasal%' then 'Phrasal Verbs'
  when lower(coalesce(p_category,'')) like '%idiom%' or lower(coalesce(p_category,'')) like '%one word%' or lower(coalesce(p_question_type,'')) like '%one word%' then 'Idioms & OWS'
  when lower(coalesce(p_category,'')) like '%spell%' or lower(coalesce(p_category,'')) like '%preposition%' then 'Spelling & Usage'
  when lower(coalesce(p_category,'')) like '%vocab%' or lower(coalesce(p_category,'')) like '%synonym%' or lower(coalesce(p_category,'')) like '%antonym%' then 'Vocabulary'
  else 'Grammar'
end;
$$;

create or replace function english.promote_sprint_bank_item(p_uid uuid,p_session_id uuid,p_position integer)
returns text language plpgsql security definer
set search_path=pg_catalog,public,english,auth as $$
declare i english.sprint_items%rowtype; qid text; oa text; ob text; oc text; od text; subj text;
begin
  if p_uid is null then raise exception 'Authentication required'; end if;
  if not exists(select 1 from english.sprint_sessions s where s.session_id=p_session_id and s.user_id=p_uid and s.status='completed') then
    return null;
  end if;
  if not exists(select 1 from english.sprint_bank_items b where b.user_id=p_uid and b.source_session_id=p_session_id and b.source_position=p_position) then
    return null;
  end if;

  select * into i from english.sprint_items where session_id=p_session_id and position=p_position;
  if not found then raise exception 'Sprint item not found'; end if;
  subj:=english.sprint_bank_subject(i.category,i.question_type);

  -- Reuse a genuinely identical canonical question when it already exists; otherwise preserve this exact generated Sprint item.
  select q.question_id into qid
  from english.questions q
  where q.active
    and regexp_replace(lower(btrim(q.question)),'\s+',' ','g')=regexp_replace(lower(btrim(i.question)),'\s+',' ','g')
  order by q.created_at asc,q.question_id asc
  limit 1;

  if qid is null then
    qid:='SPBANK_'||replace(substr(p_session_id::text,1,8),'-','')||'_'||lpad(p_position::text,2,'0');
    if not exists(select 1 from english.questions q where q.question_id=qid) then
      oa:=english.sprint_option_text(i.options,'A');
      ob:=english.sprint_option_text(i.options,'B');
      oc:=english.sprint_option_text(i.options,'C');
      od:=english.sprint_option_text(i.options,'D');
      if oa='' or ob='' or oc='' or od='' then raise exception 'Sprint option mapping incomplete at %',p_position; end if;
      insert into english.questions(
        question_id,topic,question,option_a,option_b,option_c,option_d,correct,explanation,question_type,
        source_file,concept_id,difficulty,source_id,learning_status,content_status,exam_relevance,active,created_at,updated_at
      ) values(
        qid,i.category,i.question,oa,ob,oc,od,i.correct_key,i.explanation,i.question_type,
        'GPT SSC Sprint Bank',coalesce(nullif(i.metadata->>'conceptKey',''),qid),'Medium',
        'SprintBank:'||p_session_id::text||':'||p_position::text,'New','Active','SSC CGL User-selected Sprint Bank',true,now(),now()
      );
    end if;
  end if;

  update english.sprint_bank_items
    set question_id=qid,subject=subj,promoted_at=coalesce(promoted_at,now())
  where user_id=p_uid and source_session_id=p_session_id and source_position=p_position;
  return qid;
end $$;

revoke all on function english.promote_sprint_bank_item(uuid,uuid,integer) from public,anon,authenticated;
grant execute on function english.promote_sprint_bank_item(uuid,uuid,integer) to service_role;

create or replace function public.english_set_sprint_bank_mark(p_session_id uuid,p_position integer,p_saved boolean default true)
returns jsonb language plpgsql security definer
set search_path=pg_catalog,public,english,auth as $$
declare uid uuid:=auth.uid(); i english.sprint_items%rowtype; st text; subj text; qid text;
begin
  if uid is null then raise exception 'Authentication required'; end if;
  select s.status into st from english.sprint_sessions s where s.session_id=p_session_id and s.user_id=uid;
  if st is null then raise exception 'Sprint not found'; end if;
  select * into i from english.sprint_items where session_id=p_session_id and position=p_position;
  if not found then raise exception 'Sprint item not found'; end if;
  subj:=english.sprint_bank_subject(i.category,i.question_type);

  if not coalesce(p_saved,true) then
    delete from english.sprint_bank_items where user_id=uid and source_session_id=p_session_id and source_position=p_position;
    return jsonb_build_object('ok',true,'saved',false,'subject',subj,'questionId',null);
  end if;

  insert into english.sprint_bank_items(user_id,source_session_id,source_position,subject,saved_at)
  values(uid,p_session_id,p_position,subj,now())
  on conflict(user_id,source_session_id,source_position) do update set subject=excluded.subject,saved_at=excluded.saved_at;

  if st='completed' then qid:=english.promote_sprint_bank_item(uid,p_session_id,p_position); end if;
  return jsonb_build_object('ok',true,'saved',true,'subject',subj,'questionId',qid,'pending',st<>'completed');
end $$;

create or replace function public.english_finalize_sprint_bank_marks(p_session_id uuid)
returns jsonb language plpgsql security definer
set search_path=pg_catalog,public,english,auth as $$
declare uid uuid:=auth.uid(); r record; qid text; n integer:=0;
begin
  if uid is null then raise exception 'Authentication required'; end if;
  if not exists(select 1 from english.sprint_sessions s where s.session_id=p_session_id and s.user_id=uid and s.status='completed') then raise exception 'Completed Sprint not found'; end if;
  for r in select source_position from english.sprint_bank_items where user_id=uid and source_session_id=p_session_id order by source_position loop
    qid:=english.promote_sprint_bank_item(uid,p_session_id,r.source_position);
    if qid is not null then n:=n+1; end if;
  end loop;
  return jsonb_build_object('ok',true,'promoted',n);
end $$;

create or replace function public.english_get_sprint_bank_marks(p_session_id uuid)
returns jsonb language sql stable security definer
set search_path=pg_catalog,public,english,auth as $$
select case
  when auth.uid() is null then jsonb_build_object('ok',false,'error','Authentication required')
  when not exists(select 1 from english.sprint_sessions s where s.session_id=p_session_id and s.user_id=auth.uid()) then jsonb_build_object('ok',false,'error','Sprint not found')
  else jsonb_build_object(
    'ok',true,
    'items',coalesce((select jsonb_agg(jsonb_build_object('position',b.source_position,'subject',b.subject,'questionId',b.question_id,'savedAt',b.saved_at) order by b.source_position) from english.sprint_bank_items b where b.user_id=auth.uid() and b.source_session_id=p_session_id),'[]'::jsonb)
  )
end;
$$;

create or replace function public.english_get_sprint_bank_overview()
returns jsonb language sql stable security definer
set search_path=pg_catalog,public,english,auth as $$
with subjects(subject,ord) as (values
 ('Grammar',1),('Voice',2),('Narration',3),('Vocabulary',4),('Phrasal Verbs',5),('Idioms & OWS',6),('Spelling & Usage',7)
), counts as (
 select b.subject,count(*)::int total
 from english.sprint_bank_items b
 join english.questions q on q.question_id=b.question_id and q.active
 where b.user_id=auth.uid() and b.question_id is not null
 group by b.subject
)
select case when auth.uid() is null then jsonb_build_object('ok',false,'error','Authentication required') else jsonb_build_object(
 'ok',true,
 'total',coalesce((select sum(total) from counts),0),
 'subjects',(select jsonb_agg(jsonb_build_object('subject',s.subject,'count',coalesce(c.total,0)) order by s.ord) from subjects s left join counts c on c.subject=s.subject)
) end;
$$;

create or replace function public.english_get_sprint_bank_subject(p_subject text)
returns jsonb language sql stable security definer
set search_path=pg_catalog,public,english,auth as $$
with valid as (
 select case when p_subject in ('Grammar','Voice','Narration','Vocabulary','Phrasal Verbs','Idioms & OWS','Spelling & Usage') then p_subject else null end subject
), rows as (
 select b.saved_at,b.subject,q.question_id,q.topic,q.question,q.option_a,q.option_b,q.option_c,q.option_d,upper(q.correct) correct_key,q.explanation,q.question_type,
        coalesce(st.status,'New') status,coalesce(st.mastered,false) mastered,coalesce(st.attempts,0) attempts,coalesce(st.correct,0) correct_count,coalesce(st.wrong,0) wrong_count
 from english.sprint_bank_items b
 join valid v on v.subject=b.subject
 join english.questions q on q.question_id=b.question_id and q.active
 left join english.question_state st on st.user_id=b.user_id and st.question_id=b.question_id
 where b.user_id=auth.uid() and b.question_id is not null
 order by b.saved_at desc,q.question_id
)
select case
 when auth.uid() is null then jsonb_build_object('ok',false,'error','Authentication required')
 when (select subject from valid) is null then jsonb_build_object('ok',false,'error','Unknown Sprint Bank subject')
 else jsonb_build_object(
  'ok',true,'subject',(select subject from valid),'count',(select count(*) from rows),
  'items',coalesce((select jsonb_agg(jsonb_build_object(
    'id',question_id,'category',topic,'topic',topic,'question',question,
    'options',jsonb_build_array(jsonb_build_object('key','A','text',option_a),jsonb_build_object('key','B','text',option_b),jsonb_build_object('key','C','text',option_c),jsonb_build_object('key','D','text',option_d)),
    'correctKey',correct_key,'explanation',explanation,'questionType',question_type,
    'status',status,'mastered',mastered,'attempts',attempts,'correct',correct_count,'wrong',wrong_count,'savedAt',saved_at,'selectionReason','Saved from SSC Sprint'
  ) order by saved_at desc,question_id) from rows),'[]'::jsonb)
 )
end;
$$;

revoke execute on function public.english_set_sprint_bank_mark(uuid,integer,boolean) from public,anon;
revoke execute on function public.english_finalize_sprint_bank_marks(uuid) from public,anon;
revoke execute on function public.english_get_sprint_bank_marks(uuid) from public,anon;
revoke execute on function public.english_get_sprint_bank_overview() from public,anon;
revoke execute on function public.english_get_sprint_bank_subject(text) from public,anon;
grant execute on function public.english_set_sprint_bank_mark(uuid,integer,boolean) to authenticated,service_role;
grant execute on function public.english_finalize_sprint_bank_marks(uuid) to authenticated,service_role;
grant execute on function public.english_get_sprint_bank_marks(uuid) to authenticated,service_role;
grant execute on function public.english_get_sprint_bank_overview() to authenticated,service_role;
grant execute on function public.english_get_sprint_bank_subject(text) to authenticated,service_role;
