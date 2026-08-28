create or replace function public.english_get_demand_batch(p_set_id text default '__ALL__',p_mode text default 'all',p_count integer default 20)
returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public,english,auth as $$
declare uid uuid:=auth.uid();v_id text:=btrim(coalesce(p_set_id,'__ALL__'));v_mode text:=lower(btrim(coalesce(p_mode,'all')));v_n integer:=greatest(1,least(100,coalesce(p_count,20)));out jsonb;
begin
 if uid is null then raise exception 'Authentication required'; end if;
 with base as (
  select q.question_id,min(i.sequence)::int seq,english.recent_content_date(q) added,coalesce(s.status,'New') st,coalesce(s.wrong,0) wr,coalesce(s.attempts,0) att,coalesce(s.last_marked,false) starred
  from english.practice_set_items i join english.practice_sets ps on ps.set_id=i.set_id join english.questions q on q.question_id=i.question_id left join english.question_state s on s.user_id=uid and s.question_id=q.question_id
  where ps.active and (v_id='__ALL__' or i.set_id=v_id) and q.active and not coalesce(s.mastered,false)
    and (v_mode<>'weak' or coalesce(s.status,'New') in ('Persistent Weak','Weak','Fragile') or coalesce(s.wrong,0)>0 or coalesce(s.attempts,0)>0)
  group by q.question_id,s.status,s.wrong,s.attempts,s.last_marked
 ), ranked as (
  select b.question_id,row_number() over(order by
    case when v_mode='random' and (b.st in ('Persistent Weak','Weak','Fragile') or b.wr>0) then 0 when v_mode='random' and b.added>=((now() at time zone 'Asia/Kolkata')::date-6) then 1 when v_mode='random' and b.starred then 2 when v_mode='random' and b.att>0 then 3 else 4 end,
    case when v_mode in ('weak','random') then random() else b.seq::double precision end,b.question_id)::int ord
  from base b
 ), chosen as (select * from ranked order by ord limit case when v_mode='all' then 100 else v_n end)
 select coalesce(jsonb_agg(english.question_payload(uid,c.question_id) order by c.ord),'[]'::jsonb) into out from chosen c;
 return out;
end; $$;
revoke all on function public.english_get_demand_batch(text,text,integer) from public;
grant execute on function public.english_get_demand_batch(text,text,integer) to authenticated;
