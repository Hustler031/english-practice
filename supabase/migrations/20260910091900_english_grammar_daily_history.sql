-- ENGLISH V2 — Grammar Daily history grouped like Phrasal Daily history
-- Current 10-day block is shown day-by-day; older blocks collapse to Days N–N+9,
-- and completed 30-day periods collapse to Month N. Historical revision never
-- changes Grammar Daily completion/carry-forward state.

create or replace function public.english_get_grammar_history()
returns jsonb
language plpgsql
stable
security definer
set search_path to 'pg_catalog','public','english','auth'
as $function$
declare
  uid uuid:=auth.uid();
  v_today date:=(now() at time zone 'Asia/Kolkata')::date;
  v_current_day integer:=0;
  v_current_block_start integer:=0;
  v_current_month integer:=0;
  v_current_month_start integer:=0;
  v_history jsonb:='[]'::jsonb;
begin
  if uid is null then raise exception 'Authentication required'; end if;

  with dates as (
    select distinct batch_date
    from english.grammar_daily_items
    where batch_date<=v_today
  ), days as (
    select row_number() over(order by d.batch_date)::int day_no,d.batch_date
    from dates d
  )
  select coalesce(max(day_no),0) into v_current_day from days;

  if v_current_day=0 then
    return jsonb_build_object('ok',true,'currentDay',0,'history','[]'::jsonb);
  end if;

  v_current_block_start:=((v_current_day-1)/10)*10+1;
  v_current_month:=((v_current_day-1)/30)+1;
  v_current_month_start:=(v_current_month-1)*30+1;

  with dates as (
    select distinct batch_date
    from english.grammar_daily_items
    where batch_date<=v_today
  ), numbered as (
    select row_number() over(order by d.batch_date)::int day_no,d.batch_date
    from dates d
  ), days as (
    select
      n.day_no,
      n.batch_date,
      p.total generated,
      p.practiced practised,
      p.correct,
      p.wrong,
      p.round2_focus
    from numbered n
    cross join lateral english.grammar_daily_progress(uid,n.batch_date) p
  ), day_entries as (
    select
      1 grp,
      -day_no sk,
      jsonb_build_object(
        'type','day',
        'label','Day '||day_no,
        'fromDay',day_no,
        'toDay',day_no,
        'generated',generated,
        'practised',practised,
        'correct',correct,
        'wrong',wrong,
        'round2Focus',round2_focus,
        'complete',(generated>0 and practised=generated),
        'date',batch_date,
        'isToday',(batch_date=v_today)
      ) j
    from days
    where day_no between v_current_block_start and v_current_day
  ), block_starts as (
    select generate_series(v_current_block_start-10,v_current_month_start,-10)::int start_day
    where v_current_block_start-10>=v_current_month_start
  ), block_entries as (
    select
      2 grp,
      -b.start_day sk,
      jsonb_build_object(
        'type','block',
        'label','Days '||b.start_day||'–'||least(b.start_day+9,v_current_day),
        'fromDay',b.start_day,
        'toDay',least(b.start_day+9,v_current_day),
        'generated',sum(d.generated)::int,
        'practised',sum(d.practised)::int,
        'correct',sum(d.correct)::int,
        'wrong',sum(d.wrong)::int,
        'round2Focus',sum(d.round2_focus)::int,
        'complete',bool_and(d.generated>0 and d.practised=d.generated)
      ) j
    from block_starts b
    join days d on d.day_no between b.start_day and least(b.start_day+9,v_current_day)
    group by b.start_day
  ), months as (
    select generate_series(v_current_month-1,1,-1)::int mon
    where v_current_month>1
  ), month_entries as (
    select
      3 grp,
      -m.mon sk,
      jsonb_build_object(
        'type','month',
        'label','Month '||m.mon,
        'fromDay',(m.mon-1)*30+1,
        'toDay',m.mon*30,
        'generated',sum(d.generated)::int,
        'practised',sum(d.practised)::int,
        'correct',sum(d.correct)::int,
        'wrong',sum(d.wrong)::int,
        'round2Focus',sum(d.round2_focus)::int,
        'complete',bool_and(d.generated>0 and d.practised=d.generated)
      ) j
    from months m
    join days d on d.day_no between (m.mon-1)*30+1 and m.mon*30
    group by m.mon
  ), all_entries as (
    select * from day_entries
    union all select * from block_entries
    union all select * from month_entries
  )
  select coalesce(jsonb_agg(j order by grp,sk),'[]'::jsonb)
  into v_history
  from all_entries;

  return jsonb_build_object(
    'ok',true,
    'currentDay',v_current_day,
    'currentBlockStart',v_current_block_start,
    'history',v_history
  );
end
$function$;

create or replace function public.english_get_grammar_history_batch(
  p_from_day integer,
  p_to_day integer
)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'pg_catalog','public','english','auth'
as $function$
declare
  uid uuid:=auth.uid();
  v_today date:=(now() at time zone 'Asia/Kolkata')::date;
  lo integer:=greatest(1,coalesce(p_from_day,1));
  hi integer:=greatest(greatest(1,coalesce(p_from_day,1)),coalesce(p_to_day,p_from_day,1));
  out jsonb:='[]'::jsonb;
begin
  if uid is null then raise exception 'Authentication required'; end if;

  with dates as (
    select distinct batch_date
    from english.grammar_daily_items
    where batch_date<=v_today
  ), numbered as (
    select row_number() over(order by d.batch_date)::int day_no,d.batch_date
    from dates d
  ), picked as (
    select
      i.question_id,
      i.slot_no,
      i.rule_key,
      i.question_family,
      i.is_new_variant,
      n.day_no,
      n.batch_date,
      row_number() over(
        partition by i.question_id
        order by n.day_no desc,i.slot_no
      ) duplicate_rank
    from english.grammar_daily_items i
    join numbered n on n.batch_date=i.batch_date
    join english.questions q on q.question_id=i.question_id and q.active
    where n.day_no between lo and hi
  )
  select coalesce(jsonb_agg(
    english.grammar_question_payload(uid,p.question_id)
      || jsonb_build_object(
        'historyDay',p.day_no,
        'batchDate',p.batch_date,
        'slotNo',p.slot_no,
        'ruleKey',p.rule_key,
        'questionFamily',p.question_family,
        'isNewVariant',p.is_new_variant
      )
    order by p.day_no,p.slot_no
  ),'[]'::jsonb)
  into out
  from picked p
  where p.duplicate_rank=1;

  return out;
end
$function$;

grant execute on function public.english_get_grammar_history() to authenticated;
grant execute on function public.english_get_grammar_history_batch(integer,integer) to authenticated;
