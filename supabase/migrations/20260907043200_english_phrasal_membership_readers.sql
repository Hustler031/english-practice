create or replace function public.english_get_phrasal_today()
returns jsonb language sql stable security definer
set search_path to 'pg_catalog','public','english','auth'
as $function$
select case when auth.uid() is null then '[]'::jsonb else coalesce(jsonb_agg(
  english.question_payload(auth.uid(),q.question_id)||jsonb_build_object('phrasalQuestionFamily',d.question_family,'phrasalConceptId',d.concept_id)
  order by d.slot_no
),'[]'::jsonb) end
from english.phrasal_daily_items d
join english.questions q on q.question_id=d.question_id and q.active
left join english.question_state s on s.user_id=auth.uid() and s.question_id=q.question_id
where d.batch_date=(now() at time zone 'Asia/Kolkata')::date
  and not coalesce(s.mastered,false);
$function$;

create or replace function public.english_get_phrasal_history_batch(p_from_day integer,p_to_day integer)
returns jsonb language plpgsql stable security definer
set search_path to 'pg_catalog','public','english','auth'
as $function$
declare uid uuid:=auth.uid();lo integer:=greatest(1,coalesce(p_from_day,1));hi integer:=greatest(greatest(1,coalesce(p_from_day,1)),coalesce(p_to_day,p_from_day,1));out jsonb;
begin
  if uid is null then raise exception 'Authentication required'; end if;
  with days as (
    select batch_date,row_number() over(order by batch_date)::int day_no
    from (select distinct batch_date from english.phrasal_daily_items) x
  ), picked as (
    select d.batch_date,d.slot_no,d.question_id,ds.day_no
    from english.phrasal_daily_items d
    join days ds using(batch_date)
    left join english.question_state s on s.user_id=uid and s.question_id=d.question_id
    where ds.day_no between lo and hi and not coalesce(s.mastered,false)
  )
  select coalesce(jsonb_agg(english.question_payload(uid,p.question_id) order by p.day_no,p.slot_no),'[]'::jsonb)
  into out
  from picked p join english.questions q on q.question_id=p.question_id and q.active;
  return out;
end;
$function$;

create or replace function public.english_get_phrasal_hub()
returns jsonb language plpgsql security definer
set search_path to 'pg_catalog','public','english','auth'
as $function$
declare
  uid uuid:=auth.uid();out jsonb;
  v_total int;v_exposed int;v_due int;v_weak int;v_recall_weak int;v_diff int;v_star int;
  v_mastered int;v_fresh int;v_eligible int;v_today int;v_history jsonb;
  v_current_day int;v_current_block_start int;v_current_month int;v_current_month_start int;
begin
  if uid is null then raise exception 'Authentication required'; end if;
  select count(*),count(*) filter(where attempts>0),
         count(*) filter(where active_variant_count>0 and (not proven_mastery or fresh_variant_count>0) and due),
         count(*) filter(where active_variant_count>0 and (not proven_mastery or fresh_variant_count>0) and (state in ('Persistent Weak','Weak','Fragile') or recall_weak)),
         count(*) filter(where active_variant_count>0 and (not proven_mastery or fresh_variant_count>0) and recall_weak),
         count(*) filter(where active_variant_count>0 and (not proven_mastery or fresh_variant_count>0) and difficult),
         count(*) filter(where active_variant_count>0 and (not proven_mastery or fresh_variant_count>0) and starred),
         count(*) filter(where proven_mastery),
         count(*) filter(where active_variant_count>0 and proven_mastery and fresh_variant_count>0),
         count(*) filter(where active_variant_count>0 and (not proven_mastery or fresh_variant_count>0))
  into v_total,v_exposed,v_due,v_weak,v_recall_weak,v_diff,v_star,v_mastered,v_fresh,v_eligible
  from english.phrasal_concepts(uid);

  select count(*) into v_today
  from english.phrasal_daily_items d
  join english.questions q on q.question_id=d.question_id and q.active
  where d.batch_date=(now() at time zone 'Asia/Kolkata')::date;

  create temporary table if not exists pg_temp.phrasal_days(day_no int,d date,generated int,practised int) on commit drop;
  truncate pg_temp.phrasal_days;
  insert into pg_temp.phrasal_days
  with dates as (select distinct batch_date d from english.phrasal_daily_items),
       numbered as (select d,row_number() over(order by d)::int day_no from dates)
  select n.day_no,n.d,count(i.question_id)::int,
         count(i.question_id) filter(where exists(
           select 1 from english.attempts a
           where a.user_id=uid and a.question_id=i.question_id
             and lower(coalesce(a.module,'')) in ('phrasaldaily','phrasalrevision')
             and (a.attempted_at at time zone 'Asia/Kolkata')::date=n.d
         ))::int
  from numbered n join english.phrasal_daily_items i on i.batch_date=n.d
  group by n.day_no,n.d order by n.day_no;

  select coalesce(max(day_no),0) into v_current_day from pg_temp.phrasal_days;
  if v_current_day=0 then v_history:='[]'::jsonb;
  else
    v_current_block_start:=((v_current_day-1)/10)*10+1;
    v_current_month:=((v_current_day-1)/30)+1;
    v_current_month_start:=(v_current_month-1)*30+1;
    with day_entries as (
      select 1 grp,-day_no sk,jsonb_build_object('type','day','label',case when d=(now() at time zone 'Asia/Kolkata')::date then 'Today' else 'Day '||day_no end,'fromDay',day_no,'toDay',day_no,'generated',generated,'practised',practised,'date',d) j
      from pg_temp.phrasal_days where day_no between v_current_block_start and v_current_day
    ), block_starts as (
      select generate_series(v_current_block_start-10,v_current_month_start,-10)::int start_day where v_current_block_start-10>=v_current_month_start
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

  out:=jsonb_build_object('version','V1.4','generatedAt',now(),'dailyTarget',20,
    'stats',jsonb_build_object('totalConcepts',v_total,'exposed',v_exposed,'exposurePercent',case when v_total>0 then round(v_exposed*1000.0/v_total)/10 else 0 end,'due',v_due,'weak',v_weak,'recallWeak',v_recall_weak,'difficult',v_diff,'starred',v_star,'mastered',v_mastered,'freshVariantChecks',v_fresh,'eligible',v_eligible),
    'today',jsonb_build_object('date',(now() at time zone 'Asia/Kolkata')::date,'count',v_today,'target',20,'ready',v_today>0,'sourceId','PHRASAL_DAILY_'||to_char((now() at time zone 'Asia/Kolkata')::date,'YYYYMMDD')),
    'available',jsonb_build_object('smart',v_eligible,'weak',v_weak,'difficult',v_diff,'starred',v_star,'random',v_eligible,'all',v_eligible),'sizes',jsonb_build_array(10,20,30,50),'history',v_history);
  return out;
end;
$function$;

create or replace function public.english_get_home_snapshot()
returns jsonb language sql stable security definer
set search_path to 'pg_catalog','public','english','auth'
as $function$
with uid as(select auth.uid() id),
summary as(select public.english_dashboard_summary() value),
saved as(select count(*) filter(where not mastered)::int eligible,count(*) filter(where not mastered and due)::int due from uid cross join lateral english.saved_revision_candidates(uid.id)),
starred as(select count(*) filter(where starred and not mastered)::int focus,count(*) filter(where difficult and starred and not mastered)::int difficult from uid cross join lateral english.starred_manual_index(uid.id)),
bank as(select count(*)::int total,count(*) filter(where coalesce(s.attempts,0)>0)::int exposed from uid join english.questions q on uid.id is not null and english.is_genuine_bank_question(q) left join english.question_state s on s.user_id=uid.id and s.question_id=q.question_id),
phrasal as(select count(*)::int today_count from uid join english.phrasal_daily_items d on uid.id is not null and d.batch_date=(now() at time zone 'Asia/Kolkata')::date join english.questions q on q.question_id=d.question_id and q.active and english.question_visible_to_user(uid.id,q.question_id)),
hindu as(select coalesce(jsonb_agg(jsonb_build_object('id',h.hindu_id) order by h.hindu_id),'[]'::jsonb) rows from uid join english.hindu_words h on uid.id is not null and h.active and h.word_date=(now() at time zone 'Asia/Kolkata')::date),
targeted as(select count(*)::int active,count(*) filter(where coalesce(ce.next_review,now())<=now())::int due_now from uid join english.learning_route_state r on r.user_id=uid.id and r.route='targeted' left join english.question_concept_mappings m on m.question_id=r.question_id left join english.concept_evidence ce on ce.user_id=uid.id and ce.concept_id=m.concept_id)
select case when uid.id is null then jsonb_build_object('ok',false,'error','Authentication required') else jsonb_build_object(
  'ok',true,'studyDay',greatest(1,((now() at time zone 'Asia/Kolkata')::date-date '2026-08-14')+1),'summary',summary.value,
  'intelligence',jsonb_build_object('daily',jsonb_build_object('actionableRemaining',coalesce((summary.value->>'daily_remaining')::int,0),'suppressed',coalesce((summary.value->>'daily_suppressed')::int,0)),'coreCoverage',jsonb_build_object('percent',case when bank.total>0 then round(bank.exposed*100.0/bank.total,1) else 0 end)),
  'phrasal',jsonb_build_object('today',jsonb_build_object('ready',phrasal.today_count>0,'count',phrasal.today_count),'stats',jsonb_build_object('due',0)),
  'bank',jsonb_build_object('total',bank.total,'exposed',bank.exposed,'coverage',case when bank.total>0 then round(bank.exposed*100.0/bank.total,1) else 0 end),
  'targeted',jsonb_build_object('active',targeted.active,'due',targeted.due_now),'saved',jsonb_build_object('stats',jsonb_build_object('saved',saved.eligible,'eligible',saved.eligible,'due',saved.due)),
  'starred',jsonb_build_object('stats',jsonb_build_object('focus',starred.focus,'manualDifficult',starred.difficult,'difficult',starred.difficult)),'hindu',hindu.rows
) end from uid cross join summary cross join saved cross join starred cross join bank cross join phrasal cross join hindu cross join targeted;
$function$;

create or replace function public.english_get_phrasal_audit()
returns jsonb language plpgsql stable security definer
set search_path to 'pg_catalog','public','english','auth'
as $function$
declare uid uuid:=auth.uid();out jsonb;
begin
 if uid is null then raise exception 'Authentication required'; end if;
 with qs as (select q.*,coalesce(nullif(btrim(q.concept_id),''),'PVQ_'||q.question_id) ckey from english.questions q where q.active and english.question_visible_to_user(auth.uid(),q.question_id) and (english.canonical_category(q.topic)='PHRASAL' or lower(btrim(coalesce(q.topic,'')))='phrasal verb')),
 today as (select concept_id,count(*) n from english.phrasal_daily_items where batch_date=(now() at time zone 'Asia/Kolkata')::date group by concept_id having count(*)>1),
 c as (select * from english.phrasal_concepts(uid))
 select jsonb_build_object('ok',not exists(select 1 from today),'questions',(select count(*) from qs),'concepts',(select count(*) from c),'todayCount',(select count(*) from english.phrasal_daily_items where batch_date=(now() at time zone 'Asia/Kolkata')::date),'todayDuplicateConcepts',coalesce((select jsonb_agg(concept_id) from today),'[]'::jsonb),'stats',jsonb_build_object('eligible',(select count(*) from c where active_variant_count>0 and (not proven_mastery or fresh_variant_count>0)),'recallWeak',(select count(*) from c where recall_weak),'recognitionStrongRecallWeak',(select count(*) from c where recall_weak and recognition_strong),'recallConfused',(select coalesce(sum(recall_confused),0) from c),'recallForgotten',(select coalesce(sum(recall_forgotten),0) from c))) into out;
 return out;
end;
$function$;

create or replace function public.english_get_phrasal_sense_evidence(p_concept_id text default null::text)
returns jsonb language plpgsql stable security definer
set search_path to 'pg_catalog','public','english','auth'
as $function$
declare uid uuid:=auth.uid();result jsonb;
begin
 if uid is null then raise exception 'Authentication required'; end if;
 select coalesce(jsonb_agg(jsonb_build_object('conceptId',e.concept_id,'senseKey',e.sense_key,'senseGloss',coalesce(s.gloss,''),'questionFamily',e.question_family,'attempts',e.attempts,'correct',e.correct_count,'accuracy',case when e.attempts>0 then round((e.correct_count::numeric/e.attempts::numeric)*100,1) else null end,'distinctVariants',e.distinct_variants,'lastAttempt',e.last_attempt) order by e.last_attempt desc nulls last,e.concept_id,e.sense_key,e.question_family),'[]'::jsonb)
 into result
 from (select v.concept_id,coalesce(nullif(v.sense_key,''),'legacy_default') sense_key,v.question_family,count(a.*)::int attempts,count(a.*) filter(where a.correct)::int correct_count,count(distinct v.question_id)::int distinct_variants,max(a.attempted_at) last_attempt from english.phrasal_question_variants v join english.questions q on q.question_id=v.question_id and q.active join english.attempts a on a.question_id=v.question_id and a.user_id=uid where p_concept_id is null or v.concept_id=p_concept_id group by v.concept_id,coalesce(nullif(v.sense_key,''),'legacy_default'),v.question_family) e
 left join english.phrasal_concept_senses s on s.concept_id=e.concept_id and s.sense_key=e.sense_key;
 return coalesce(result,'[]'::jsonb);
end;
$function$;
