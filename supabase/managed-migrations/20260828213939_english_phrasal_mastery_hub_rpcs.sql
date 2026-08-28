create or replace function public.english_get_phrasal_today()
returns jsonb language sql stable security definer set search_path='pg_catalog','public','english','auth' as $$
select case when auth.uid() is null then '[]'::jsonb else coalesce(jsonb_agg(english.question_payload(auth.uid(),q.question_id) || jsonb_build_object('phrasalQuestionFamily',english.phrasal_question_family(q),'phrasalConceptId',coalesce(nullif(btrim(q.concept_id),''),'PVQ_'||q.question_id)) order by q.question_id),'[]'::jsonb) end
from english.questions q left join english.question_state s on s.user_id=auth.uid() and s.question_id=q.question_id
where q.active and not coalesce(s.mastered,false) and q.source_id='PHRASAL_DAILY_'||to_char((now() at time zone 'Asia/Kolkata')::date,'YYYYMMDD')
  and (english.canonical_category(q.topic)='PHRASAL' or lower(btrim(coalesce(q.topic,'')))='phrasal verb');
$$;

create or replace function public.english_get_phrasal_history_batch(p_from_day integer,p_to_day integer)
returns jsonb language plpgsql stable security definer set search_path='pg_catalog','public','english','auth' as $$
declare uid uuid:=auth.uid();lo integer:=greatest(1,coalesce(p_from_day,1));hi integer:=greatest(greatest(1,coalesce(p_from_day,1)),coalesce(p_to_day,p_from_day,1));out jsonb;
begin
 if uid is null then raise exception 'Authentication required'; end if;
 with dated as (
   select q.*,to_date(substring(q.source_id from 'PHRASAL_DAILY_([0-9]{8})'),'YYYYMMDD') d
   from english.questions q where q.active and q.source_id ~ '^PHRASAL_DAILY_[0-9]{8}$' and (english.canonical_category(q.topic)='PHRASAL' or lower(btrim(coalesce(q.topic,'')))='phrasal verb')
 ), days as (select d,row_number() over(order by d)::int day_no from (select distinct d from dated) x), picked as (
   select distinct on(q.question_id) q.question_id,ds.day_no from dated q join days ds using(d) left join english.question_state s on s.user_id=uid and s.question_id=q.question_id where ds.day_no between lo and hi and not coalesce(s.mastered,false) order by q.question_id,ds.day_no
 ) select coalesce(jsonb_agg(english.question_payload(uid,p.question_id) order by p.day_no,p.question_id),'[]'::jsonb) into out from picked p;
 return out;
end;
$$;

create or replace function public.english_get_phrasal_hub()
returns jsonb language plpgsql volatile security definer set search_path='pg_catalog','public','english','auth' as $$
declare uid uuid:=auth.uid();out jsonb;v_total int;v_exposed int;v_due int;v_weak int;v_recall_weak int;v_diff int;v_star int;v_mastered int;v_fresh int;v_eligible int;v_today int;v_history jsonb;v_current_day int;v_current_block_start int;v_current_month int;v_current_month_start int;
begin
 if uid is null then raise exception 'Authentication required'; end if;
 select count(*),count(*) filter(where attempts>0),count(*) filter(where active_variant_count>0 and (not proven_mastery or fresh_variant_count>0) and due),count(*) filter(where active_variant_count>0 and (not proven_mastery or fresh_variant_count>0) and (state in ('Persistent Weak','Weak','Fragile') or recall_weak)),count(*) filter(where active_variant_count>0 and (not proven_mastery or fresh_variant_count>0) and recall_weak),count(*) filter(where active_variant_count>0 and (not proven_mastery or fresh_variant_count>0) and difficult),count(*) filter(where active_variant_count>0 and (not proven_mastery or fresh_variant_count>0) and starred),count(*) filter(where proven_mastery),count(*) filter(where active_variant_count>0 and proven_mastery and fresh_variant_count>0),count(*) filter(where active_variant_count>0 and (not proven_mastery or fresh_variant_count>0))
 into v_total,v_exposed,v_due,v_weak,v_recall_weak,v_diff,v_star,v_mastered,v_fresh,v_eligible from english.phrasal_concepts(uid);
 select count(*) into v_today from english.questions q where q.active and q.source_id='PHRASAL_DAILY_'||to_char((now() at time zone 'Asia/Kolkata')::date,'YYYYMMDD') and (english.canonical_category(q.topic)='PHRASAL' or lower(btrim(coalesce(q.topic,'')))='phrasal verb');

 create temporary table if not exists pg_temp.phrasal_days(day_no int,d date,generated int,practised int) on commit drop;
 truncate pg_temp.phrasal_days;
 insert into pg_temp.phrasal_days
 with dated as (
   select q.question_id,to_date(substring(q.source_id from 'PHRASAL_DAILY_([0-9]{8})'),'YYYYMMDD') d
   from english.questions q where q.active and q.source_id ~ '^PHRASAL_DAILY_[0-9]{8}$' and (english.canonical_category(q.topic)='PHRASAL' or lower(btrim(coalesce(q.topic,'')))='phrasal verb')
 ), dates as (select distinct d from dated), numbered as (select d,row_number() over(order by d)::int day_no from dates)
 select n.day_no,n.d,count(d.question_id)::int,count(d.question_id) filter(where exists(select 1 from english.attempts a where a.user_id=uid and a.question_id=d.question_id and lower(coalesce(a.module,'')) in ('phrasaldaily','phrasalrevision')))::int
 from numbered n join dated d using(d) group by n.day_no,n.d order by n.day_no;
 select coalesce(max(day_no),0) into v_current_day from pg_temp.phrasal_days;
 if v_current_day=0 then v_history:='[]'::jsonb; else
   v_current_block_start:=((v_current_day-1)/10)*10+1;
   v_current_month:=((v_current_day-1)/30)+1;
   v_current_month_start:=(v_current_month-1)*30+1;
   with day_entries as (
     select 1 grp,-day_no sk,jsonb_build_object('type','day','label',case when d=(now() at time zone 'Asia/Kolkata')::date then 'Today' else 'Day '||day_no end,'fromDay',day_no,'toDay',day_no,'generated',generated,'practised',practised,'date',d) j
     from pg_temp.phrasal_days where day_no between v_current_block_start and v_current_day
   ), block_starts as (
     select generate_series(v_current_block_start-10,v_current_month_start,-10)::int start_day
     where v_current_block_start-10>=v_current_month_start
   ), block_entries as (
     select 2 grp,-b.start_day sk,jsonb_build_object('type','block','label','Days '||b.start_day||'–'||least(b.start_day+9,v_current_day),'fromDay',b.start_day,'toDay',least(b.start_day+9,v_current_day),'generated',sum(d.generated),'practised',sum(d.practised)) j
     from block_starts b join pg_temp.phrasal_days d on d.day_no between b.start_day and least(b.start_day+9,v_current_day) group by b.start_day
   ), months as (
     select generate_series(v_current_month-1,1,-1)::int mon where v_current_month>1
   ), month_entries as (
     select 3 grp,-m.mon sk,jsonb_build_object('type','month','label','Month '||m.mon,'fromDay',(m.mon-1)*30+1,'toDay',m.mon*30,'generated',sum(d.generated),'practised',sum(d.practised)) j
     from months m join pg_temp.phrasal_days d on d.day_no between (m.mon-1)*30+1 and m.mon*30 group by m.mon
   ), all_e as (select * from day_entries union all select * from block_entries union all select * from month_entries)
   select coalesce(jsonb_agg(j order by grp,sk),'[]'::jsonb) into v_history from all_e;
 end if;
 out:=jsonb_build_object('version','V1.3','generatedAt',now(),'dailyTarget',20,
   'stats',jsonb_build_object('totalConcepts',v_total,'exposed',v_exposed,'exposurePercent',case when v_total>0 then round(v_exposed*1000.0/v_total)/10 else 0 end,'due',v_due,'weak',v_weak,'recallWeak',v_recall_weak,'difficult',v_diff,'starred',v_star,'mastered',v_mastered,'freshVariantChecks',v_fresh,'eligible',v_eligible),
   'today',jsonb_build_object('date',(now() at time zone 'Asia/Kolkata')::date,'count',v_today,'target',20,'ready',v_today>0,'sourceId','PHRASAL_DAILY_'||to_char((now() at time zone 'Asia/Kolkata')::date,'YYYYMMDD')),
   'available',jsonb_build_object('smart',v_eligible,'weak',v_weak,'difficult',v_diff,'starred',v_star,'random',v_eligible,'all',v_eligible),'sizes',jsonb_build_array(10,20,30,50),'history',v_history);
 return out;
end;
$$;

create or replace function public.english_get_phrasal_audit()
returns jsonb language plpgsql stable security definer set search_path='pg_catalog','public','english','auth' as $$
declare uid uuid:=auth.uid();out jsonb;
begin
 if uid is null then raise exception 'Authentication required'; end if;
 with qs as (select q.*,coalesce(nullif(btrim(q.concept_id),''),'PVQ_'||q.question_id) ckey from english.questions q where q.active and (english.canonical_category(q.topic)='PHRASAL' or lower(btrim(coalesce(q.topic,'')))='phrasal verb')),
 today as (select ckey,count(*) n from qs where source_id='PHRASAL_DAILY_'||to_char((now() at time zone 'Asia/Kolkata')::date,'YYYYMMDD') group by ckey having count(*)>1),
 c as (select * from english.phrasal_concepts(uid))
 select jsonb_build_object('ok',not exists(select 1 from today),'questions',(select count(*) from qs),'concepts',(select count(*) from c),'todayCount',(select count(*) from qs where source_id='PHRASAL_DAILY_'||to_char((now() at time zone 'Asia/Kolkata')::date,'YYYYMMDD')),'todayDuplicateConcepts',coalesce((select jsonb_agg(ckey) from today),'[]'::jsonb),'stats',jsonb_build_object('eligible',(select count(*) from c where active_variant_count>0 and (not proven_mastery or fresh_variant_count>0)),'recallWeak',(select count(*) from c where recall_weak),'recognitionStrongRecallWeak',(select count(*) from c where recall_weak and recognition_strong),'recallConfused',(select coalesce(sum(recall_confused),0) from c),'recallForgotten',(select coalesce(sum(recall_forgotten),0) from c))) into out;
 return out;
end;
$$;

revoke all on function public.english_get_phrasal_today() from public,anon;
revoke all on function public.english_get_phrasal_history_batch(integer,integer) from public,anon;
revoke all on function public.english_get_phrasal_hub() from public,anon;
revoke all on function public.english_get_phrasal_audit() from public,anon;
grant execute on function public.english_get_phrasal_today() to authenticated;
grant execute on function public.english_get_phrasal_history_batch(integer,integer) to authenticated;
grant execute on function public.english_get_phrasal_hub() to authenticated;
grant execute on function public.english_get_phrasal_audit() to authenticated;
