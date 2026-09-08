-- Cache the expensive learning-progress aggregation in three fixed Asia/Kolkata
-- buckets per day. The public RPC contract remains unchanged.
--
-- Rationale: the underlying aggregate scans/joins the full English learning
-- universe and attempts history. It is a dashboard/progress read, not a quiz
-- correctness dependency, so recomputing it on every client revalidation is
-- unnecessary and can exhaust small-instance Disk IO burst budget.

alter function public.english_get_learning_progress()
  rename to english_get_learning_progress_uncached;

revoke all on function public.english_get_learning_progress_uncached() from public;
revoke all on function public.english_get_learning_progress_uncached() from anon;
revoke all on function public.english_get_learning_progress_uncached() from authenticated;
grant execute on function public.english_get_learning_progress_uncached() to service_role;

create table if not exists english.learning_progress_cache (
  user_id uuid primary key,
  bucket_date date not null,
  bucket_no smallint not null check (bucket_no between 0 and 2),
  payload jsonb not null,
  computed_at timestamptz not null default now()
);

alter table english.learning_progress_cache enable row level security;
revoke all on table english.learning_progress_cache from public;
revoke all on table english.learning_progress_cache from anon;
revoke all on table english.learning_progress_cache from authenticated;

create or replace function public.english_get_learning_progress()
returns jsonb
language plpgsql
stable
security definer
set search_path to 'pg_catalog', 'public', 'english', 'auth'
as $function$
declare
  v_uid uuid := auth.uid();
  v_now timestamptz := now();
  v_local timestamp without time zone;
  v_bucket_date date;
  v_bucket_no smallint;
  v_payload jsonb;
begin
  -- Preserve the historical unauthenticated behavior of the original RPC.
  if v_uid is null then
    return public.english_get_learning_progress_uncached();
  end if;

  v_local := v_now at time zone 'Asia/Kolkata';
  v_bucket_date := v_local::date;
  v_bucket_no := floor(extract(hour from v_local) / 8)::smallint;

  select c.payload
    into v_payload
  from english.learning_progress_cache c
  where c.user_id = v_uid
    and c.bucket_date = v_bucket_date
    and c.bucket_no = v_bucket_no;

  if v_payload is not null then
    return v_payload;
  end if;

  -- Prevent a cold-cache request stampede if multiple app reads arrive at once.
  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(
      'english-learning-progress:' || v_uid::text || ':' || v_bucket_date::text || ':' || v_bucket_no::text,
      0
    )
  );

  -- Another request may have populated the cache while we waited for the lock.
  select c.payload
    into v_payload
  from english.learning_progress_cache c
  where c.user_id = v_uid
    and c.bucket_date = v_bucket_date
    and c.bucket_no = v_bucket_no;

  if v_payload is not null then
    return v_payload;
  end if;

  v_payload := public.english_get_learning_progress_uncached();

  if v_payload is null then
    return null;
  end if;

  insert into english.learning_progress_cache(
    user_id, bucket_date, bucket_no, payload, computed_at
  ) values (
    v_uid, v_bucket_date, v_bucket_no, v_payload, v_now
  )
  on conflict (user_id) do update
  set bucket_date = excluded.bucket_date,
      bucket_no = excluded.bucket_no,
      payload = excluded.payload,
      computed_at = excluded.computed_at;

  return v_payload;
end;
$function$;

revoke all on function public.english_get_learning_progress() from public;
revoke all on function public.english_get_learning_progress() from anon;
grant execute on function public.english_get_learning_progress() to authenticated;
grant execute on function public.english_get_learning_progress() to service_role;

comment on table english.learning_progress_cache is
  'Per-user cached snapshot for the expensive learning-progress dashboard aggregate. Refreshed at most once per 8-hour Asia/Kolkata bucket.';
comment on function public.english_get_learning_progress() is
  'Cached learning-progress RPC. Heavy aggregation executes at most once per user per 8-hour Asia/Kolkata bucket.';
