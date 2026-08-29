create or replace function public.english_get_starred_rotation_stats(p_from_day integer default null, p_to_day integer default null)
returns jsonb
language sql
stable
security definer
set search_path to 'pg_catalog','public','english','auth'
as $function$
with c as (
  select * from english.starred_revision_candidates(auth.uid())
  where (p_from_day is null or origin_day>=p_from_day)
    and (p_to_day is null or origin_day<=p_to_day)
)
select jsonb_build_object(
  'weakExact',count(*) filter(where state='Weak')::int,
  'learningExact',count(*) filter(where state='Learning')::int,
  'newCount',count(*) filter(where state='New')::int,
  'days7Plus',count(*) filter(where not never_revised and coalesce(days_since_revision,0)>=7)::int,
  'days14Plus',count(*) filter(where not never_revised and coalesce(days_since_revision,0)>=14)::int,
  'recent24h',count(*) filter(where last_revision is not null and now()-last_revision>=interval '0 seconds' and now()-last_revision<interval '24 hours')::int
) from c;
$function$;
grant execute on function public.english_get_starred_rotation_stats(integer,integer) to authenticated;
