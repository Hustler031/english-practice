create or replace function public.english_get_sprint_same_day_questions()
returns jsonb
language sql
stable
security definer
set search_path to 'pg_catalog','public','english','auth'
as $$
  with uid as (select auth.uid() id)
  select case
    when (select id from uid) is null then '[]'::jsonb
    else coalesce((
      select jsonb_agg(q.question order by q.question)
      from (
        select distinct i.question
        from english.sprint_sessions s
        join english.sprint_items i on i.session_id=s.session_id
        cross join uid
        where s.user_id=uid.id
          and s.status='completed'
          and s.completed_at>=(((now() at time zone 'Asia/Kolkata')::date)::timestamp at time zone 'Asia/Kolkata')
          and nullif(btrim(i.question),'') is not null
      ) q
    ),'[]'::jsonb)
  end;
$$;

revoke all on function public.english_get_sprint_same_day_questions() from public, anon;
grant execute on function public.english_get_sprint_same_day_questions() to authenticated;
