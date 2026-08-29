alter table english.daily_current
  add column if not exists selection_signals text[] not null default '{}'::text[],
  add column if not exists selection_snapshot jsonb not null default '{}'::jsonb;

create or replace function english.daily_reason_code(p_reason text)
returns text language sql immutable as $$
select case p_reason
  when 'Persistent Weak' then 'PW'
  when 'Weak' then 'W'
  when 'Fragile' then 'FR'
  when 'Due Spaced Revision' then 'DUE'
  when 'Marked Review' then 'STAR'
  when 'Difficult Review' then 'DIFF'
  when 'Controlled New' then 'NEW'
  when 'Learning' then 'LEARN'
  else 'MIX' end;
$$;

create or replace function english.daily_signal_codes(
  p_reason text,p_state text,p_due boolean,p_starred boolean,p_difficult boolean,p_new boolean
)
returns text[] language sql immutable as $$
with raw(code,ord) as (
  select * from unnest(array_remove(array[
    english.daily_reason_code(p_reason),
    case p_state when 'Persistent Weak' then 'PW' when 'Weak' then 'W' when 'Fragile' then 'FR' when 'Learning' then 'LEARN' end,
    case when p_due then 'DUE' end,
    case when p_starred then 'STAR' end,
    case when p_difficult then 'DIFF' end,
    case when p_new then 'NEW' end
  ]::text[],null)) with ordinality
), dedup as (
  select code,min(ord) ord from raw where nullif(code,'') is not null group by code
)
select coalesce(array_agg(code order by ord),'{}'::text[]) from dedup;
$$;

create or replace function english.daily_category_penalties(p_user_id uuid)
returns table(
  category text, penalty numeric, seen_count integer, weak_count integer,
  first_attempt_accuracy numeric, retention_accuracy numeric
)
language sql stable security definer
set search_path=pg_catalog,english,auth as $$
with qbank as (
  select q.question_id,english.learning_category(q.topic) category
  from english.questions q
  where english.is_genuine_bank_question(q)
), a0 as (
  select a.question_id,a.correct,a.attempted_at,a.source_row,a.created_at,a.attempt_id,
         (a.attempted_at at time zone 'Asia/Kolkata')::date study_date,
         row_number() over(partition by a.question_id order by a.attempted_at,a.source_row nulls last,a.created_at,a.attempt_id) overall_rn,
         row_number() over(partition by a.question_id,(a.attempted_at at time zone 'Asia/Kolkata')::date order by a.attempted_at,a.source_row nulls last,a.created_at,a.attempt_id) day_rn
  from english.attempts a join qbank q on q.question_id=a.question_id
  where a.user_id=p_user_id
), cp as (
  select x.*,row_number() over(partition by question_id order by study_date,attempted_at,source_row nulls last,created_at,attempt_id) cp_rn
  from a0 x where day_rn=1
), firsts as (
  select question_id,max(case when overall_rn=1 and coalesce(correct,false) then 1 else 0 end)::int first_correct
  from a0 group by question_id
), retention as (
  select question_id,
         count(*) filter(where cp_rn>1)::int ret_n,
         count(*) filter(where cp_rn>1 and coalesce(correct,false))::int ret_c
  from cp group by question_id
), cats as (select distinct category from qbank), seen as (
  select q.category,q.question_id,
         coalesce(s.status,'New') status,f.first_correct,
         coalesce(r.ret_n,0)::int ret_n,coalesce(r.ret_c,0)::int ret_c
  from qbank q join firsts f on f.question_id=q.question_id
  left join retention r on r.question_id=q.question_id
  left join english.question_state s on s.user_id=p_user_id and s.question_id=q.question_id
), agg as (
  select c.category,count(s.question_id)::int seen_count,
         count(*) filter(where s.status in ('Persistent Weak','Weak'))::int weak_count,
         coalesce(avg(s.first_correct::numeric),0) first_acc,
         coalesce(sum(s.ret_n),0)::int ret_n,coalesce(sum(s.ret_c),0)::int ret_c
  from cats c left join seen s on s.category=c.category group by c.category
)
select category,
       case when seen_count=0 then .5::numeric else
         greatest(0::numeric,least(1::numeric,
           (weak_count::numeric/seen_count)*.5
           +(1-first_acc)*.25
           +(1-(case when ret_n>0 then ret_c::numeric/ret_n else .5::numeric end))*.25
         )) end penalty,
       seen_count,weak_count,
       case when seen_count>0 then round(first_acc,4) else null end,
       case when ret_n>0 then round(ret_c::numeric/ret_n,4) else null end
from agg;
$$;

create or replace function english.create_daily(p_user_id uuid,p_batch_date date,p_target integer)
returns integer language plpgsql security definer
set search_path=pg_catalog,english,auth as $$
declare
  v_target integer:=greatest(1,least(120,coalesce(p_target,120)));
  v_reason text; v_take integer; v_inserted integer; v_count integer:=0;
begin
  create temporary table if not exists pg_temp.ep_daily_candidates(
    question_id text primary key, reason text, score numeric, priority integer,
    signals text[], snapshot jsonb
  ) on commit drop;
  truncate pg_temp.ep_daily_candidates;

  insert into pg_temp.ep_daily_candidates(question_id,reason,score,priority,signals,snapshot)
  select q.question_id,r.reason,
         english.daily_reason_base_score(r.reason)
         + coalesce(cp.penalty,0)*70
         + least(120,greatest(0,coalesce(floor(extract(epoch from (((p_batch_date::timestamp + interval '1 day - 1 millisecond') at time zone 'Asia/Kolkata')-s.next_review))/86400),0))) * 12
         + case when coalesce(s.last_marked,false) then 12 else 0 end
         + case when coalesce(ds.difficult,false) then 10 else 0 end
         + random()*20,
         english.daily_reason_base_score(r.reason),
         english.daily_signal_codes(
           r.reason,coalesce(s.status,'New'),
           s.next_review is not null and s.next_review <= ((p_batch_date::timestamp + interval '1 day - 1 millisecond') at time zone 'Asia/Kolkata'),
           coalesce(s.last_marked,false),coalesce(ds.difficult,false),
           coalesce(s.attempts,0)=0 and english.is_genuine_bank_question(q)
         ),
         jsonb_build_object(
           'selectedAt',now(),'batchDate',p_batch_date,
           'state',coalesce(s.status,'New'),'attempts',coalesce(s.attempts,0),
           'correct',coalesce(s.correct,0),'wrong',coalesce(s.wrong,0),
           'accuracy',coalesce(s.accuracy,0),'nextReview',s.next_review,
           'starred',coalesce(s.last_marked,false),'difficult',coalesce(ds.difficult,false),
           'category',english.learning_category(q.topic),
           'categoryPenalty',coalesce(cp.penalty,0),
           'daysOverdue',greatest(0,coalesce(floor(extract(epoch from (((p_batch_date::timestamp + interval '1 day - 1 millisecond') at time zone 'Asia/Kolkata')-s.next_review))/86400),0))
         )
  from english.questions q
  left join english.question_state s on s.user_id=p_user_id and s.question_id=q.question_id
  left join english.difficult_state ds on ds.user_id=p_user_id and ds.question_id=q.question_id
  left join english.daily_category_penalties(p_user_id) cp on cp.category=english.learning_category(q.topic)
  cross join lateral (select english.daily_reason(p_user_id,q.question_id,p_batch_date) reason) r
  where q.active and not coalesce(s.mastered,false) and r.reason<>''
    and not (
      p_batch_date=((now() at time zone 'Asia/Kolkata')::date)
      and exists(select 1 from english.attempts a where a.user_id=p_user_id and a.question_id=q.question_id and lower(coalesce(a.module,''))='daily' and (a.attempted_at at time zone 'Asia/Kolkata')::date=p_batch_date)
    );

  foreach v_reason in array array['Controlled New','Persistent Weak','Weak','Fragile','Due Spaced Revision','Learning','Marked Review','Difficult Review','Mixed Revision'] loop
    exit when v_count>=v_target;
    v_take:=least(english.daily_quota(v_reason,v_target),v_target-v_count);
    with pick as (
      select c.question_id,c.reason,c.score,c.priority,c.signals,c.snapshot
      from pg_temp.ep_daily_candidates c
      where c.reason=v_reason
        and not exists(select 1 from english.daily_current d where d.user_id=p_user_id and d.question_id=c.question_id)
      order by c.score desc limit v_take
    )
    insert into english.daily_current(user_id,question_id,sequence,priority,reason,quiz_date,status,topic,concept_id,selection_signals,selection_snapshot)
    select p_user_id,p.question_id,
           v_count+row_number() over(order by p.score desc)::int,
           round(p.score)::int,p.reason,p_batch_date,'New',q.topic,q.concept_id,p.signals,p.snapshot
    from pick p join english.questions q on q.question_id=p.question_id
    order by p.score desc;
    get diagnostics v_inserted=row_count;
    v_count:=v_count+v_inserted;
  end loop;

  if v_count<v_target then
    with existing as (
      select reason,count(*) n from english.daily_current where user_id=p_user_id and quiz_date=p_batch_date group by reason
    ), ranked as (
      select c.*,row_number() over(partition by c.reason order by c.score desc) rn
      from pg_temp.ep_daily_candidates c
      where not exists(select 1 from english.daily_current d where d.user_id=p_user_id and d.question_id=c.question_id)
    ), eligible as (
      select r.* from ranked r left join existing e on e.reason=r.reason
      where r.rn <= greatest(0,english.daily_cap(r.reason,v_target)-coalesce(e.n,0))
      order by r.score desc limit (v_target-v_count)
    )
    insert into english.daily_current(user_id,question_id,sequence,priority,reason,quiz_date,status,topic,concept_id,selection_signals,selection_snapshot)
    select p_user_id,e.question_id,v_count+row_number() over(order by e.score desc)::int,
           round(e.score)::int,e.reason,p_batch_date,'New',q.topic,q.concept_id,e.signals,e.snapshot
    from eligible e join english.questions q on q.question_id=e.question_id
    order by e.score desc;
    get diagnostics v_inserted=row_count;
    v_count:=v_count+v_inserted;
  end if;
  return v_count;
end;
$$;

with meta as (
  select d.user_id,d.question_id,d.quiz_date,d.reason,
         q.topic,english.is_genuine_bank_question(q) as genuine,
         s.status as state_status,s.attempts as state_attempts,s.correct as state_correct,s.wrong as state_wrong,
         s.accuracy as state_accuracy,s.next_review as state_next_review,s.last_marked as state_starred,
         ds.difficult as state_difficult
  from english.daily_current d
  join english.questions q on q.question_id=d.question_id
  left join english.question_state s on s.user_id=d.user_id and s.question_id=d.question_id
  left join english.difficult_state ds on ds.user_id=d.user_id and ds.question_id=d.question_id
  where d.selection_snapshot='{}'::jsonb
)
update english.daily_current d
set selection_signals=english.daily_signal_codes(
      coalesce(m.reason,'Mixed Revision'),coalesce(m.state_status,'New'),
      m.state_next_review is not null and m.state_next_review <= ((m.quiz_date::timestamp + interval '1 day - 1 millisecond') at time zone 'Asia/Kolkata'),
      coalesce(m.state_starred,false),coalesce(m.state_difficult,false),
      coalesce(m.state_attempts,0)=0 and m.genuine
    ),
    selection_snapshot=jsonb_build_object(
      'backfilled',true,'batchDate',m.quiz_date,'state',coalesce(m.state_status,'New'),
      'attempts',coalesce(m.state_attempts,0),'correct',coalesce(m.state_correct,0),'wrong',coalesce(m.state_wrong,0),
      'accuracy',coalesce(m.state_accuracy,0),'nextReview',m.state_next_review,
      'starred',coalesce(m.state_starred,false),'difficult',coalesce(m.state_difficult,false),
      'category',english.learning_category(m.topic)
    )
from meta m
where d.user_id=m.user_id and d.question_id=m.question_id;

create or replace function public.english_dashboard_summary()
returns jsonb language sql stable security definer
set search_path=pg_catalog,public,english,auth as $$
with d as (
  select count(*)::int stored,
         count(*) filter(where lower(coalesce(status,''))='completed')::int completed
  from english.daily_current where user_id=auth.uid()
), cur as (
  select count(*) filter(where lower(coalesce(status,''))<>'completed')::int remaining
  from english.current_daily_items(auth.uid())
)
select case when auth.uid() is null then jsonb_build_object('ok',false,'error','Authentication required') else jsonb_build_object(
 'ok',true,
 'total_active',(select count(*) from english.questions q where q.active and not exists(select 1 from english.question_state s where s.user_id=auth.uid() and s.question_id=q.question_id and s.mastered)),
 'attempted',(select count(*) from english.question_state s where s.user_id=auth.uid() and s.attempts>0),
 'mastered',(select count(*) from english.question_state s where s.user_id=auth.uid() and s.mastered),
 'starred',(select count(*) from english.question_state s where s.user_id=auth.uid() and s.last_marked),
 'difficult',(select count(*) from english.difficult_state x where x.user_id=auth.uid() and x.difficult),
 'daily_total',d.stored,
 'daily_stored_total',d.stored,
 'daily_completed',d.completed,
 'daily_remaining',cur.remaining,
 'daily_actionable_total',d.completed+cur.remaining,
 'daily_suppressed',greatest(0,d.stored-d.completed-cur.remaining),
 'daily_target_is_maximum',true
) end from d cross join cur;
$$;

create or replace function public.english_start_daily(p_target integer default 120)
returns jsonb language plpgsql security definer
set search_path=pg_catalog,public,english,auth as $$
declare uid uuid:=auth.uid(); info jsonb;
begin
  if uid is null then raise exception 'Authentication required'; end if;
  info:=english.ensure_daily(uid,p_target);
  return info || jsonb_build_object('items',coalesce((
    select jsonb_agg(to_jsonb(x)||jsonb_build_object(
      'selectionSignals',coalesce(d.selection_signals,'{}'::text[]),
      'selectionSnapshot',coalesce(d.selection_snapshot,'{}'::jsonb)
    ) order by x.sequence)
    from english.current_daily_items(uid) x
    join english.daily_current d on d.user_id=uid and d.question_id=x.question_id
    where lower(coalesce(x.status,''))<>'completed'
  ),'[]'::jsonb));
end;
$$;

create or replace function public.english_resume_daily()
returns jsonb language plpgsql security definer
set search_path=pg_catalog,public,english,auth as $$
declare uid uuid:=auth.uid(); info jsonb;
begin
  if uid is null then raise exception 'Authentication required'; end if;
  info:=english.ensure_daily(uid,120);
  return info || jsonb_build_object('items',coalesce((
    select jsonb_agg(to_jsonb(x)||jsonb_build_object(
      'selectionSignals',coalesce(d.selection_signals,'{}'::text[]),
      'selectionSnapshot',coalesce(d.selection_snapshot,'{}'::jsonb)
    ) order by x.sequence)
    from english.current_daily_items(uid) x
    join english.daily_current d on d.user_id=uid and d.question_id=x.question_id
    where lower(coalesce(x.status,''))<>'completed'
  ),'[]'::jsonb));
end;
$$;
