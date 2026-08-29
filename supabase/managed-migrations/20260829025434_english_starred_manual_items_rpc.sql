create or replace function public.english_get_starred_manual_items(p_mode text default 'all', p_from_day integer default null, p_to_day integer default null)
returns jsonb
language plpgsql
stable security definer
set search_path to 'pg_catalog','public','english','auth'
as $function$
declare uid uuid:=auth.uid(); m text:=lower(btrim(coalesce(p_mode,'all'))); out jsonb;
begin
 if uid is null then raise exception 'Authentication required'; end if;
 if m not in ('all','mastered') then raise exception 'Unknown Starred manual view mode: %',p_mode; end if;
 with latest_star as (
   select distinct on (e.question_id) e.question_id,e.day_no
   from english.star_events e
   where e.user_id=uid
   order by e.question_id,e.event_at desc,e.source_row desc nulls last,e.id desc
 ), rows as (
   select qs.question_id,greatest(1,coalesce(ls.day_no,1))::int origin_day,coalesce(qs.mastered,false) mastered
   from english.question_state qs
   join english.questions q on q.question_id=qs.question_id and q.active
   left join latest_star ls on ls.question_id=qs.question_id
   where qs.user_id=uid and coalesce(qs.last_marked,false)
     and (p_from_day is null or greatest(1,coalesce(ls.day_no,1))>=p_from_day)
     and (p_to_day is null or greatest(1,coalesce(ls.day_no,1))<=p_to_day)
     and (m<>'mastered' or coalesce(qs.mastered,false))
 )
 select coalesce(jsonb_agg(english.question_payload(uid,r.question_id)||jsonb_build_object('starredDay',r.origin_day,'mastered',r.mastered) order by r.origin_day desc,r.question_id),'[]'::jsonb) into out from rows r;
 return out;
end;
$function$;

grant execute on function public.english_get_starred_manual_items(text,integer,integer) to authenticated;
