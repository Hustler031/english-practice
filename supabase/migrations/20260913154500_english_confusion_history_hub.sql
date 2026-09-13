-- Daily Confusion history / revision hub.
-- Keeps the canonical daily publisher untouched and adds read-only tracking + revision access.

create or replace function public.english_get_confusion_hub()
returns jsonb
language plpgsql
stable
security definer
set search_path = pg_catalog, public, english, auth
as $$
declare
  uid uuid := auth.uid();
  outv jsonb;
begin
  if uid is null then raise exception 'Authentication required'; end if;

  with dates as (
    select d.batch_date,
           dense_rank() over(order by d.batch_date)::int as day_no
    from (select distinct batch_date from english.daily_confusion_items where active) d
  ), items as (
    select d.day_no,i.batch_date,i.slot,i.question_id,i.category,
           exists(
             select 1 from english.attempts a
             where a.user_id=uid and a.question_id=i.question_id
               and lower(coalesce(a.module,''))='confusion'
               and (a.attempted_at at time zone 'Asia/Kolkata')::date=i.batch_date
           ) as completed_on_day,
           coalesce(qs.mastered,false) as mastered,
           coalesce(qs.status,'New') as status,
           coalesce(ds.difficult,false) as difficult,
           exists(
             select 1 from english.attempts a
             where a.user_id=uid and a.question_id=i.question_id
               and lower(coalesce(a.module,''))='confusion'
           ) as ever_revised
    from english.daily_confusion_items i
    join dates d on d.batch_date=i.batch_date
    left join english.question_state qs on qs.user_id=uid and qs.question_id=i.question_id
    left join english.difficult_state ds on ds.user_id=uid and ds.question_id=i.question_id
    where i.active
  ), hist as (
    select day_no,batch_date,
           count(*)::int published,
           count(*) filter(where completed_on_day)::int completed,
           count(*) filter(where not completed_on_day)::int pending,
           count(*) filter(where mastered)::int mastered,
           count(*) filter(where not mastered)::int focus,
           count(*) filter(where status in ('Persistent Weak','Weak','Fragile'))::int weak,
           count(*) filter(where difficult)::int difficult,
           count(*) filter(where not ever_revised)::int new_count
    from items
    group by day_no,batch_date
  ), cats as (
    select category,count(*)::int n from items group by category
  )
  select jsonb_build_object(
    'currentDay',coalesce((select max(day_no) from hist),0),
    'currentDate',(select max(batch_date) from hist),
    'stats',jsonb_build_object(
      'published',coalesce((select sum(published) from hist),0),
      'completed',coalesce((select sum(completed) from hist),0),
      'pending',coalesce((select sum(pending) from hist),0),
      'mastered',coalesce((select count(*) from items where mastered),0),
      'focus',coalesce((select count(*) from items where not mastered),0),
      'weak',coalesce((select count(*) from items where status in ('Persistent Weak','Weak','Fragile')),0),
      'difficult',coalesce((select count(*) from items where difficult),0),
      'new',coalesce((select count(*) from items where not ever_revised),0)
    ),
    'categoryCounts',coalesce((select jsonb_object_agg(category,n) from cats),'{}'::jsonb),
    'history',coalesce((
      select jsonb_agg(jsonb_build_object(
        'day',day_no,'date',batch_date,'label','Day '||day_no,
        'published',published,'completed',completed,'pending',pending,
        'mastered',mastered,'focus',focus,'weak',weak,'difficult',difficult,'new',new_count
      ) order by day_no desc)
      from hist
    ),'[]'::jsonb)
  ) into outv;

  return outv;
end;
$$;

create or replace function public.english_get_confusion_revision_batch(
  p_mode text default 'smart',
  p_count integer default 20,
  p_from_date date default null,
  p_to_date date default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path = pg_catalog, public, english, auth
as $$
declare
  uid uuid := auth.uid();
  v_mode text := lower(btrim(coalesce(p_mode,'smart')));
  v_count integer := least(500,greatest(1,coalesce(p_count,20)));
  outv jsonb;
begin
  if uid is null then raise exception 'Authentication required'; end if;
  if v_mode not in ('smart','all','new','weak','difficult','mastered','pending') then
    raise exception 'Unsupported Daily Confusion revision mode';
  end if;

  with dates as (
    select d.batch_date,dense_rank() over(order by d.batch_date)::int day_no
    from (select distinct batch_date from english.daily_confusion_items where active) d
  ), base as (
    select i.batch_date,d.day_no,i.slot,i.question_id,i.bank_id,i.category,i.pair_cluster,
           coalesce(qs.mastered,false) mastered,
           coalesce(qs.status,'New') status,
           coalesce(ds.difficult,false) difficult,
           exists(
             select 1 from english.attempts a
             where a.user_id=uid and a.question_id=i.question_id
               and lower(coalesce(a.module,''))='confusion'
               and (a.attempted_at at time zone 'Asia/Kolkata')::date=i.batch_date
           ) completed_on_day,
           (select count(*)::int from english.attempts a
             where a.user_id=uid and a.question_id=i.question_id
               and lower(coalesce(a.module,''))='confusion') confusion_attempts,
           (select max(a.attempted_at) from english.attempts a
             where a.user_id=uid and a.question_id=i.question_id
               and lower(coalesce(a.module,''))='confusion') last_confusion_attempt
    from english.daily_confusion_items i
    join dates d on d.batch_date=i.batch_date
    join english.questions q on q.question_id=i.question_id and q.active
    left join english.question_state qs on qs.user_id=uid and qs.question_id=i.question_id
    left join english.difficult_state ds on ds.user_id=uid and ds.question_id=i.question_id
    where i.active
      and (p_from_date is null or i.batch_date>=p_from_date)
      and (p_to_date is null or i.batch_date<=p_to_date)
  ), filtered as (
    select * from base
    where case v_mode
      when 'all' then true
      when 'new' then confusion_attempts=0
      when 'weak' then status in ('Persistent Weak','Weak','Fragile')
      when 'difficult' then difficult
      when 'mastered' then mastered
      when 'pending' then not completed_on_day
      else not mastered
    end
  ), ranked as (
    select f.*,
      case status when 'Persistent Weak' then 0 when 'Weak' then 1 when 'Fragile' then 2 else 3 end state_ord
    from filtered f
  ), chosen as (
    select * from ranked
    order by
      case when v_mode='smart' then state_ord else 0 end,
      case when v_mode='smart' and difficult then 0 else 1 end,
      case when v_mode='smart' and confusion_attempts=0 then 0 else 1 end,
      case when v_mode='smart' then last_confusion_attempt end nulls first,
      batch_date desc,slot
    limit v_count
  )
  select coalesce(jsonb_agg(
    english.question_payload(uid,c.question_id) || jsonb_build_object(
      'id',c.question_id,
      'category',c.category,
      'topic',c.category,
      'bankId',c.bank_id,
      'pairCluster',c.pair_cluster,
      'batchDate',c.batch_date,
      'dayNumber',c.day_no,
      'slot',c.slot,
      'confusionAttempts',c.confusion_attempts,
      'completedOnDay',c.completed_on_day,
      'selectionReason',case v_mode
        when 'smart' then 'Daily Confusion Smart Revision'
        when 'new' then 'Not yet revised in Daily Confusion'
        when 'weak' then 'Weak Daily Confusion concept'
        when 'difficult' then 'Marked Difficult'
        when 'mastered' then 'Mastered Daily Confusion item'
        when 'pending' then 'Original daily set pending'
        else 'Daily Confusion history'
      end
    ) order by
      case when v_mode='smart' then c.state_ord else 0 end,
      c.batch_date desc,c.slot
  ),'[]'::jsonb) into outv
  from chosen c;

  return outv;
end;
$$;

grant execute on function public.english_get_confusion_hub() to authenticated;
grant execute on function public.english_get_confusion_revision_batch(text,integer,date,date) to authenticated;
