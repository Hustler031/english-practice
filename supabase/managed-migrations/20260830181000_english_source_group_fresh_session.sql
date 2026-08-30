-- English V2 grouped Sources/PDF fresh-session support.
-- Extends the central fresh-session gateway so a grouped archive is selected once,
-- deduplicated once, and only the final learner-visible rows are recorded as exposures.

create or replace function english.source_group_candidates(
  p_source_keys text[],
  p_mode text,
  p_count integer default 80
) returns jsonb
language plpgsql volatile security definer
set search_path='pg_catalog','public','english','auth'
as $$
declare
  keys text[];
  key_count integer;
  m text:=lower(btrim(coalesce(p_mode,'all')));
  n integer:=greatest(1,least(1000,coalesce(p_count,80)));
  per_key integer;
  out jsonb;
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  if m not in ('all','new','weak','random','starred') then
    raise exception 'Unknown Source Practice mode: %',p_mode;
  end if;

  select coalesce(array_agg(x.key order by x.first_ord),'{}'::text[])
  into keys
  from (
    select u.key,min(u.ord)::bigint first_ord
    from unnest(coalesce(p_source_keys,'{}'::text[])) with ordinality u(key,ord)
    where btrim(coalesce(u.key,''))<>''
    group by u.key
  ) x;

  key_count:=coalesce(cardinality(keys),0);
  if key_count=0 then return '[]'::jsonb; end if;

  -- One source gets a wide rotation window; grouped archives spread that window
  -- across keys while keeping at least ten candidates per selected source/date.
  per_key:=least(1000,greatest(10,ceil((n*4.0)/key_count)::integer));

  with source_rows as (
    select k.key_ord::int key_ord,e.ordinality::int local_ord,e.value j,
      coalesce(nullif(e.value->>'id',''),nullif(e.value->>'question_id',''),nullif(e.value->>'questionId','')) qid
    from unnest(keys) with ordinality k(source_key,key_ord)
    cross join lateral jsonb_array_elements(
      public.english_get_source_batch_core_20260830(k.source_key,m,per_key)
    ) with ordinality e(value,ordinality)
  ), dedup as (
    select distinct on (qid) qid,j,key_ord,local_ord
    from source_rows
    where qid is not null
    order by qid,local_ord,key_ord
  ), ranked as (
    select j,row_number() over(order by local_ord,key_ord,qid)::int ord
    from dedup
  ), chosen as (
    select * from ranked order by ord limit n
  )
  select coalesce(jsonb_agg(j order by ord),'[]'::jsonb)
  into out from chosen;

  return out;
end $$;

revoke all on function english.source_group_candidates(text[],text,integer) from public,anon,authenticated;
grant execute on function english.source_group_candidates(text[],text,integer) to service_role;

create or replace function public.english_start_fresh_session(
  p_rpc text,
  p_args jsonb default '{}'::jsonb,
  p_client_exclude text[] default '{}'::text[]
) returns jsonb
language plpgsql volatile security definer
set search_path='pg_catalog','public','english','auth'
as $$
declare
  uid uuid:=auth.uid();
  a jsonb:=coalesce(p_args,'{}'::jsonb);
  rpc_name text:=btrim(coalesce(p_rpc,''));
  m text:=lower(btrim(coalesce(a->>'p_mode','all')));
  n integer;
  candidate_n integer;
  raw jsonb;
  lane text;
  strict_unseen boolean:=false;
  cat text;
  source_key text;
  source_name text;
  source_keys text[];
  source_lane_hash text;
  set_id text;
  from_day integer;
  to_day integer;
  record_session boolean;
begin
  if uid is null then raise exception 'Authentication required'; end if;
  record_session:=not english.request_is_local_safe();

  case rpc_name
    when 'english_get_revision_batch' then
      n:=greatest(1,least(100,coalesce(nullif(a->>'p_count','')::integer,30)));
      m:=lower(btrim(coalesce(a->>'p_mode','smart')));
      candidate_n:=least(100,greatest(n,n*3));
      raw:=public.english_get_revision_batch_core_20260830(m,candidate_n);
      lane:='revision:'||m;

    when 'english_get_difficult_items' then
      n:=greatest(1,least(1000,coalesce(nullif(a->>'p_count','')::integer,100)));
      candidate_n:=least(1000,greatest(n,n*3));
      raw:=public.english_get_difficult_items_core_20260830(candidate_n);
      lane:='difficult';

    when 'english_get_saved_revision_batch' then
      n:=greatest(1,least(100,coalesce(nullif(a->>'p_count','')::integer,20)));
      m:=lower(btrim(coalesce(a->>'p_mode','smart')));
      candidate_n:=least(100,greatest(n,n*3));
      lane:='saved:'||m;
      if m='new' then
        strict_unseen:=true;
        select coalesce(jsonb_agg(j order by ord),'[]'::jsonb) into raw from (
          select row_number() over(order by c.created_at desc nulls last,c.question_id)::int ord,
            english.question_payload(uid,c.question_id)||jsonb_build_object(
              'smartMySaved',true,'smartMySavedLane','new','smartMySavedReason','Never Revised in My Saved'
            ) j
          from english.saved_revision_candidates(uid)c
          where not c.mastered and c.never_revised
          order by c.created_at desc nulls last,c.question_id
          limit candidate_n
        ) x;
      else
        raw:=public.english_get_saved_revision_batch_core_20260830(m,candidate_n);
      end if;

    when 'english_get_new_practice_batch' then
      n:=greatest(1,least(100,coalesce(nullif(a->>'p_count','')::integer,10)));
      m:=lower(btrim(coalesce(a->>'p_mode','all')));
      cat:=coalesce(a->>'p_category','ALL');
      source_name:=coalesce(a->>'p_source','ALL');
      candidate_n:=least(100,greatest(n,n*3));
      raw:=public.english_get_new_practice_batch_core_20260830(cat,m,candidate_n,source_name);
      strict_unseen:=m in ('new','newwords');
      lane:='new:'||lower(cat)||':'||m||':'||lower(source_name);

    when 'english_get_topic_batch' then
      n:=greatest(1,least(120,coalesce(nullif(a->>'p_count','')::integer,20)));
      m:=lower(btrim(coalesce(a->>'p_mode','all')));
      cat:=coalesce(a->>'p_category','ALL');
      candidate_n:=least(120,greatest(n,n*3));
      raw:=public.english_get_topic_batch_core_20260830(cat,m,candidate_n);
      strict_unseen:=m='new';
      lane:='topic:'||lower(cat)||':'||m;

    when 'english_get_source_batch' then
      n:=greatest(1,least(1000,coalesce(nullif(a->>'p_count','')::integer,20)));
      m:=lower(btrim(coalesce(a->>'p_mode','all')));
      source_key:=coalesce(a->>'p_source_key','');
      candidate_n:=least(1000,greatest(n,n*3));
      raw:=public.english_get_source_batch_core_20260830(source_key,m,candidate_n);
      strict_unseen:=m='new';
      lane:='source:'||lower(source_key)||':'||m;

    when 'english_get_source_group_batch' then
      n:=greatest(1,least(1000,coalesce(nullif(a->>'p_count','')::integer,20)));
      m:=lower(btrim(coalesce(a->>'p_mode','all')));
      select coalesce(array_agg(x.value),'{}'::text[]) into source_keys
      from jsonb_array_elements_text(coalesce(a->'p_source_keys','[]'::jsonb)) x(value)
      where btrim(coalesce(x.value,''))<>'';
      if coalesce(cardinality(source_keys),0)=0 then return '[]'::jsonb; end if;
      candidate_n:=least(1000,greatest(n,n*4));
      raw:=english.source_group_candidates(source_keys,m,candidate_n);
      strict_unseen:=m='new';
      select md5(string_agg(lower(k),'|' order by lower(k))) into source_lane_hash
      from (select distinct unnest(source_keys) k) s;
      lane:='source-group:'||coalesce(source_lane_hash,'none')||':'||m;

    when 'english_get_demand_batch' then
      n:=greatest(1,least(1000,coalesce(nullif(a->>'p_count','')::integer,20)));
      m:=lower(btrim(coalesce(a->>'p_mode','all')));
      set_id:=coalesce(a->>'p_set_id','__ALL__');
      if m='all' then raise exception 'Demand Practice All is a fixed/resume lane'; end if;
      candidate_n:=least(1000,greatest(n,n*3));
      raw:=public.english_get_demand_batch_core_20260830(set_id,m,candidate_n);
      lane:='demand:'||lower(set_id)||':'||m;

    when 'english_get_starred_batch' then
      n:=greatest(1,least(50,coalesce(nullif(a->>'p_count','')::integer,20)));
      m:=lower(btrim(coalesce(a->>'p_mode','smart')));
      from_day:=nullif(a->>'p_from_day','')::integer;
      to_day:=nullif(a->>'p_to_day','')::integer;
      candidate_n:=least(50,greatest(n,n*3));
      raw:=public.english_get_starred_batch_core_20260830(m,candidate_n,from_day,to_day);
      lane:='starred:'||m||':'||coalesce(from_day::text,'any')||':'||coalesce(to_day::text,'any');

    when 'english_get_phrasal_batch' then
      n:=greatest(1,least(100,coalesce(nullif(a->>'p_count','')::integer,20)));
      m:=lower(btrim(coalesce(a->>'p_mode','smart')));
      candidate_n:=least(100,greatest(n,n*3));
      raw:=public.english_get_phrasal_batch_core_20260830(m,candidate_n);
      lane:='phrasal:'||m;

    when 'english_get_today_extra_batch' then
      n:=greatest(1,least(30,coalesce(nullif(a->>'p_count','')::integer,20)));
      candidate_n:=least(100,greatest(n,n*3));
      raw:=english.extra_practice_candidates(uid,candidate_n);
      lane:='extra';

    when 'english_get_bank_coverage_batch' then
      n:=greatest(1,least(100,coalesce(nullif(a->>'p_count','')::integer,10)));
      cat:=coalesce(a->>'p_category','ALL');
      candidate_n:=least(300,greatest(n,n*3));
      raw:=english.bank_unseen_candidates(uid,cat,candidate_n);
      strict_unseen:=true;
      lane:='bank-unseen:'||lower(cat);

    else
      raise exception 'RPC is not a fresh-session lane: %',rpc_name;
  end case;

  return english.rotate_fresh_session_batch(
    uid,lane,raw,n,strict_unseen,coalesce(p_client_exclude,'{}'::text[]),record_session
  );
end $$;

revoke all on function public.english_start_fresh_session(text,jsonb,text[]) from public,anon;
grant execute on function public.english_start_fresh_session(text,jsonb,text[]) to authenticated,service_role;
