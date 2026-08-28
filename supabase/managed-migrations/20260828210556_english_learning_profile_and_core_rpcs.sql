alter table english.attempts add column if not exists source_row bigint;
create index if not exists english_attempts_learning_order_idx on english.attempts(user_id,question_id,attempted_at,source_row);

create or replace function english.learning_profile(p_user_id uuid,p_question_id text)
returns table(
  attempts integer, correct integer, wrong integer, accuracy numeric,
  marked_count integer, avg_time numeric, first_attempt timestamptz,
  last_attempt timestamptz, last_result boolean, last_time numeric,
  correct_streak integer, state text, next_review timestamptz,
  checkpoint_count integer, checkpoint_wrong integer,
  recent_checkpoint_wrong integer, proven_mastery boolean
)
language sql stable security definer
set search_path=pg_catalog,english,auth
as $$
with a as (
  select x.*,
    (x.attempted_at at time zone 'Asia/Kolkata')::date as study_date,
    row_number() over(
      partition by (x.attempted_at at time zone 'Asia/Kolkata')::date
      order by x.attempted_at, x.source_row nulls last, x.created_at, x.attempt_id
    ) as day_rn
  from english.attempts x
  where x.user_id=p_user_id and x.question_id=p_question_id
),
tot as (
  select
    count(*)::int as attempts,
    count(*) filter(where coalesce(correct,false))::int as correct,
    count(*) filter(where not coalesce(correct,false))::int as wrong,
    count(*) filter(where coalesce(marked_revision,false))::int as marked_count,
    avg(time_seconds) filter(where time_seconds>0 and time_seconds<=180) as avg_time,
    min(attempted_at) as first_attempt,
    max(attempted_at) as last_attempt,
    (array_agg(coalesce(correct,false) order by attempted_at desc,source_row desc nulls last,created_at desc,attempt_id desc))[1] as last_result,
    (array_agg(time_seconds order by attempted_at desc,source_row desc nulls last,created_at desc,attempt_id desc))[1] as last_time
  from a
),
cp0 as (
  select * from a where day_rn=1
),
cp as (
  select c.*,
    row_number() over(order by study_date desc,attempted_at desc,source_row desc nulls last,created_at desc,attempt_id desc) as rev_no
  from cp0 c
),
cpa as (
  select
    count(*)::int as checkpoint_count,
    count(*) filter(where not coalesce(correct,false))::int as checkpoint_wrong,
    array_agg(coalesce(correct,false) order by study_date desc,attempted_at desc,source_row desc nulls last,created_at desc,attempt_id desc) as results_desc,
    array_agg(study_date order by study_date desc,attempted_at desc,source_row desc nulls last,created_at desc,attempt_id desc) as dates_desc,
    array_agg(attempted_at order by study_date desc,attempted_at desc,source_row desc nulls last,created_at desc,attempt_id desc) as times_desc,
    count(*) filter(where rev_no<=4 and not coalesce(correct,false))::int as recent_checkpoint_wrong
  from cp
),
calc as (
  select tot.*, cpa.*,
    coalesce(
      (select min(i)-1 from generate_subscripts(cpa.results_desc,1) g(i) where cpa.results_desc[i]=false),
      cardinality(cpa.results_desc),0
    )::int as streak,
    cpa.results_desc[1] as last_checkpoint_correct,
    cpa.dates_desc[1] as last_checkpoint_date,
    cpa.dates_desc[2] as previous_checkpoint_date,
    cpa.times_desc[1] as last_checkpoint_at
  from tot cross join cpa
),
classified as (
  select calc.*,
    case
      when calc.attempts=0 then 'New'
      when calc.last_checkpoint_correct=false then case when calc.recent_checkpoint_wrong>=2 then 'Persistent Weak' else 'Weak' end
      when calc.streak>=4 and calc.previous_checkpoint_date is not null and (calc.last_checkpoint_date-calc.previous_checkpoint_date)>=5 then 'Proven Mastered'
      when calc.streak>=3 then 'Strong'
      when calc.checkpoint_wrong>0 then 'Fragile'
      else 'Learning'
    end as derived_state
  from calc
),
final as (
  select classified.*,
    case
      when attempts=0 then 0
      when derived_state in ('Persistent Weak','Weak') then 1
      when derived_state='Fragile' then case when streak>=2 then 3 else 2 end
      when derived_state='Learning' then 1
      when derived_state='Strong' then 7
      when derived_state='Proven Mastered' then 30
      else 7
    end as interval_days
  from classified
)
select
  attempts,
  correct,
  wrong,
  case when attempts>0 then correct::numeric/attempts else 0::numeric end,
  marked_count,
  coalesce(avg_time,0::numeric),
  first_attempt,
  last_attempt,
  last_result,
  least(180::numeric,greatest(0::numeric,coalesce(last_time,0::numeric))),
  streak,
  derived_state,
  case when attempts>0 and last_checkpoint_at is not null then last_checkpoint_at + make_interval(days=>interval_days) else null end,
  coalesce(checkpoint_count,0),
  coalesce(checkpoint_wrong,0),
  coalesce(recent_checkpoint_wrong,0),
  (derived_state='Proven Mastered')
from final;
$$;

create or replace function english.recompute_question_state(p_user_id uuid,p_question_id text)
returns jsonb
language plpgsql security definer
set search_path=pg_catalog,english,auth
as $$
declare
  p record; q english.questions%rowtype; old english.question_state%rowtype;
  v_marked boolean; v_mastered boolean; v_mastered_on timestamptz;
  v_repeat timestamptz; v_recall integer; v_status text; v_next timestamptz;
begin
  select * into q from english.questions where question_id=p_question_id;
  if not found then raise exception 'Question not found'; end if;
  select * into p from english.learning_profile(p_user_id,p_question_id);
  select * into old from english.question_state where user_id=p_user_id and question_id=p_question_id;
  v_repeat:=old.repeat_suppressed_until;
  v_recall:=coalesce(old.recall_check_count,0);

  select case when se.action='STAR' then true else false end into v_marked
  from english.star_events se
  where se.user_id=p_user_id and se.question_id=p_question_id
  order by se.event_at desc,se.id desc limit 1;
  if not found then v_marked:=coalesce(old.last_marked,false); end if;

  select bool_or(me.active and me.restored_on is null),
         max(me.mastered_on) filter(where me.active and me.restored_on is null)
  into v_mastered,v_mastered_on
  from english.mastery_events me
  where me.user_id=p_user_id and me.question_id=p_question_id;
  v_mastered:=coalesce(v_mastered,coalesce(old.mastered,false));
  if v_mastered and v_mastered_on is null then v_mastered_on:=old.mastered_on; end if;
  if not v_mastered then v_mastered_on:=null; v_repeat:=null; end if;
  v_status:=case when v_mastered then 'Mastered' else p.state end;
  v_next:=case when v_mastered then null else p.next_review end;

  insert into english.question_state(
    user_id,question_id,attempts,correct,wrong,accuracy,marked_count,avg_time,
    last_attempt,last_result,last_time,last_marked,correct_streak,status,next_review,
    mastered,mastered_on,repeat_suppressed_until,recall_check_count,updated_at
  ) values(
    p_user_id,p_question_id,p.attempts,p.correct,p.wrong,p.accuracy,p.marked_count,p.avg_time,
    p.last_attempt,p.last_result,p.last_time,v_marked,p.correct_streak,v_status,v_next,
    v_mastered,v_mastered_on,v_repeat,v_recall,now()
  )
  on conflict(user_id,question_id) do update set
    attempts=excluded.attempts,correct=excluded.correct,wrong=excluded.wrong,accuracy=excluded.accuracy,
    marked_count=excluded.marked_count,avg_time=excluded.avg_time,last_attempt=excluded.last_attempt,
    last_result=excluded.last_result,last_time=excluded.last_time,last_marked=excluded.last_marked,
    correct_streak=excluded.correct_streak,status=excluded.status,next_review=excluded.next_review,
    mastered=excluded.mastered,mastered_on=excluded.mastered_on,
    repeat_suppressed_until=excluded.repeat_suppressed_until,
    recall_check_count=excluded.recall_check_count,updated_at=excluded.updated_at;

  update english.questions set
    learning_status=v_status,
    first_seen_date=case when p.attempts>0 then p.first_attempt else first_seen_date end,
    last_seen_date=case when p.attempts>0 then p.last_attempt else last_seen_date end,
    seen_count=case when p.attempts>0 then p.attempts else coalesce(seen_count,0) end,
    updated_at=now()
  where question_id=p_question_id;

  return jsonb_build_object('question_id',p_question_id,'attempts',p.attempts,'correct',p.correct,'wrong',p.wrong,'status',v_status,'next_review',v_next,'mastered',v_mastered,'starred',v_marked,'correct_streak',p.correct_streak);
end;
$$;

create or replace function english.reconcile_learning_state(p_user_id uuid)
returns jsonb
language plpgsql security definer
set search_path=pg_catalog,english,auth
as $$
declare v_id text; v_n integer:=0;
begin
  if not exists(select 1 from auth.users where id=p_user_id) then raise exception 'User not found'; end if;
  for v_id in
    select question_id from english.question_state where user_id=p_user_id
    union
    select question_id from english.attempts where user_id=p_user_id
  loop
    perform english.recompute_question_state(p_user_id,v_id); v_n:=v_n+1;
  end loop;
  return jsonb_build_object('ok',true,'rows',v_n);
end;
$$;

create or replace function public.english_submit_answer(
  p_question_id text,
  p_selected_key text,
  p_time_seconds numeric default 0,
  p_marked_revision boolean default false,
  p_attempt_id text default null,
  p_module text default 'practice'
) returns jsonb
language plpgsql security definer
set search_path=pg_catalog,public,english,auth
as $$
declare uid uuid:=auth.uid(); q english.questions%rowtype; v_id text; v_correct boolean; v_rows integer; v_state jsonb;
begin
  if uid is null then raise exception 'Authentication required'; end if;
  select * into q from english.questions where question_id=btrim(p_question_id);
  if not found then raise exception 'Question not found'; end if;
  if upper(btrim(p_selected_key)) not in ('A','B','C','D') then raise exception 'Invalid answer'; end if;
  v_correct:=upper(btrim(p_selected_key))=upper(coalesce(q.correct,''));
  v_id:=coalesce(nullif(btrim(p_attempt_id),''),q.question_id||'-'||floor(extract(epoch from clock_timestamp())*1000)::bigint||'-'||substr(replace(gen_random_uuid()::text,'-',''),1,6));
  insert into english.attempts(attempt_id,user_id,question_id,attempted_at,selected_answer,correct,time_seconds,marked_revision,topic,concept_id,module,submission_key,created_at)
  values(v_id,uid,q.question_id,now(),upper(btrim(p_selected_key)),v_correct,least(180,greatest(0,coalesce(p_time_seconds,0))),coalesce(p_marked_revision,false),q.topic,q.concept_id,coalesce(nullif(btrim(p_module),''),'practice'),v_id,now())
  on conflict do nothing;
  get diagnostics v_rows=row_count;
  if v_rows=0 then
    select english.recompute_question_state(uid,q.question_id) into v_state;
    return jsonb_build_object('ok',true,'deduped',true,'attempt_id',v_id,'is_correct',v_correct,'correct_key',upper(coalesce(q.correct,'')),'state',v_state);
  end if;
  select english.recompute_question_state(uid,q.question_id) into v_state;
  if lower(coalesce(p_module,''))='daily' then update english.daily_current set status='Completed' where user_id=uid and question_id=q.question_id; end if;
  return jsonb_build_object('ok',true,'deduped',false,'attempt_id',v_id,'is_correct',v_correct,'correct_key',upper(coalesce(q.correct,'')),'state',v_state);
end;
$$;

create or replace function public.english_set_starred(p_question_id text,p_starred boolean)
returns jsonb language plpgsql security definer
set search_path=pg_catalog,public,english,auth
as $$
declare uid uuid:=auth.uid(); q english.questions%rowtype; v_current boolean; v_state jsonb;
begin
  if uid is null then raise exception 'Authentication required'; end if;
  select * into q from english.questions where question_id=btrim(p_question_id);
  if not found then raise exception 'Question not found'; end if;
  select (action='STAR') into v_current from english.star_events where user_id=uid and question_id=q.question_id order by event_at desc,id desc limit 1;
  if found and v_current=coalesce(p_starred,false) then
    return jsonb_build_object('ok',true,'deduped',true,'question_id',q.question_id,'starred',v_current);
  end if;
  insert into english.star_events(user_id,question_id,event_at,starred_date,day_no,action)
  values(uid,q.question_id,now(),(now() at time zone 'Asia/Kolkata')::date,null,case when p_starred then 'STAR' else 'UNSTAR' end);
  select english.recompute_question_state(uid,q.question_id) into v_state;
  return jsonb_build_object('ok',true,'deduped',false,'question_id',q.question_id,'starred',coalesce(p_starred,false),'state',v_state);
end;
$$;

create or replace function public.english_set_difficult(p_question_id text,p_difficult boolean)
returns jsonb language plpgsql security definer
set search_path=pg_catalog,public,english,auth
as $$
declare uid uuid:=auth.uid(); q english.questions%rowtype; v_mastered boolean;
begin
  if uid is null then raise exception 'Authentication required'; end if;
  select * into q from english.questions where question_id=btrim(p_question_id) and active;
  if not found then return jsonb_build_object('ok',false,'reason','not-active-question'); end if;
  select coalesce(mastered,false) into v_mastered from english.question_state where user_id=uid and question_id=q.question_id;
  if coalesce(v_mastered,false) then return jsonb_build_object('ok',false,'reason','mastered'); end if;
  insert into english.difficult_state(user_id,question_id,difficult,updated_at)
  values(uid,q.question_id,coalesce(p_difficult,false),now())
  on conflict(user_id,question_id) do update set difficult=excluded.difficult,updated_at=excluded.updated_at;
  return jsonb_build_object('ok',true,'question_id',q.question_id,'difficult',coalesce(p_difficult,false));
end;
$$;

create or replace function public.english_set_mastered(p_question_id text,p_mastered boolean,p_require_proven boolean default false)
returns jsonb language plpgsql security definer
set search_path=pg_catalog,public,english,auth
as $$
declare uid uuid:=auth.uid(); q english.questions%rowtype; p record; v_state jsonb;
begin
  if uid is null then raise exception 'Authentication required'; end if;
  select * into q from english.questions where question_id=btrim(p_question_id);
  if not found then raise exception 'Question not found'; end if;
  select * into p from english.learning_profile(uid,q.question_id);
  if coalesce(p_mastered,false) then
    if coalesce(p_require_proven,false) and not p.proven_mastery then raise exception 'Retention not proven yet'; end if;
    if not exists(select 1 from english.mastery_events where user_id=uid and question_id=q.question_id and active and restored_on is null) then
      insert into english.mastery_events(user_id,question_id,mastered_on,reason,previous_status,source,category,restored_on,active)
      values(uid,q.question_id,now(),'User marked as easy/mastered',(select status from english.question_state where user_id=uid and question_id=q.question_id),'v2',q.topic,null,true);
    end if;
  else
    update english.mastery_events set active=false,restored_on=coalesce(restored_on,now()) where user_id=uid and question_id=q.question_id and active;
    update english.question_state set mastered=false,mastered_on=null,repeat_suppressed_until=null where user_id=uid and question_id=q.question_id;
  end if;
  select english.recompute_question_state(uid,q.question_id) into v_state;
  return jsonb_build_object('ok',true,'question_id',q.question_id,'mastered',coalesce(p_mastered,false),'state',v_state);
end;
$$;

create or replace function public.english_dashboard_summary()
returns jsonb language sql stable security definer
set search_path=pg_catalog,public,english,auth
as $$
select case when auth.uid() is null then jsonb_build_object('ok',false,'error','Authentication required') else jsonb_build_object(
 'ok',true,
 'total_active',(select count(*) from english.questions q where q.active and not exists(select 1 from english.question_state s where s.user_id=auth.uid() and s.question_id=q.question_id and s.mastered)),
 'attempted',(select count(*) from english.question_state s where s.user_id=auth.uid() and s.attempts>0),
 'mastered',(select count(*) from english.question_state s where s.user_id=auth.uid() and s.mastered),
 'starred',(select count(*) from english.question_state s where s.user_id=auth.uid() and s.last_marked),
 'difficult',(select count(*) from english.difficult_state d where d.user_id=auth.uid() and d.difficult),
 'daily_total',(select count(*) from english.daily_current d where d.user_id=auth.uid()),
 'daily_completed',(select count(*) from english.daily_current d where d.user_id=auth.uid() and lower(coalesce(d.status,''))='completed')
) end;
$$;

revoke all on function public.english_submit_answer(text,text,numeric,boolean,text,text) from public;
revoke all on function public.english_set_starred(text,boolean) from public;
revoke all on function public.english_set_difficult(text,boolean) from public;
revoke all on function public.english_set_mastered(text,boolean,boolean) from public;
revoke all on function public.english_dashboard_summary() from public;
grant execute on function public.english_submit_answer(text,text,numeric,boolean,text,text) to authenticated;
grant execute on function public.english_set_starred(text,boolean) to authenticated;
grant execute on function public.english_set_difficult(text,boolean) to authenticated;
grant execute on function public.english_set_mastered(text,boolean,boolean) to authenticated;
grant execute on function public.english_dashboard_summary() to authenticated;
