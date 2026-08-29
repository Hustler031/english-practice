create or replace function public.english_get_daily_current()
returns jsonb
language sql
stable
security definer
set search_path=pg_catalog,public,english,auth
as $$
with ctx as (
  select auth.uid() uid,(now() at time zone 'Asia/Kolkata')::date today
), batch as (
  select min(d.quiz_date) batch_date
  from english.daily_current d cross join ctx
  where d.user_id=ctx.uid
), items as (
  select x.*
  from ctx cross join batch
  cross join lateral english.current_daily_items(ctx.uid) x
  where batch.batch_date is not null and x.quiz_date=batch.batch_date
)
select case
  when ctx.uid is null then jsonb_build_object('ok',false,'error','Authentication required')
  else jsonb_build_object(
    'ok',true,
    'batch_date',coalesce(batch.batch_date,ctx.today),
    'today',ctx.today,
    'pending_previous_day',coalesce(batch.batch_date<ctx.today,false),
    'created',0,
    'archived',0,
    'target_is_maximum',true,
    'total',(select count(*) from items),
    'completed',(select count(*) from items where lower(coalesce(status,''))='completed'),
    'remaining',(select count(*) from items where lower(coalesce(status,''))<>'completed'),
    'items',coalesce((
      select jsonb_agg(to_jsonb(i) order by i.sequence)
      from items i
      where lower(coalesce(i.status,''))<>'completed'
    ),'[]'::jsonb)
  )
end
from ctx cross join batch;
$$;

revoke all on function public.english_get_daily_current() from public,anon;
grant execute on function public.english_get_daily_current() to authenticated,service_role;
