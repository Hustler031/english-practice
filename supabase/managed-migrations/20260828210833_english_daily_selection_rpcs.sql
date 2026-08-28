create or replace function english.canonical_category(p_topic text)
returns text language sql immutable
as $$
select case
  when lower(coalesce(p_topic,'')) like '%spelling%' then 'SPELLING'
  when lower(coalesce(p_topic,'')) like '%idiom%' then 'IDIOM'
  when lower(coalesce(p_topic,'')) like '%phrasal%' then 'PHRASAL'
  when lower(coalesce(p_topic,'')) like '%one word%' or lower(coalesce(p_topic,'')) like '%field of study%' or lower(coalesce(p_topic,'')) like '%fields of study%' then 'OWS'
  when lower(coalesce(p_topic,'')) like '%synonym%' or lower(coalesce(p_topic,'')) like '%antonym%' then 'SYN_ANT'
  when lower(coalesce(p_topic,'')) like '%confus%' then 'CONFUSED'
  when lower(coalesce(p_topic,'')) like '%sentence improvement%' then 'SENT_IMP'
  when lower(coalesce(p_topic,'')) like '%fill in%' then 'FILL'
  when lower(coalesce(p_topic,'')) like '%cloze%' then 'CLOZE'
  when lower(coalesce(p_topic,'')) like '%para%' then 'PARA'
  when lower(coalesce(p_topic,'')) like '%reading comprehension%' then 'RC'
  when lower(coalesce(p_topic,'')) like '%error%' then 'ERROR'
  when lower(coalesce(p_topic,'')) like '%grammar%' then 'GRAMMAR'
  when lower(coalesce(p_topic,'')) like '%vocab%' then 'VOC'
  else 'MISC' end;
$$;

create or replace function english.learning_category(p_topic text)
returns text language sql immutable
as $$
select case
  when lower(coalesce(p_topic,'')) like '%fixed preposition%' then 'FIXED_PREPOSITION'
  when lower(coalesce(p_topic,'')) like '%fields of study%' or lower(coalesce(p_topic,'')) like '%field of study%' then 'FIELDS_OF_STUDY'
  else english.canonical_category(p_topic) end;
$$;

create or replace function english.is_genuine_bank_question(q english.questions)
returns boolean language sql immutable
as $$
select q.active
  and q.question_id !~* '^MYWORD_'
  and q.question_id !~* '^HV20[0-9]{6}_'
  and lower(coalesce(q.topic,'')) not like '%the hindu%'
  and lower(coalesce(q.source_id,q.source_file,'')) not like '%my_saved_words%'
  and lower(coalesce(q.source_id,q.source_file,'')) not like '%my saved words%'
  and lower(coalesce(q.source_id,q.source_file,'')) not like '%the hindu daily%'
  and lower(coalesce(q.source_id,q.source_file,'')) not like '%daily news vocabulary%';
$$;

create or replace function english.daily_reason(
  p_user_id uuid,
  p_question_id text,
  p_batch_date date
) returns text
language sql stable security definer
set search_path=pg_catalog,english,auth
as $$
with x as (
  select q,
         coalesce(s.attempts,0) attempts,
         coalesce(s.status,'New') state,
         s.next_review,
         coalesce(s.mastered,false) mastered,
         coalesce(s.last_marked,false) starred,
         coalesce(d.difficult,false) difficult
  from english.questions q
  left join english.question_state s on s.user_id=p_user_id and s.question_id=q.question_id
  left join english.difficult_state d on d.user_id=p_user_id and d.question_id=q.question_id
  where q.question_id=p_question_id
)
select case
  when not (q).active or mastered then ''
  when attempts=0 and english.is_genuine_bank_question(q) then 'Controlled New'
  when next_review is null or next_review > ((p_batch_date::timestamp + interval '1 day - 1 millisecond') at time zone 'Asia/Kolkata') then ''
  when state='Persistent Weak' then 'Persistent Weak'
  when state='Weak' then 'Weak'
  when state='Fragile' then 'Fragile'
  when state='Learning' then 'Learning'
  when starred then 'Marked Review'
  when difficult then 'Difficult Review'
  else 'Due Spaced Revision'
end from x;
$$;

create or replace function english.daily_reason_base_score(p_reason text)
returns integer language sql immutable
as $$ select case p_reason
  when 'Persistent Weak' then 1000 when 'Weak' then 900 when 'Fragile' then 800
  when 'Due Spaced Revision' then 720 when 'Learning' then 660
  when 'Marked Review' then 640 when 'Difficult Review' then 630
  when 'Controlled New' then 520 when 'Mixed Revision' then 300 else 0 end; $$;

create or replace function english.daily_quota(p_reason text,p_target integer)
returns integer language sql immutable
as $$ select greatest(1,floor(p_target * case p_reason
  when 'Persistent Weak' then .22 when 'Weak' then .18 when 'Fragile' then .15
  when 'Due Spaced Revision' then .15 when 'Learning' then .08
  when 'Marked Review' then .05 when 'Difficult Review' then .05
  when 'Controlled New' then .10 when 'Mixed Revision' then .02 else 0 end)::int); $$;

create or replace function english.daily_cap(p_reason text,p_target integer)
returns integer language sql immutable
as $$ select greatest(1,ceil(p_target * case p_reason
  when 'Persistent Weak' then .30 when 'Weak' then .25 when 'Fragile' then .20
  when 'Due Spaced Revision' then .25 when 'Learning' then .15
  when 'Marked Review' then .10 when 'Difficult Review' then .10
  when 'Controlled New' then .15 when 'Mixed Revision' then .05 else 1 end)::int); $$;

create or replace function english.current_daily_items(p_user_id uuid)
returns table(
  sequence integer, priority integer, reason text, quiz_date date, status text,
  question_id text, topic text, word text, question text,
  option_a text, option_b text, option_c text, option_d text, correct_key text,
  explanation text, subtopic text, question_type text, source_file text, source_page text,
  concept_id text, difficulty text, tip text, usage_note text, example_sentence text,
  memory_aid text, related_words text, source_url text, starred boolean, difficult boolean
)
language sql stable security definer
set search_path=pg_catalog,english,auth
as $$
select d.sequence,d.priority,d.reason,d.quiz_date,d.status,
       q.question_id,q.topic,q.word,q.question,q.option_a,q.option_b,q.option_c,q.option_d,upper(q.correct),
       q.explanation,q.subtopic,q.question_type,q.source_file,q.source_page,q.concept_id,q.difficulty,
       q.tip,q.usage_note,q.example_sentence,q.memory_aid,q.related_words,q.source_url,
       coalesce(s.last_marked,false),coalesce(ds.difficult,false)
from english.daily_current d
join english.questions q on q.question_id=d.question_id
left join english.question_state s on s.user_id=p_user_id and s.question_id=q.question_id
left join english.difficult_state ds on ds.user_id=p_user_id and ds.question_id=q.question_id
where d.user_id=p_user_id
  and q.active
  and not coalesce(s.mastered,false)
  and (lower(coalesce(d.status,''))='completed' or english.daily_reason(p_user_id,q.question_id,d.quiz_date)<>'')
order by d.sequence;
$$;

create or replace function english.archive_daily(p_user_id uuid,p_batch_date date)
returns integer
language plpgsql security definer
set search_path=pg_catalog,english,auth
as $$
declare v_rows integer;
begin
  insert into english.daily_history(user_id,quiz_date,day_no,question_id,priority,reason,status,topic,concept_id,archived_at)
  select d.user_id,d.quiz_date,null,d.question_id,d.priority,d.reason,d.status,d.topic,d.concept_id,now()
  from english.daily_current d
  where d.user_id=p_user_id and d.quiz_date=p_batch_date
    and not exists(
      select 1 from english.daily_history h
      where h.user_id=d.user_id and h.quiz_date=d.quiz_date and h.question_id=d.question_id
    );
  get diagnostics v_rows=row_count;
  delete from english.daily_current where user_id=p_user_id and quiz_date=p_batch_date;
  return v_rows;
end;
$$;

create or replace function english.create_daily(p_user_id uuid,p_batch_date date,p_target integer)
returns integer
language plpgsql security definer
set search_path=pg_catalog,english,auth
as $$
declare
  v_target integer:=greatest(1,least(120,coalesce(p_target,120)));
  v_reason text; v_take integer; v_count integer:=0; v_seq integer:=0;
begin
  create temporary table if not exists pg_temp.ep_daily_candidates(
    question_id text primary key, reason text, score numeric, priority integer
  ) on commit drop;
  truncate pg_temp.ep_daily_candidates;

  insert into pg_temp.ep_daily_candidates(question_id,reason,score,priority)
  select q.question_id,r.reason,
         english.daily_reason_base_score(r.reason)
         + least(120,greatest(0,coalesce(floor(extract(epoch from (((p_batch_date::timestamp + interval '1 day - 1 millisecond') at time zone 'Asia/Kolkata')-s.next_review))/86400),0))) * 12
         + case when coalesce(s.last_marked,false) then 12 else 0 end
         + case when coalesce(ds.difficult,false) then 10 else 0 end
         + random()*20,
         english.daily_reason_base_score(r.reason)
  from english.questions q
  left join english.question_state s on s.user_id=p_user_id and s.question_id=q.question_id
  left join english.difficult_state ds on ds.user_id=p_user_id and ds.question_id=q.question_id
  cross join lateral (select english.daily_reason(p_user_id,q.question_id,p_batch_date) reason) r
  where q.active and not coalesce(s.mastered,false) and r.reason<>''
    and not (
      p_batch_date=((now() at time zone 'Asia/Kolkata')::date)
      and exists(select 1 from english.attempts a where a.user_id=p_user_id and a.question_id=q.question_id and lower(coalesce(a.module,''))='daily' and (a.attempted_at at time zone 'Asia/Kolkata')::date=p_batch_date)
    );

  -- Fill reason quotas in the same reason order as the Apps Script selector.
  foreach v_reason in array array['Controlled New','Persistent Weak','Weak','Fragile','Due Spaced Revision','Learning','Marked Review','Difficult Review','Mixed Revision'] loop
    exit when v_count>=v_target;
    v_take:=least(english.daily_quota(v_reason,v_target),v_target-v_count);
    for v_seq in
      select 0
    loop exit; end loop;
    for v_reason, v_take in
      select v_reason,v_take
    loop exit; end loop;
    with pick as (
      select c.question_id,c.reason,c.score,c.priority
      from pg_temp.ep_daily_candidates c
      where c.reason=v_reason
        and not exists(select 1 from english.daily_current d where d.user_id=p_user_id and d.question_id=c.question_id)
      order by c.score desc limit v_take
    )
    insert into english.daily_current(user_id,question_id,sequence,priority,reason,quiz_date,status,topic,concept_id)
    select p_user_id,p.question_id,
           v_count+row_number() over(order by p.score desc)::int,
           round(p.score)::int,p.reason,p_batch_date,'New',q.topic,q.concept_id
    from pick p join english.questions q on q.question_id=p.question_id
    order by p.score desc;
    get diagnostics v_take=row_count;
    v_count:=v_count+v_take;
  end loop;

  -- Fill remaining capacity by score while honoring per-reason hard caps.
  if v_count<v_target then
    with existing as (
      select reason,count(*) n from english.daily_current where user_id=p_user_id and quiz_date=p_batch_date group by reason
    ), ranked as (
      select c.*,row_number() over(partition by c.reason order by c.score desc) rn
      from pg_temp.ep_daily_candidates c
      where not exists(select 1 from english.daily_current d where d.user_id=p_user_id and d.question_id=c.question_id)
    ), eligible as (
      select r.*
      from ranked r left join existing e on e.reason=r.reason
      where r.rn <= greatest(0,english.daily_cap(r.reason,v_target)-coalesce(e.n,0))
      order by r.score desc limit (v_target-v_count)
    )
    insert into english.daily_current(user_id,question_id,sequence,priority,reason,quiz_date,status,topic,concept_id)
    select p_user_id,e.question_id,v_count+row_number() over(order by e.score desc)::int,
           round(e.score)::int,e.reason,p_batch_date,'New',q.topic,q.concept_id
    from eligible e join english.questions q on q.question_id=e.question_id
    order by e.score desc;
    get diagnostics v_take=row_count;
    v_count:=v_count+v_take;
  end if;
  return v_count;
end;
$$;

create or replace function english.ensure_daily(p_user_id uuid,p_target integer default 120)
returns jsonb
language plpgsql security definer
set search_path=pg_catalog,english,auth
as $$
declare
  v_today date:=(now() at time zone 'Asia/Kolkata')::date;
  v_batch date; v_pending integer; v_created integer:=0; v_archived integer:=0; v_next date;
begin
  select min(quiz_date) into v_batch from english.daily_current where user_id=p_user_id;
  if v_batch is null then
    v_batch:=v_today;
    v_created:=english.create_daily(p_user_id,v_batch,p_target);
  else
    -- Pending means only pending rows that remain actionable under the batch-date due clock.
    select count(*) into v_pending
    from english.daily_current d
    where d.user_id=p_user_id and d.quiz_date=v_batch
      and lower(coalesce(d.status,''))<>'completed'
      and english.daily_reason(p_user_id,d.question_id,v_batch)<>'';

    if v_batch<v_today and v_pending=0 then
      v_archived:=english.archive_daily(p_user_id,v_batch);
      v_next:=v_batch+1;
      v_batch:=v_next;
      v_created:=english.create_daily(p_user_id,v_batch,p_target);
    end if;
    -- If batch_date is today, intentionally do not refill suppressed/stale rows.
  end if;

  return jsonb_build_object(
    'ok',true,'batch_date',v_batch,'today',v_today,
    'pending_previous_day',(v_batch<v_today),
    'created',v_created,'archived',v_archived,'target_is_maximum',true,
    'total',(select count(*) from english.current_daily_items(p_user_id)),
    'completed',(select count(*) from english.current_daily_items(p_user_id) where lower(coalesce(status,''))='completed'),
    'remaining',(select count(*) from english.current_daily_items(p_user_id) where lower(coalesce(status,''))<>'completed')
  );
end;
$$;

create or replace function public.english_start_daily(p_target integer default 120)
returns jsonb language plpgsql security definer
set search_path=pg_catalog,public,english,auth
as $$
declare uid uuid:=auth.uid(); info jsonb;
begin
  if uid is null then raise exception 'Authentication required'; end if;
  info:=english.ensure_daily(uid,p_target);
  return info || jsonb_build_object('items',coalesce((select jsonb_agg(to_jsonb(x) order by x.sequence) from english.current_daily_items(uid) x where lower(coalesce(x.status,''))<>'completed'),'[]'::jsonb));
end;
$$;

create or replace function public.english_resume_daily()
returns jsonb language plpgsql security definer
set search_path=pg_catalog,public,english,auth
as $$
declare uid uuid:=auth.uid(); info jsonb;
begin
  if uid is null then raise exception 'Authentication required'; end if;
  info:=english.ensure_daily(uid,120);
  return info || jsonb_build_object('items',coalesce((select jsonb_agg(to_jsonb(x) order by x.sequence) from english.current_daily_items(uid) x where lower(coalesce(x.status,''))<>'completed'),'[]'::jsonb));
end;
$$;

revoke all on function public.english_start_daily(integer) from public;
revoke all on function public.english_resume_daily() from public;
grant execute on function public.english_start_daily(integer) to authenticated;
grant execute on function public.english_resume_daily() to authenticated;
