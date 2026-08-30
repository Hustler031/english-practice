create or replace function public.maths_get_home_snapshot() returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public,maths as $$
declare uid uuid:=maths._require_uid(); day_ int:=maths._study_day(); daily maths.sessions%rowtype; target_ int; done_ int; resume_ jsonb; ids text[]; new_ids text[]; config jsonb;
begin
 config:=jsonb_build_object('dailyTarget',coalesce(nullif(maths._setting('daily_chapter_size','25'),'')::int,25),'newQuota',coalesce(nullif(maths._setting('daily_new_quota','7'),'')::int,7),'difficultRotationDays',coalesce(nullif(maths._setting('difficult_rotation_days','3'),'')::int,3),'practiceMoreSize',coalesce(nullif(maths._setting('practice_more_size','20'),'')::int,20),'timezone',maths._setting('study_timezone','Asia/Kolkata'));
 select * into daily from maths.sessions s where s.user_id=uid and lower(coalesce(s.mode,''))='daily' and coalesce(nullif(s.params->>'planDay','')::int,0)=day_ order by s.completed desc,s.updated_at desc nulls last limit 1;
 if daily.session_id is null then target_:=(config->>'dailyTarget')::int; else select count(*) into target_ from maths.session_questions where session_id=daily.session_id; end if;
 done_:=case when daily.session_id is null then 0 else (select count(distinct a.question_id) from maths.attempts a where a.user_id=uid and a.session_id=daily.session_id) end;
 select jsonb_build_object('sessionId',s.session_id,'title',s.title,'mode',s.mode,'currentIndex',s.current_index,'target',(select count(*) from maths.session_questions sq where sq.session_id=s.session_id)) into resume_ from maths.sessions s where s.user_id=uid and not s.completed order by s.updated_at desc nulls last limit 1;
 select coalesce(array_agg(r.question_id),array[]::text[]) into ids from maths._user_runtime(uid) r where r.academic_eligible;
 new_ids:=maths._new_ids(uid,ids);
 return jsonb_build_object('ok',true,'studyDay',day_,'config',config,'daily',jsonb_build_object('target',target_,'done',least(done_,target_),'remaining',greatest(0,target_-done_),'completed',coalesce(daily.completed,false),'sessionId',coalesce(daily.session_id,''),'composition',coalesce(daily.params->'dailyComposition','null'::jsonb)),'resume',resume_,'overall',maths._metric(uid,ids),'counts',jsonb_build_object('new',coalesce(array_length(new_ids,1),0),'starred',(select count(*) from maths._user_runtime(uid) r where r.academic_eligible and r.starred and not r.mastered),'concepts',(select count(*) from maths.concept_membership c where c.user_id=uid and c.active),'mocks',(select count(*) from maths.practice_set_items where set_id='MOCK_QUESTIONS'),'formulas',(select count(*) from maths.practice_set_items where set_id='MOCK_FORMULA_REVISION'),'calculation',(select count(*) from maths._user_runtime(uid) r where r.runtime_active and (r.bank_calculation or r.in_calc_set))));
end $$;
revoke all on function maths._new_ids(uuid,text[]) from public,anon,authenticated;
revoke all on function maths._formula_metric(uuid,text[]) from public,anon,authenticated;


