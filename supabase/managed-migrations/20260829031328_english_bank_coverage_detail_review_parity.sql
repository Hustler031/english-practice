create or replace function public.english_get_bank_coverage_category_detail(p_category text)
returns jsonb
language plpgsql stable security definer
set search_path to 'pg_catalog','public','english','auth'
as $function$
declare uid uuid:=auth.uid(); v_cat text:=upper(btrim(coalesce(p_category,''))); v_today date:=(now() at time zone 'Asia/Kolkata')::date; out jsonb;
begin
 if uid is null then raise exception 'Authentication required'; end if;
 with bank as (
   select q.question_id,q.word,q.question,coalesce(s.attempts,0)>0 exposed
   from english.questions q left join english.question_state s on s.user_id=uid and s.question_id=q.question_id
   where english.is_genuine_bank_question(q) and english.learning_category(q.topic)=v_cat
 ), today_last as (
   select distinct on (a.question_id) a.question_id,a.correct,a.attempted_at
   from english.attempts a join bank b on b.question_id=a.question_id
   where a.user_id=uid and lower(coalesce(a.module,''))='bankcoverage' and (a.attempted_at at time zone 'Asia/Kolkata')::date=v_today
   order by a.question_id,a.attempted_at desc,a.attempt_id desc
 ), today_items as (
   select b.question_id,b.word,b.question,t.correct,coalesce(d.difficult,false) difficult
   from today_last t join bank b on b.question_id=t.question_id
   left join english.difficult_state d on d.user_id=uid and d.question_id=t.question_id
 ), previous_day as (
   select max((a.attempted_at at time zone 'Asia/Kolkata')::date) d
   from english.attempts a join bank b on b.question_id=a.question_id
   where a.user_id=uid and lower(coalesce(a.module,''))='bankcoverage' and (a.attempted_at at time zone 'Asia/Kolkata')::date<v_today
 ), previous as (
   select distinct on (a.question_id) a.question_id,a.correct
   from english.attempts a join bank b on b.question_id=a.question_id cross join previous_day p
   where p.d is not null and a.user_id=uid and lower(coalesce(a.module,''))='bankcoverage' and (a.attempted_at at time zone 'Asia/Kolkata')::date=p.d
   order by a.question_id,a.attempted_at desc,a.attempt_id desc
 )
 select jsonb_build_object(
   'id',v_cat,'total',(select count(*) from bank),'exposed',(select count(*) from bank where exposed),'left',(select count(*) from bank where not exposed),
   'coverage',case when (select count(*) from bank)>0 then round((select count(*) from bank where exposed)*100.0/(select count(*) from bank),1) else 0 end,
   'newToday',(select count(*) from today_items),'attemptedToday',(select count(*) from today_items),'todayCorrect',(select count(*) from today_items where correct),
   'todayWrong',(select count(*) from today_items where not correct),'todayDifficult',(select count(*) from today_items where difficult),
   'lastSession',case when (select d from previous_day) is null then null else jsonb_build_object('date',(select d from previous_day),'attempted',(select count(*) from previous),'correct',(select count(*) from previous where correct),'wrong',(select count(*) from previous where not correct)) end
 ) into out;
 return out;
end $function$;

create or replace function public.english_get_bank_coverage_review_batch(p_category text,p_mode text default 'all',p_count integer default 20)
returns jsonb
language plpgsql stable security definer
set search_path to 'pg_catalog','public','english','auth'
as $function$
declare uid uuid:=auth.uid(); v_cat text:=upper(btrim(coalesce(p_category,''))); v_mode text:=lower(btrim(coalesce(p_mode,'all'))); v_n integer:=greatest(1,least(100,coalesce(p_count,20))); v_today date:=(now() at time zone 'Asia/Kolkata')::date; out jsonb;
begin
 if uid is null then raise exception 'Authentication required'; end if;
 with latest as (
  select distinct on (a.question_id) a.question_id,a.correct,a.attempted_at
  from english.attempts a join english.questions q on q.question_id=a.question_id
  where a.user_id=uid and lower(coalesce(a.module,''))='bankcoverage' and (a.attempted_at at time zone 'Asia/Kolkata')::date=v_today
    and english.is_genuine_bank_question(q) and english.learning_category(q.topic)=v_cat
  order by a.question_id,a.attempted_at desc,a.attempt_id desc
 ), eligible as (
  select l.question_id,row_number() over(order by l.attempted_at desc,l.question_id)::int ord
  from latest l left join english.difficult_state d on d.user_id=uid and d.question_id=l.question_id
  where v_mode='all' or (v_mode='wrong' and not l.correct) or (v_mode='difficult' and coalesce(d.difficult,false))
  limit v_n
 )
 select coalesce(jsonb_agg(english.question_payload(uid,e.question_id) order by e.ord),'[]'::jsonb) into out from eligible e;
 return out;
end $function$;
