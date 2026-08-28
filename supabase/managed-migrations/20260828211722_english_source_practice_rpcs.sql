create or replace function public.english_get_source_hub()
returns jsonb language sql stable security definer set search_path=pg_catalog,public,english,auth as $$
with pool as (
 select q.question_id,q.topic,english.source_descriptor_key(q) source_key,english.source_descriptor_name(q) source_name,english.recent_content_date(q) added,coalesce(s.status,'New') st
 from english.questions q left join english.question_state s on s.user_id=auth.uid() and s.question_id=q.question_id
 where auth.uid() is not null and q.active and not coalesce(s.mastered,false) and english.recent_content_date(q)>='2026-08-15' and english.source_descriptor_key(q) is not null
), g as (
 select source_key,min(source_name) name,count(*) count,count(*) filter(where st in ('Persistent Weak','Weak','Fragile')) weak,count(*) filter(where added>=((now() at time zone 'Asia/Kolkata')::date-6)) recent,max(added) latest,string_agg(distinct english.canonical_category(topic),', ' order by english.canonical_category(topic)) categories
 from pool group by source_key
)
select coalesce(jsonb_agg(jsonb_build_object('key',g.source_key,'name',g.name,'count',g.count,'weak',g.weak,'recent',g.recent,'latest',g.latest,'categorySummary',g.categories,'children',case when g.source_key='THE_HINDU' then (select coalesce(jsonb_agg(jsonb_build_object('key','THE_HINDU::'||x.added::text,'date',x.added,'count',x.n,'weak',x.w) order by x.added desc),'[]'::jsonb) from (select p.added,count(*) n,count(*) filter(where p.st in ('Persistent Weak','Weak','Fragile')) w from pool p where p.source_key='THE_HINDU' group by p.added) x) else '[]'::jsonb end) order by case g.source_key when 'HANDWRITTEN' then 1 when 'THE_HINDU' then 2 when 'SCREENSHOTS' then 3 else 4 end,g.latest desc,g.name),'[]'::jsonb) from g; $$;

create or replace function public.english_get_source_batch(p_source_key text,p_mode text default 'all',p_count integer default 20)
returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public,english,auth as $$
declare uid uuid:=auth.uid();v_key text:=btrim(coalesce(p_source_key,''));v_mode text:=lower(btrim(coalesce(p_mode,'all')));v_n integer:=greatest(1,least(100,coalesce(p_count,20)));v_date date;out jsonb;
begin
 if uid is null then raise exception 'Authentication required'; end if;
 if v_key like 'THE_HINDU::%' then begin v_date:=substring(v_key from 12)::date; exception when others then v_date:=null; end; end if;
 with base as (
  select q.question_id,coalesce(s.status,'New') st,coalesce(s.attempts,0) att,coalesce(s.last_marked,false) starred,english.recent_content_date(q) added
  from english.questions q left join english.question_state s on s.user_id=uid and s.question_id=q.question_id
  where q.active and not coalesce(s.mastered,false) and english.recent_content_date(q)>='2026-08-15'
    and ((v_date is not null and english.source_descriptor_key(q)='THE_HINDU' and english.recent_content_date(q)=v_date) or (v_date is null and english.source_descriptor_key(q)=v_key))
    and (v_mode<>'weak' or coalesce(s.status,'New') in ('Persistent Weak','Weak','Fragile'))
 ), ranked as (
  select question_id,row_number() over(order by case when v_mode='random' and st in ('Persistent Weak','Weak','Fragile') then 0 when v_mode='random' and added>=((now() at time zone 'Asia/Kolkata')::date-6) then 1 when v_mode='random' and starred then 2 when v_mode='random' and att>0 then 3 else 4 end,case when v_mode in ('weak','random') then random() else 0 end,question_id)::int ord from base
 ), chosen as (select * from ranked order by ord limit v_n)
 select coalesce(jsonb_agg(english.question_payload(uid,c.question_id) order by c.ord),'[]'::jsonb) into out from chosen c;
 return out;
end; $$;

revoke all on function public.english_get_source_hub() from public;
revoke all on function public.english_get_source_batch(text,text,integer) from public;
grant execute on function public.english_get_source_hub() to authenticated;
grant execute on function public.english_get_source_batch(text,text,integer) to authenticated;
