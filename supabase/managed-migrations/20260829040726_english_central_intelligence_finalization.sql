create or replace function english.central_revision_signals(
  p_status text,p_due boolean,p_difficult boolean,p_starred boolean,p_wrong integer,p_next_review timestamptz
)
returns text[] language sql stable as $$
select array_remove(array[
  nullif(coalesce(p_status,'New'),''),
  case when p_due then 'Due' end,
  case when p_difficult then 'Difficult' end,
  case when p_starred then 'Starred' end,
  case when coalesce(p_wrong,0)>0 then 'Wrong '||p_wrong end,
  case when p_due and p_next_review is not null then
    greatest(0,floor(extract(epoch from (now()-p_next_review))/86400)::int)::text||'d overdue' end
]::text[],null);
$$;

create or replace function public.english_get_revision_batch(p_mode text default 'smart',p_count integer default 30)
returns jsonb language plpgsql stable security definer
set search_path=pg_catalog,public,english,auth as $$
declare uid uuid:=auth.uid();m text:=lower(btrim(coalesce(p_mode,'smart')));n integer:=greatest(1,least(100,coalesce(p_count,30)));out jsonb;
begin
 if uid is null then raise exception 'Authentication required'; end if;
 if m not in ('smart','due','weak','recall','difficult','random') then raise exception 'Unknown revision mode: %',p_mode; end if;
 with base as (
  select q.question_id,coalesce(s.status,'New') status,coalesce(s.attempts,0) attempts,coalesce(s.wrong,0) wrong,
    coalesce(d.difficult,false) difficult,coalesce(s.last_marked,false) starred,s.last_attempt,s.next_review,
    (s.next_review is not null and s.next_review <= (((now() at time zone 'Asia/Kolkata')::date+1)::timestamp at time zone 'Asia/Kolkata')) due
  from english.questions q
  left join english.question_state s on s.user_id=uid and s.question_id=q.question_id
  left join english.difficult_state d on d.user_id=uid and d.question_id=q.question_id
  where q.active and not coalesce(s.mastered,false)
 ), filtered as (
  select * from base where
    (m='smart' and attempts>0 and (due or status in ('Persistent Weak','Weak','Fragile') or difficult)) or
    (m='due' and attempts>0 and due) or
    (m='weak' and status in ('Persistent Weak','Weak','Fragile')) or
    (m='recall' and attempts>0) or
    (m='difficult' and difficult) or m='random'
 ), ranked as (
  select *,row_number() over(order by
    case when m='random' then random() else 0 end,
    case when status='Persistent Weak' and due then 10
         when status='Persistent Weak' then 9
         when status='Weak' and due then 8
         when status='Weak' then 7
         when status='Fragile' and due then 6
         when due then 5
         when status='Fragile' then 4
         when difficult then 3
         when status='Learning' then 2 else 1 end desc,
    difficult desc,wrong desc,coalesce(next_review,'infinity'::timestamptz) asc,
    coalesce(last_attempt,'epoch'::timestamptz) asc,question_id
  )::int ord from filtered
 ), chosen as (select * from ranked order by ord limit n)
 select coalesce(jsonb_agg(
   english.question_payload(uid,c.question_id)||jsonb_build_object(
     'centralRevisionMode',m,
     'centralRevisionSignals',english.central_revision_signals(c.status,c.due,c.difficult,c.starred,c.wrong,c.next_review),
     'centralRevisionReason',case
       when c.status='Persistent Weak' then 'Persistent Weak'
       when c.status='Weak' then 'Weak'
       when c.status='Fragile' then 'Fragile'
       when c.due then 'Due Spaced Revision'
       when c.difficult then 'Difficult'
       else 'Recall Rotation' end
   ) order by c.ord
 ),'[]'::jsonb) into out from chosen c;
 return out;
end $$;

create or replace function public.english_get_central_intelligence()
returns jsonb language sql stable security definer
set search_path=pg_catalog,public,english,auth as $$
with uid as (select auth.uid() id),
q as (
 select qs.question_id,qs.status,qs.attempts,qs.wrong,qs.next_review,qs.mastered,qs.last_marked,
        coalesce(d.difficult,false) difficult,
        (qs.next_review is not null and qs.next_review <= (((now() at time zone 'Asia/Kolkata')::date+1)::timestamp at time zone 'Asia/Kolkata')) due
 from english.question_state qs cross join uid
 left join english.difficult_state d on d.user_id=uid.id and d.question_id=qs.question_id
 where qs.user_id=uid.id
), queues as (
 select
   count(*) filter(where not mastered and status='Persistent Weak')::int persistent_weak,
   count(*) filter(where not mastered and status='Weak')::int weak,
   count(*) filter(where not mastered and status='Fragile')::int fragile,
   count(*) filter(where not mastered and attempts>0 and due)::int due,
   count(*) filter(where not mastered and difficult)::int difficult,
   count(*) filter(where not mastered and last_marked)::int starred,
   count(*) filter(where not mastered and status='Learning')::int learning,
   count(*) filter(where not mastered and status='Strong')::int strong,
   count(*) filter(where not mastered and status='Proven Mastered')::int proven_mastered,
   count(*) filter(where mastered)::int manual_mastered
 from q
), daily as (
 select count(*)::int stored,count(*) filter(where lower(coalesce(status,''))='completed')::int completed
 from english.daily_current cross join uid where user_id=uid.id
), daily_current as (
 select count(*) filter(where lower(coalesce(status,''))<>'completed')::int remaining
 from uid cross join lateral english.current_daily_items(uid.id)
), core as (
 select count(*)::int total,
        count(*) filter(where coalesce(s.attempts,0)>0)::int exposed
 from english.questions x cross join uid
 left join english.question_state s on s.user_id=uid.id and s.question_id=x.question_id
 where english.is_genuine_bank_question(x)
), penalties as (
 select category,penalty,seen_count,weak_count,first_attempt_accuracy,retention_accuracy,
        row_number() over(order by penalty desc,category)::int rn
 from uid cross join lateral english.daily_category_penalties(uid.id)
), recommendation as (
 select case
   when dc.remaining>0 then jsonb_build_object('route','daily','mode','resume','count',dc.remaining,'reason','Finish the current actionable Daily queue')
   when qu.persistent_weak>0 then jsonb_build_object('route','revision','mode','smart','count',least(30,qu.persistent_weak+qu.weak+qu.fragile+qu.due),'reason','Persistent Weak items need priority recall')
   when qu.weak+qu.fragile>0 then jsonb_build_object('route','revision','mode','smart','count',least(30,qu.weak+qu.fragile+qu.due),'reason','Weak and Fragile retention needs attention')
   when qu.due>0 then jsonb_build_object('route','revision','mode','due','count',least(30,qu.due),'reason','Spaced reviews are due')
   when qu.difficult>0 then jsonb_build_object('route','revision','mode','difficult','count',least(30,qu.difficult),'reason','No due backlog; revisit Difficult items')
   when c.exposed<c.total then jsonb_build_object('route','bankCoverage','mode','unseen','count',least(20,c.total-c.exposed),'reason','No urgent retention backlog; expand core-bank exposure')
   else jsonb_build_object('route','revision','mode','recall','count',20,'reason','All urgent queues are clear; maintain recall rotation') end value
 from queues qu cross join daily_current dc cross join core c
)
select case when (select id from uid) is null then jsonb_build_object('ok',false,'error','Authentication required') else jsonb_build_object(
 'ok',true,'version',1,'generatedAt',now(),
 'queues',jsonb_build_object(
   'persistentWeak',qu.persistent_weak,'weak',qu.weak,'fragile',qu.fragile,'due',qu.due,
   'difficult',qu.difficult,'starred',qu.starred,'learning',qu.learning,'strong',qu.strong,
   'provenMastered',qu.proven_mastered,'manualMastered',qu.manual_mastered
 ),
 'daily',jsonb_build_object('stored',d.stored,'completed',d.completed,'actionableRemaining',dc.remaining,
   'suppressed',greatest(0,d.stored-d.completed-dc.remaining),'targetIsMaximum',true),
 'coreCoverage',jsonb_build_object('total',c.total,'exposed',c.exposed,'left',greatest(0,c.total-c.exposed),
   'percent',case when c.total>0 then round(c.exposed*100.0/c.total,1) else 0 end),
 'categoryPriorities',coalesce((select jsonb_agg(jsonb_build_object(
   'category',p.category,'penalty',round(p.penalty,4),'seen',p.seen_count,'weak',p.weak_count,
   'firstAttemptAccuracy',p.first_attempt_accuracy,'retentionAccuracy',p.retention_accuracy
 ) order by p.rn) from penalties p where p.rn<=5),'[]'::jsonb),
 'recommended',(select value from recommendation)
) end
from queues qu cross join daily d cross join daily_current dc cross join core c;
$$;

revoke execute on function public.english_get_revision_batch(text,integer) from public,anon;
grant execute on function public.english_get_revision_batch(text,integer) to authenticated,service_role;
revoke execute on function public.english_get_central_intelligence() from public,anon;
grant execute on function public.english_get_central_intelligence() to authenticated,service_role;
