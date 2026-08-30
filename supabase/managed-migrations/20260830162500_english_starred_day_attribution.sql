-- Ensure every new Starred event is attributed to the actual English day,
-- and repair legacy NULL day_no rows from their IST event date.

update english.star_events
set day_no = english.daily_day_no(
  coalesce(starred_date, (event_at at time zone 'Asia/Kolkata')::date)
)
where day_no is null;

create or replace function public.english_set_starred(p_question_id text, p_starred boolean)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'english', 'auth'
as $function$
declare
  uid uuid:=auth.uid();
  q english.questions%rowtype;
  v_current boolean;
  v_state jsonb;
  v_date date := (now() at time zone 'Asia/Kolkata')::date;
begin
  if uid is null then raise exception 'Authentication required'; end if;
  select * into q from english.questions where question_id=btrim(p_question_id) and english.question_visible_to_user(uid,question_id);
  if not found then raise exception 'Question not found'; end if;
  select (action='STAR') into v_current from english.star_events where user_id=uid and question_id=q.question_id order by event_at desc,id desc limit 1;
  if found and v_current=coalesce(p_starred,false) then
    return jsonb_build_object('ok',true,'deduped',true,'question_id',q.question_id,'starred',v_current);
  end if;
  insert into english.star_events(user_id,question_id,event_at,starred_date,day_no,action)
  values(uid,q.question_id,now(),v_date,english.daily_day_no(v_date),case when p_starred then 'STAR' else 'UNSTAR' end);
  select english.recompute_question_state(uid,q.question_id) into v_state;
  return jsonb_build_object('ok',true,'deduped',false,'question_id',q.question_id,'starred',coalesce(p_starred,false),'state',v_state);
end;
$function$;

create or replace function english.starred_manual_index(p_user_id uuid)
returns table(question_id text, origin_day integer, starred boolean, mastered boolean, difficult boolean)
language sql
stable security definer
set search_path to 'pg_catalog', 'english', 'auth'
as $function$
with ev as (
  select e.question_id,bool_or(e.action='STAR') ever_starred
  from english.star_events e where e.user_id=p_user_id group by e.question_id
), latest as (
  select distinct on (e.question_id)
         e.question_id,
         greatest(1,coalesce(e.day_no,english.daily_day_no(coalesce(e.starred_date,(e.event_at at time zone 'Asia/Kolkata')::date)),1))::int day_no,
         e.action
  from english.star_events e where e.user_id=p_user_id
  order by e.question_id,e.event_at desc,e.source_row desc nulls last,e.id desc
)
select qs.question_id,greatest(1,coalesce(l.day_no,1))::int,
       coalesce(qs.last_marked,false),coalesce(qs.mastered,false),coalesce(d.difficult,false)
from english.question_state qs
join english.questions q on q.question_id=qs.question_id and q.active
left join ev on ev.question_id=qs.question_id
left join latest l on l.question_id=qs.question_id
left join english.difficult_state d on d.user_id=qs.user_id and d.question_id=qs.question_id
where qs.user_id=p_user_id
  and (coalesce(ev.ever_starred,false) or coalesce(qs.last_marked,false))
  and (coalesce(qs.last_marked,false) or coalesce(qs.mastered,false));
$function$;

create or replace function english.starred_revision_candidates(p_user_id uuid)
returns table(question_id text, state text, due boolean, difficult boolean, controlled_new boolean, never_revised boolean, revised_count integer, last_revision timestamp with time zone, days_since_revision integer, origin_day integer)
language sql
stable security definer
set search_path to 'pg_catalog', 'english', 'auth'
as $function$
with mods as (
 select a.question_id,count(*)::int revised_count,max(a.attempted_at) last_revision from english.attempts a where a.user_id=p_user_id and lower(coalesce(a.module,''))='starredrevision' group by a.question_id
), ev as (
 select distinct on (e.question_id)
        e.question_id,
        greatest(1,coalesce(e.day_no,english.daily_day_no(coalesce(e.starred_date,(e.event_at at time zone 'Asia/Kolkata')::date)),1))::int day_no
 from english.star_events e where e.user_id=p_user_id
 order by e.question_id,e.event_at desc,e.source_row desc nulls last,e.id desc
)
select q.question_id,coalesce(s.status,'New'),(s.next_review is not null and s.next_review <= (((now() at time zone 'Asia/Kolkata')::date+1)::timestamp at time zone 'Asia/Kolkata')),
 coalesce(d.difficult,false),coalesce(s.attempts,0)=0,coalesce(m.revised_count,0)=0,coalesce(m.revised_count,0),m.last_revision,
 case when m.last_revision is null then null else greatest(0,floor(extract(epoch from (now()-m.last_revision))/86400)::int) end,
 greatest(1,coalesce(ev.day_no,1))
from english.questions q join english.question_state s on s.user_id=p_user_id and s.question_id=q.question_id and coalesce(s.last_marked,false)
left join english.difficult_state d on d.user_id=p_user_id and d.question_id=q.question_id left join mods m on m.question_id=q.question_id left join ev on ev.question_id=q.question_id
where q.active and not coalesce(s.mastered,false);
$function$;
