-- Fresh-session rotation and My Saved New lane.
-- Resume remains exact because QuizRunner persists the active session client-side.
-- Fresh launches over-fetch the existing intelligent pool, prefer questions not
-- attempted in the same module during the last 90 minutes, then randomise only
-- the presentation order. If the pool is too small, recent questions remain as fallback.

create index if not exists attempts_user_module_recent_idx
on english.attempts(user_id, (lower(btrim(coalesce(module,'')))), attempted_at desc, question_id);

create or replace function english.was_recent_module_attempt(
  p_user_id uuid,
  p_question_id text,
  p_module text,
  p_minutes integer default 90
) returns boolean
language sql stable security definer
set search_path='pg_catalog','english'
as $$
  select exists(
    select 1
    from english.attempts a
    where a.user_id=p_user_id
      and a.question_id=p_question_id
      and lower(btrim(coalesce(a.module,'')))=lower(btrim(coalesce(p_module,'')))
      and a.attempted_at >= now() - make_interval(mins => greatest(1,coalesce(p_minutes,90)))
  );
$$;

create or replace function english.rotate_fresh_batch(
  p_user_id uuid,
  p_module text,
  p_rows jsonb,
  p_limit integer,
  p_minutes integer default 90
) returns jsonb
language sql volatile security definer
set search_path='pg_catalog','english'
as $$
with expanded as (
  select e.value j,e.ordinality ord,
         english.was_recent_module_attempt(
           p_user_id,
           coalesce(e.value->>'id',e.value->>'question_id',''),
           p_module,
           p_minutes
         ) recent
  from jsonb_array_elements(coalesce(p_rows,'[]'::jsonb)) with ordinality e(value,ordinality)
), picked as (
  select j
  from expanded
  order by recent asc,ord asc
  limit greatest(1,coalesce(p_limit,20))
), shuffled as (
  select j,random() r from picked
)
select coalesce(jsonb_agg(j order by r),'[]'::jsonb) from shuffled;
$$;

revoke all on function english.was_recent_module_attempt(uuid,text,text,integer) from public,anon;
revoke all on function english.rotate_fresh_batch(uuid,text,jsonb,integer,integer) from public,anon;
grant execute on function english.was_recent_module_attempt(uuid,text,text,integer) to authenticated,service_role;
grant execute on function english.rotate_fresh_batch(uuid,text,jsonb,integer,integer) to authenticated,service_role;

-- My Saved: preserve the existing intelligence engine as the core and add:
-- 1) a true module-specific New lane (never revised in My Saved),
-- 2) recent-session cooldown for every fresh non-New launch.
alter function public.english_get_saved_revision_batch(text,integer)
  rename to english_get_saved_revision_batch_core_20260830;

create or replace function public.english_get_saved_revision_batch(
  p_mode text default 'smart',
  p_count integer default 20
) returns jsonb
language plpgsql volatile security definer
set search_path='pg_catalog','public','english','auth'
as $$
declare
  uid uuid:=auth.uid();
  m text:=lower(btrim(coalesce(p_mode,'smart')));
  n integer:=greatest(1,least(100,coalesce(p_count,20)));
  candidate_n integer;
  raw jsonb;
  out jsonb;
begin
  if uid is null then raise exception 'Authentication required'; end if;

  if m='new' then
    select coalesce(jsonb_agg(j order by random()),'[]'::jsonb) into out
    from (
      select english.question_payload(uid,c.question_id)
        || jsonb_build_object(
             'smartMySaved',true,
             'smartMySavedLane','new',
             'smartMySavedReason','Never Revised in My Saved'
           ) j
      from english.saved_revision_candidates(uid) c
      where not c.mastered and c.never_revised
      order by c.created_at desc nulls last,c.question_id
      limit n
    ) x;
    return out;
  end if;

  if m not in ('smart','weak','difficult','starred','random','all') then
    raise exception 'Unknown My Saved mode: %',p_mode;
  end if;

  candidate_n:=least(100,greatest(n,n*3));
  raw:=public.english_get_saved_revision_batch_core_20260830(m,candidate_n);
  return english.rotate_fresh_batch(uid,'mySavedRevision',raw,n,90);
end $$;

revoke all on function public.english_get_saved_revision_batch(text,integer) from public,anon;
grant execute on function public.english_get_saved_revision_batch(text,integer) to authenticated,service_role;
revoke execute on function public.english_get_saved_revision_batch_core_20260830(text,integer) from public,anon,authenticated;

create or replace function public.english_get_saved_revision_hub() returns jsonb
language sql stable security definer
set search_path='pg_catalog','public','english','auth'
as $$
with c as (select * from english.saved_revision_candidates(auth.uid())),
stats as (
 select count(*)::int saved,
        count(*) filter(where not mastered)::int eligible,
        count(*) filter(where not mastered and controlled_new)::int controlled_new,
        count(*) filter(where not mastered and never_revised)::int never_revised,
        count(*) filter(where not mastered and due)::int due,
        count(*) filter(where not mastered and state in ('Persistent Weak','Weak','Fragile'))::int weak,
        count(*) filter(where not mastered and difficult)::int difficult,
        count(*) filter(where not mastered and starred)::int starred,
        count(*) filter(where mastered)::int mastered
 from c
), days as (
 select (created_at at time zone 'Asia/Kolkata')::date d,
        count(*)::int saved,
        count(*) filter(where not mastered)::int eligible,
        count(*) filter(where not mastered and controlled_new)::int controlled_new,
        count(*) filter(where not mastered and due)::int due,
        count(*) filter(where not mastered and state in ('Persistent Weak','Weak','Fragile'))::int weak,
        count(*) filter(where not mastered and difficult)::int difficult,
        count(*) filter(where mastered)::int mastered
 from c group by 1 order by 1 desc
), day_meta as (
 select greatest(1,((now() at time zone 'Asia/Kolkata')::date-date '2026-08-14')+1)::int current_day
)
select jsonb_build_object(
 'version','V4',
 'currentDay',m.current_day,
 'stats',jsonb_build_object(
   'saved',s.saved,'eligible',s.eligible,'controlledNew',s.controlled_new,
   'neverRevised',s.never_revised,'due',s.due,'weak',s.weak,
   'difficult',s.difficult,'starred',s.starred,'mastered',s.mastered
 ),
 'available',jsonb_build_object(
   'smart',s.eligible,'new',s.never_revised,'weak',s.weak,
   'difficult',s.difficult,'starred',s.starred,'random',s.eligible,'all',s.eligible
 ),
 'sizes',jsonb_build_array(10,20,30,50),
 'history',coalesce((
   select jsonb_agg(jsonb_build_object(
     'date',d,'day',greatest(1,(d-date '2026-08-14')+1),'label',to_char(d,'DD Mon YYYY'),
     'saved',saved,'eligible',eligible,'controlledNew',controlled_new,'due',due,
     'weak',weak,'difficult',difficult,'mastered',mastered
   ) order by d desc) from days
 ),'[]'::jsonb)
) from stats s cross join day_meta m;
$$;

revoke all on function public.english_get_saved_revision_hub() from public,anon;
grant execute on function public.english_get_saved_revision_hub() to authenticated,service_role;

-- Central Revision.
alter function public.english_get_revision_batch(text,integer)
  rename to english_get_revision_batch_core_20260830;

create or replace function public.english_get_revision_batch(
  p_mode text default 'smart',
  p_count integer default 30
) returns jsonb
language plpgsql volatile security definer
set search_path='pg_catalog','public','english','auth'
as $$
declare
  uid uuid:=auth.uid();
  n integer:=greatest(1,least(100,coalesce(p_count,30)));
  raw jsonb;
begin
  if uid is null then raise exception 'Authentication required'; end if;
  raw:=public.english_get_revision_batch_core_20260830(p_mode,least(100,greatest(n,n*3)));
  return english.rotate_fresh_batch(uid,'revision',raw,n,90);
end $$;

revoke all on function public.english_get_revision_batch(text,integer) from public,anon;
grant execute on function public.english_get_revision_batch(text,integer) to authenticated,service_role;
revoke execute on function public.english_get_revision_batch_core_20260830(text,integer) from public,anon,authenticated;

-- Difficult-only revision.
alter function public.english_get_difficult_items(integer)
  rename to english_get_difficult_items_core_20260830;

create or replace function public.english_get_difficult_items(
  p_count integer default 100
) returns jsonb
language plpgsql volatile security definer
set search_path='pg_catalog','public','english','auth'
as $$
declare
  uid uuid:=auth.uid();
  n integer:=greatest(1,least(1000,coalesce(p_count,100)));
  raw jsonb;
begin
  if uid is null then raise exception 'Authentication required'; end if;
  raw:=public.english_get_difficult_items_core_20260830(least(1000,greatest(n,n*3)));
  return english.rotate_fresh_batch(uid,'difficult',raw,n,90);
end $$;

revoke all on function public.english_get_difficult_items(integer) from public,anon;
grant execute on function public.english_get_difficult_items(integer) to authenticated,service_role;
revoke execute on function public.english_get_difficult_items_core_20260830(integer) from public,anon,authenticated;

-- New Practice: make "new" genuinely unseen, then wrap all fresh launches
-- with recent-session rotation.
alter function public.english_get_new_practice_batch(text,text,integer,text)
  rename to english_get_new_practice_batch_core_20260830;

create or replace function public.english_get_new_practice_batch_core_20260830(
  p_category text default 'ALL',
  p_mode text default 'all',
  p_count integer default 10,
  p_source text default 'ALL'
) returns jsonb
language plpgsql volatile security definer
set search_path='pg_catalog','public','english','auth'
as $$
declare
  uid uuid:=auth.uid();
  v_cat text:=upper(btrim(coalesce(p_category,'ALL')));
  v_mode text:=lower(btrim(coalesce(p_mode,'all')));
  v_source text:=btrim(coalesce(p_source,'ALL'));
  v_n integer:=greatest(1,least(100,coalesce(p_count,10)));
  out jsonb;
begin
 if uid is null then raise exception 'Authentication required'; end if;
 if v_mode not in ('all','new','newwords','weak','random','starred') then
   raise exception 'Unknown New Practice mode: %',p_mode;
 end if;

 with base as (
  select q.question_id,
         english.new_practice_type(uid,q) type_id,
         english.new_practice_source(uid,q) source_name,
         english.recent_content_date(q) added,
         coalesce(s.status,'New') st,
         coalesce(s.attempts,0) att,
         coalesce(s.last_marked,false) starred,
         s.last_attempt
  from english.questions q
  left join english.question_state s on s.user_id=uid and s.question_id=q.question_id
  where q.active and english.question_visible_to_user(uid,q.question_id)
    and not coalesce(s.mastered,false)
    and (
      english.recent_content_date(q) is not null
      or exists(select 1 from english.hindu_vocab_registry h where h.user_id=uid and h.active and h.in_vocab and h.question_id=q.question_id)
      or exists(select 1 from english.saved_items si where si.user_id=uid and si.active and si.practice_question_id=q.question_id)
    )
 ), filtered as (
  select * from base
  where (v_cat='ALL' or type_id=v_cat)
    and (v_source='ALL' or source_name=v_source)
    and (
      v_mode not in ('new','newwords','weak','starred')
      or (v_mode in ('new','newwords') and att=0)
      or (v_mode='weak' and st in ('Persistent Weak','Weak','Fragile'))
      or (v_mode='starred' and starred)
    )
 ), ranked as (
  select question_id,row_number() over(order by
    case
      when v_mode in ('new','newwords') and added is not null then 0
      when v_mode in ('new','newwords') then 1
      when v_mode='random' and st in ('Persistent Weak','Weak','Fragile') then 0
      when v_mode='random' and added>=((now() at time zone 'Asia/Kolkata')::date-6) then 1
      when v_mode='random' and starred then 2
      when v_mode='random' and att>0 then 3
      else 4
    end,
    case when v_mode in ('weak','random','starred') then random() else 0 end,
    added desc nulls last,last_attempt asc nulls first,question_id
  )::int ord
  from filtered
 ), chosen as (
   select * from ranked order by ord limit v_n
 )
 select coalesce(jsonb_agg(english.question_payload(uid,c.question_id) order by c.ord),'[]'::jsonb)
 into out from chosen c;
 return out;
end $$;

create or replace function public.english_get_new_practice_batch(
  p_category text default 'ALL',
  p_mode text default 'all',
  p_count integer default 10,
  p_source text default 'ALL'
) returns jsonb
language plpgsql volatile security definer
set search_path='pg_catalog','public','english','auth'
as $$
declare
  uid uuid:=auth.uid();
  n integer:=greatest(1,least(100,coalesce(p_count,10)));
  raw jsonb;
begin
  if uid is null then raise exception 'Authentication required'; end if;
  raw:=public.english_get_new_practice_batch_core_20260830(
    p_category,p_mode,least(100,greatest(n,n*3)),p_source
  );
  return english.rotate_fresh_batch(uid,'new',raw,n,90);
end $$;

revoke all on function public.english_get_new_practice_batch(text,text,integer,text) from public,anon;
grant execute on function public.english_get_new_practice_batch(text,text,integer,text) to authenticated,service_role;
revoke execute on function public.english_get_new_practice_batch_core_20260830(text,text,integer,text) from public,anon,authenticated;

-- Source/PDF Practice: push mode filtering to the backend, raise the old 100-row
-- ceiling, and rotate fresh sessions before the client slices the merged result.
alter function public.english_get_source_batch(text,text,integer)
  rename to english_get_source_batch_core_20260830;

create or replace function public.english_get_source_batch_core_20260830(
  p_source_key text,
  p_mode text default 'all',
  p_count integer default 20
) returns jsonb
language plpgsql volatile security definer
set search_path='pg_catalog','public','english','auth'
as $$
declare
  uid uuid:=auth.uid();
  v_key text:=btrim(coalesce(p_source_key,''));
  v_mode text:=lower(btrim(coalesce(p_mode,'all')));
  v_n integer:=greatest(1,least(1000,coalesce(p_count,20)));
  v_date date;
  out jsonb;
begin
 if uid is null then raise exception 'Authentication required'; end if;
 if v_mode not in ('all','new','weak','random','starred') then
   raise exception 'Unknown Source Practice mode: %',p_mode;
 end if;
 if v_key like 'THE_HINDU::%' then
   begin v_date:=substring(v_key from 12)::date; exception when others then v_date:=null; end;
 end if;

 with base as (
  select q.question_id,
         coalesce(s.status,'New') st,
         coalesce(s.attempts,0) att,
         coalesce(s.last_marked,false) starred,
         english.recent_content_date(q) added
  from english.questions q
  left join english.question_state s on s.user_id=uid and s.question_id=q.question_id
  where q.active and english.question_visible_to_user(uid,q.question_id)
    and not coalesce(s.mastered,false)
    and (
      (v_date is not null and english.source_descriptor_key(q)='THE_HINDU' and english.recent_content_date(q)=v_date)
      or (v_date is null and english.source_descriptor_key(q)=v_key)
    )
 ), filtered as (
   select * from base
   where v_mode not in ('new','weak','starred')
      or (v_mode='new' and att=0)
      or (v_mode='weak' and st in ('Persistent Weak','Weak','Fragile'))
      or (v_mode='starred' and starred)
 ), ranked as (
  select question_id,row_number() over(order by
    case
      when v_mode='random' and st in ('Persistent Weak','Weak','Fragile') then 0
      when v_mode='random' and added>=((now() at time zone 'Asia/Kolkata')::date-6) then 1
      when v_mode='random' and starred then 2
      when v_mode='random' and att>0 then 3
      else 4
    end,
    case when v_mode in ('weak','random','starred') then random() else 0 end,
    added desc nulls last,question_id
  )::int ord from filtered
 ), chosen as (
   select * from ranked order by ord limit v_n
 )
 select coalesce(jsonb_agg(english.question_payload(uid,c.question_id) order by c.ord),'[]'::jsonb)
 into out from chosen c;
 return out;
end $$;

create or replace function public.english_get_source_batch(
  p_source_key text,
  p_mode text default 'all',
  p_count integer default 20
) returns jsonb
language plpgsql volatile security definer
set search_path='pg_catalog','public','english','auth'
as $$
declare
  uid uuid:=auth.uid();
  n integer:=greatest(1,least(1000,coalesce(p_count,20)));
  raw jsonb;
begin
  if uid is null then raise exception 'Authentication required'; end if;
  raw:=public.english_get_source_batch_core_20260830(
    p_source_key,p_mode,least(1000,greatest(n,n*3))
  );
  return english.rotate_fresh_batch(uid,'source',raw,n,90);
end $$;

revoke all on function public.english_get_source_batch(text,text,integer) from public,anon;
grant execute on function public.english_get_source_batch(text,text,integer) to authenticated,service_role;
revoke execute on function public.english_get_source_batch_core_20260830(text,text,integer) from public,anon,authenticated;

-- Topic Practice.
alter function public.english_get_topic_batch(text,text,integer)
  rename to english_get_topic_batch_core_20260830;

create or replace function public.english_get_topic_batch(
  p_category text,
  p_mode text default 'all',
  p_count integer default 20
) returns jsonb
language plpgsql volatile security definer
set search_path='pg_catalog','public','english','auth'
as $$
declare
  uid uuid:=auth.uid();
  n integer:=greatest(1,least(120,coalesce(p_count,20)));
  raw jsonb;
begin
  if uid is null then raise exception 'Authentication required'; end if;
  raw:=public.english_get_topic_batch_core_20260830(
    p_category,p_mode,least(120,greatest(n,n*3))
  );
  return english.rotate_fresh_batch(uid,'topic',raw,n,90);
end $$;

revoke all on function public.english_get_topic_batch(text,text,integer) from public,anon;
grant execute on function public.english_get_topic_batch(text,text,integer) to authenticated,service_role;
revoke execute on function public.english_get_topic_batch_core_20260830(text,text,integer) from public,anon,authenticated;

-- Demanded Practice: keep Practice All deterministic so its persisted resume index
-- still points at the same ordered set. Weak/Random get fresh-session rotation.
alter function public.english_get_demand_batch(text,text,integer)
  rename to english_get_demand_batch_core_20260830;

create or replace function public.english_get_demand_batch_core_20260830(
  p_set_id text default '__ALL__',
  p_mode text default 'all',
  p_count integer default 20
) returns jsonb
language plpgsql volatile security definer
set search_path='pg_catalog','public','english','auth'
as $$
declare
  uid uuid:=auth.uid();
  v_id text:=btrim(coalesce(p_set_id,'__ALL__'));
  v_mode text:=lower(btrim(coalesce(p_mode,'all')));
  v_n integer:=greatest(1,least(1000,coalesce(p_count,20)));
  out jsonb;
begin
 if uid is null then raise exception 'Authentication required'; end if;
 with base as (
  select q.question_id,min(i.sequence)::int seq,
         english.recent_content_date(q) added,
         coalesce(s.status,'New') st,
         coalesce(s.wrong,0) wr,
         coalesce(s.attempts,0) att,
         coalesce(s.last_marked,false) starred
  from english.practice_set_items i
  join english.practice_sets ps on ps.set_id=i.set_id
  join english.questions q on q.question_id=i.question_id
  left join english.question_state s on s.user_id=uid and s.question_id=q.question_id
  where ps.active and (v_id='__ALL__' or i.set_id=v_id)
    and q.active and english.question_visible_to_user(uid,q.question_id)
    and not coalesce(s.mastered,false)
    and (
      v_mode<>'weak'
      or coalesce(s.status,'New') in ('Persistent Weak','Weak','Fragile')
      or coalesce(s.wrong,0)>0
      or coalesce(s.attempts,0)>0
    )
  group by q.question_id,s.status,s.wrong,s.attempts,s.last_marked
 ), ranked as (
  select b.question_id,row_number() over(order by
    case
      when v_mode='random' and (b.st in ('Persistent Weak','Weak','Fragile') or b.wr>0) then 0
      when v_mode='random' and b.added>=((now() at time zone 'Asia/Kolkata')::date-6) then 1
      when v_mode='random' and b.starred then 2
      when v_mode='random' and b.att>0 then 3
      else 4
    end,
    case when v_mode in ('weak','random') then random() else b.seq::double precision end,
    b.question_id
  )::int ord
  from base b
 ), chosen as (
   select * from ranked order by ord limit v_n
 )
 select coalesce(jsonb_agg(english.question_payload(uid,c.question_id) order by c.ord),'[]'::jsonb)
 into out from chosen c;
 return out;
end $$;

create or replace function public.english_get_demand_batch(
  p_set_id text default '__ALL__',
  p_mode text default 'all',
  p_count integer default 20
) returns jsonb
language plpgsql volatile security definer
set search_path='pg_catalog','public','english','auth'
as $$
declare
  uid uuid:=auth.uid();
  m text:=lower(btrim(coalesce(p_mode,'all')));
  n integer:=greatest(1,least(1000,coalesce(p_count,20)));
  raw jsonb;
begin
  if uid is null then raise exception 'Authentication required'; end if;
  if m='all' then
    return public.english_get_demand_batch_core_20260830(p_set_id,m,n);
  end if;
  raw:=public.english_get_demand_batch_core_20260830(
    p_set_id,m,least(1000,greatest(n,n*3))
  );
  return english.rotate_fresh_batch(uid,'demand',raw,n,90);
end $$;

revoke all on function public.english_get_demand_batch(text,text,integer) from public,anon;
grant execute on function public.english_get_demand_batch(text,text,integer) to authenticated,service_role;
revoke execute on function public.english_get_demand_batch_core_20260830(text,text,integer) from public,anon,authenticated;

-- Starred Smart/Focus lanes: over-fetch the existing intelligence output and
-- move questions revised in the last 90 minutes to fallback positions.
alter function public.english_get_starred_batch(text,integer,integer,integer)
  rename to english_get_starred_batch_core_20260830;

create or replace function public.english_get_starred_batch(
  p_mode text default 'smart',
  p_count integer default 20,
  p_from_day integer default null,
  p_to_day integer default null
) returns jsonb
language plpgsql volatile security definer
set search_path='pg_catalog','public','english','auth'
as $$
declare
  uid uuid:=auth.uid();
  n integer:=greatest(1,least(50,coalesce(p_count,20)));
  raw jsonb;
begin
  if uid is null then raise exception 'Authentication required'; end if;
  raw:=public.english_get_starred_batch_core_20260830(
    p_mode,least(50,greatest(n,n*3)),p_from_day,p_to_day
  );
  return english.rotate_fresh_batch(uid,'starredRevision',raw,n,90);
end $$;

revoke all on function public.english_get_starred_batch(text,integer,integer,integer) from public,anon;
grant execute on function public.english_get_starred_batch(text,integer,integer,integer) to authenticated,service_role;
revoke execute on function public.english_get_starred_batch_core_20260830(text,integer,integer,integer) from public,anon,authenticated;

-- Phrasal Smart/Focus lanes: preserve concept intelligence and its least-used
-- variant selection, then rotate exact questions recently served by Phrasal Revision.
alter function public.english_get_phrasal_batch(text,integer)
  rename to english_get_phrasal_batch_core_20260830;

create or replace function public.english_get_phrasal_batch(
  p_mode text default 'smart',
  p_count integer default 20
) returns jsonb
language plpgsql volatile security definer
set search_path='pg_catalog','public','english','auth'
as $$
declare
  uid uuid:=auth.uid();
  n integer:=greatest(1,least(100,coalesce(p_count,20)));
  raw jsonb;
begin
  if uid is null then raise exception 'Authentication required'; end if;
  raw:=public.english_get_phrasal_batch_core_20260830(
    p_mode,least(100,greatest(n,n*3))
  );
  return english.rotate_fresh_batch(uid,'phrasalRevision',raw,n,90);
end $$;

revoke all on function public.english_get_phrasal_batch(text,integer) from public,anon;
grant execute on function public.english_get_phrasal_batch(text,integer) to authenticated,service_role;
revoke execute on function public.english_get_phrasal_batch_core_20260830(text,integer) from public,anon,authenticated;

-- Intentionally repetitive lanes remain untouched:
-- Daily persisted set, Hindu rounds, Phrasal Today, Bank Coverage Today Review.
