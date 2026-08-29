create or replace function public.english_get_bank_coverage_category_detail(p_category text)
returns jsonb
language plpgsql stable security definer
set search_path to 'pg_catalog','public','english','auth'
as $function$
declare uid uuid:=auth.uid(); v_cat text:=upper(btrim(coalesce(p_category,''))); v_today date:=(now() at time zone 'Asia/Kolkata')::date; out jsonb;
begin
 if uid is null then raise exception 'Authentication required'; end if;
 with bank as (
   select q.question_id,q.word,q.question,q.option_a,q.option_b,q.option_c,q.option_d,q.correct,q.explanation,coalesce(s.attempts,0)>0 exposed,coalesce(s.last_marked,false) starred
   from english.questions q left join english.question_state s on s.user_id=uid and s.question_id=q.question_id
   where english.is_genuine_bank_question(q) and english.learning_category(q.topic)=v_cat
 ), today_last as (
   select distinct on (a.question_id) a.question_id,a.correct answer_correct,a.selected_answer,a.attempted_at
   from english.attempts a join bank b on b.question_id=a.question_id
   where a.user_id=uid and lower(coalesce(a.module,''))='bankcoverage' and (a.attempted_at at time zone 'Asia/Kolkata')::date=v_today
   order by a.question_id,a.attempted_at desc,a.attempt_id desc
 ), today_items as (
   select b.*,t.answer_correct,t.selected_answer,t.attempted_at,coalesce(d.difficult,false) difficult
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
 ), today_json as (
   select jsonb_build_object(
     'attempted',count(*),'correct',count(*) filter(where answer_correct),'wrong',count(*) filter(where not answer_correct),'difficult',count(*) filter(where difficult),
     'items',coalesce(jsonb_agg(jsonb_build_object(
       'id',question_id,'word',coalesce(word,''),'question',coalesce(question,''),'correct',answer_correct,'starred',starred,'difficult',difficult,
       'selectedKey',coalesce(selected_answer,''),'selectedText',case upper(coalesce(selected_answer,'')) when 'A' then option_a when 'B' then option_b when 'C' then option_c when 'D' then option_d else '' end,
       'correctKey',coalesce(correct,''),'correctText',case upper(coalesce(correct,'')) when 'A' then option_a when 'B' then option_b when 'C' then option_c when 'D' then option_d else '' end,
       'explanation',coalesce(explanation,'')
     ) order by attempted_at desc),'[]'::jsonb)
   ) j from today_items
 )
 select jsonb_build_object(
   'id',v_cat,'total',(select count(*) from bank),'exposed',(select count(*) from bank where exposed),'left',(select count(*) from bank where not exposed),
   'coverage',case when (select count(*) from bank)>0 then round((select count(*) from bank where exposed)*100.0/(select count(*) from bank),1) else 0 end,
   'newToday',(select count(*) from today_items),'attemptedToday',(select count(*) from today_items),'todayCorrect',(select count(*) from today_items where answer_correct),
   'todayWrong',(select count(*) from today_items where not answer_correct),'todayDifficult',(select count(*) from today_items where difficult),
   'today',(select j from today_json),
   'lastSession',case when (select d from previous_day) is null then null else jsonb_build_object('date',(select d from previous_day),'attempted',(select count(*) from previous),'correct',(select count(*) from previous where correct),'wrong',(select count(*) from previous where not correct)) end
 ) into out;
 return out;
end $function$;
