-- Optional editorial tone items remain separate from Hindu vocabulary Concept_ID semantics.
-- Manual ChatGPT Saved upgrades reuse the validated Saved enrichment RPC.

create table if not exists english.editorial_tone_items (
  tone_id uuid primary key default gen_random_uuid(),
  source_date date not null,
  source_name text not null,
  source_url text,
  tone_kind text not null check (tone_kind in ('actual','counterfactual')),
  context_paraphrase text not null,
  question text not null,
  options jsonb not null,
  correct_key text not null check (correct_key in ('A','B','C','D')),
  explanation text not null,
  quality jsonb not null,
  fingerprint text not null unique,
  active boolean not null default true,
  created_at timestamptz not null default now()
);
alter table english.editorial_tone_items enable row level security;
revoke all on english.editorial_tone_items from public, anon, authenticated;
grant select,insert,update on english.editorial_tone_items to service_role;

create or replace function public.english_apply_editorial_tone_items(p_items jsonb)
returns jsonb
language plpgsql security definer
set search_path='pg_catalog','public','english'
as $$
declare
  x jsonb;
  n integer:=0;
  inserted integer:=0;
  fp text;
begin
  if not english.ai_feature_enabled('hindu_tone_v1') then raise exception 'Editorial tone feature is disabled'; end if;
  if jsonb_typeof(coalesce(p_items,'null'::jsonb))<>'array' or jsonb_array_length(p_items)>3 then
    raise exception 'At most 3 editorial tone items are allowed';
  end if;
  perform english.assert_generated_items_quality(p_items,false);

  for x in select value from jsonb_array_elements(p_items) loop
    n:=n+1;
    if length(coalesce(x->>'contextParaphrase',''))>700 then raise exception 'Tone context % is too long',n; end if;
    if jsonb_typeof(coalesce(x->'options','null'::jsonb))<>'array' or jsonb_array_length(x->'options')<>4 then
      raise exception 'Tone item % requires four options',n;
    end if;
    fp:=coalesce(nullif(x->>'fingerprint',''),md5(lower(regexp_replace(coalesce(x->>'question','')||' '||coalesce(x->>'contextParaphrase',''),'\s+',' ','g'))));
    insert into english.editorial_tone_items(
      source_date,source_name,source_url,tone_kind,context_paraphrase,question,options,correct_key,explanation,quality,fingerprint
    ) values(
      coalesce((x->>'sourceDate')::date,(now() at time zone 'Asia/Kolkata')::date),
      coalesce(nullif(x->>'sourceName',''),'Current editorial'),nullif(x->>'sourceUrl',''),
      coalesce(nullif(x->>'toneKind',''),'actual'),x->>'contextParaphrase',x->>'question',x->'options',
      upper(x->>'correctKey'),x->>'explanation',x->'quality',fp
    ) on conflict(fingerprint) do nothing;
    if found then inserted:=inserted+1; end if;
  end loop;
  return jsonb_build_object('ok',true,'received',n,'inserted',inserted);
end $$;
revoke all on function public.english_apply_editorial_tone_items(jsonb) from public, anon, authenticated;
grant execute on function public.english_apply_editorial_tone_items(jsonb) to service_role;

create or replace function public.english_get_editorial_tone_recent(p_limit integer default 3)
returns jsonb
language sql stable security definer
set search_path='pg_catalog','public','english','auth'
as $$
select case when auth.uid() is null
  then jsonb_build_object('ok',false,'error','Authentication required')
  else jsonb_build_object('ok',true,'items',coalesce((
    select jsonb_agg(jsonb_build_object(
      'toneId',tone_id,'sourceDate',source_date,'sourceName',source_name,'toneKind',tone_kind,
      'context',context_paraphrase,'question',question,'options',options,'correctKey',correct_key,'explanation',explanation
    ) order by source_date desc,created_at desc)
    from (
      select * from english.editorial_tone_items where active
      order by source_date desc,created_at desc
      limit greatest(1,least(10,coalesce(p_limit,3)))
    ) t
  ),'[]'::jsonb)) end
$$;
grant execute on function public.english_get_editorial_tone_recent(integer) to authenticated, service_role;

create or replace function public.english_manual_upgrade_saved_item(p_saved_id text,p_item jsonb)
returns jsonb
language plpgsql security definer
set search_path='pg_catalog','public','english','auth'
as $$
declare
  owner_id uuid;
  owner_count integer;
  out jsonb;
begin
  select count(*),max(s.user_id::text)::uuid into owner_count,owner_id
  from english.saved_items s where s.active and s.saved_id=p_saved_id;
  if owner_count<>1 then raise exception 'Saved item not found'; end if;
  perform english.assert_generated_items_quality(jsonb_build_array(p_item),false);
  perform set_config('request.jwt.claim.sub',owner_id::text,true);

  out:=public.english_set_saved_enrichment(
    p_saved_id,
    coalesce(p_item->>'meaning',''),coalesce(p_item->>'partOfSpeech',''),
    coalesce(p_item->>'synonyms',''),coalesce(p_item->>'antonyms',''),
    coalesce(p_item->>'example',''),coalesce(p_item->>'explanation',''),
    coalesce(p_item->>'question',''),coalesce(p_item->>'optionA',''),coalesce(p_item->>'optionB',''),
    coalesce(p_item->>'optionC',''),coalesce(p_item->>'optionD',''),upper(coalesce(p_item->>'correctOption','')),
    'manual ChatGPT upgraded/reviewed','Ready'
  );
  return jsonb_build_object('ok',true,'savedId',p_saved_id,'result',out,'provenance','manual_chatgpt_upgraded');
end $$;
revoke all on function public.english_manual_upgrade_saved_item(text,jsonb) from public, anon, authenticated;
grant execute on function public.english_manual_upgrade_saved_item(text,jsonb) to service_role;
