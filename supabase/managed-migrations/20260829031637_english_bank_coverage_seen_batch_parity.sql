create or replace function public.english_get_bank_coverage_seen_batch(p_category text,p_count integer default 10)
returns jsonb
language plpgsql stable security definer
set search_path to 'pg_catalog','public','english','auth'
as $function$
declare uid uuid:=auth.uid();v_cat text:=upper(btrim(coalesce(p_category,'')));v_n integer:=greatest(1,least(100,coalesce(p_count,10)));out jsonb;
begin
 if uid is null then raise exception 'Authentication required'; end if;
 with chosen as (
   select q.question_id,row_number() over(order by coalesce(s.last_attempt,'epoch'::timestamptz),q.question_id)::int ord
   from english.questions q join english.question_state s on s.user_id=uid and s.question_id=q.question_id
   where english.is_genuine_bank_question(q) and english.learning_category(q.topic)=v_cat and coalesce(s.attempts,0)>0 and not coalesce(s.mastered,false)
   order by coalesce(s.last_attempt,'epoch'::timestamptz),q.question_id limit v_n
 )
 select coalesce(jsonb_agg(english.question_payload(uid,c.question_id) order by c.ord),'[]'::jsonb) into out from chosen c;
 return out;
end $function$;
