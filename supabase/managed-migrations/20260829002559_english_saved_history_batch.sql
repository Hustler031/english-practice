create or replace function public.english_get_saved_history_batch(p_date date,p_mode text default 'all',p_count integer default 100)
returns jsonb language plpgsql stable security definer
set search_path='pg_catalog','public','english','auth'
as $$
declare uid uuid:=auth.uid();m text:=lower(btrim(coalesce(p_mode,'all')));n integer:=greatest(1,least(100,coalesce(p_count,100)));out jsonb;
begin
 if uid is null then raise exception 'Authentication required'; end if;
 if p_date is null then return '[]'::jsonb; end if;
 with base as (
  select c.*,case when c.due and c.state='Persistent Weak' then 8 when c.due and c.state='Weak' then 7 when c.due and c.state='Fragile' then 6 when c.due then 5 when c.difficult then 4 when c.never_revised then 3 when c.state in ('Learning','New') then 2 else 1 end tier
  from english.saved_revision_candidates(uid)c where not c.mastered and (c.created_at at time zone 'Asia/Kolkata')::date=p_date
  and (m<>'weak' or c.state in ('Persistent Weak','Weak','Fragile')) and (m<>'difficult' or c.difficult) and (m<>'starred' or c.starred)
 ), ranked as (
  select b.question_id,row_number() over(order by case when m='random' then random() else 0 end,case when m='all' then b.never_revised::int else b.tier end desc,case when m='all' then coalesce(b.last_revision,'epoch'::timestamptz) end asc,b.due desc,b.difficult desc,coalesce(b.days_since_revision,1000000000) desc,b.question_id)::int ord from base b
 )
 select coalesce(jsonb_agg(english.question_payload(uid,r.question_id)||jsonb_build_object('smartMySaved',true,'smartMySavedReason','Saved History') order by r.ord),'[]'::jsonb) into out from ranked r where r.ord<=n;
 return out;
end $$;
grant execute on function public.english_get_saved_history_batch(date,text,integer) to authenticated;

create or replace function public.english_get_saved_revision_hub() returns jsonb
language sql stable security definer
set search_path='pg_catalog','public','english','auth'
as $$
with c as (select * from english.saved_revision_candidates(auth.uid())),
stats as (
 select count(*)::int saved,count(*) filter(where not mastered)::int eligible,count(*) filter(where not mastered and controlled_new)::int controlled_new,
 count(*) filter(where not mastered and never_revised)::int never_revised,count(*) filter(where not mastered and due)::int due,
 count(*) filter(where not mastered and state in ('Persistent Weak','Weak','Fragile'))::int weak,
 count(*) filter(where not mastered and difficult)::int difficult,count(*) filter(where not mastered and starred)::int starred,
 count(*) filter(where mastered)::int mastered from c
), days as (
 select (created_at at time zone 'Asia/Kolkata')::date d,count(*)::int saved,
 count(*) filter(where not mastered)::int eligible,count(*) filter(where not mastered and controlled_new)::int controlled_new,
 count(*) filter(where not mastered and due)::int due,count(*) filter(where not mastered and state in ('Persistent Weak','Weak','Fragile'))::int weak,
 count(*) filter(where not mastered and difficult)::int difficult,count(*) filter(where mastered)::int mastered
 from c group by 1
)
select jsonb_build_object(
 'version','V2','stats',jsonb_build_object('saved',s.saved,'eligible',s.eligible,'controlledNew',s.controlled_new,'neverRevised',s.never_revised,'due',s.due,'weak',s.weak,'difficult',s.difficult,'starred',s.starred,'mastered',s.mastered),
 'available',jsonb_build_object('smart',s.eligible,'weak',s.weak,'difficult',s.difficult,'starred',s.starred,'random',s.eligible,'all',s.eligible),
 'sizes',jsonb_build_array(10,20,30,50),
 'history',coalesce((select jsonb_agg(jsonb_build_object('date',d,'label',case when d is null then 'Imported Saved' else to_char(d,'DD Mon YYYY') end,'saved',saved,'eligible',eligible,'controlledNew',controlled_new,'due',due,'weak',weak,'difficult',difficult,'mastered',mastered) order by d desc nulls last) from days),'[]'::jsonb)
) from stats s;
$$;
