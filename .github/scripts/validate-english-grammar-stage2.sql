\set ON_ERROR_STOP on

-- Reuse the full Stage 1 behavioral harness first. The workflow injects the two Stage 1 follow-up migrations
-- into that harness before this script is executed.
\ir validate-english-grammar-stage1.sql

-- Stage 1's disposable harness defines auth.uid() as NULL because service-owned generation does not use
-- learner JWT context. Stage 2 read/practice RPCs are authenticated learner functions, so pin the fixture user.
create or replace function auth.uid()
returns uuid
language sql
stable
as $$ select '11111111-1111-1111-1111-111111111111'::uuid $$;

\ir ../../supabase/migrations/20260909020000_english_grammar_world_read_model.sql

-- Hub must expose the same 260-rule curriculum and the already-published exact-20 Daily batch.
do $$
declare h jsonb;
begin
  h:=public.english_get_grammar_hub();
  if not coalesce((h->>'ok')::boolean,false) then raise exception 'Grammar hub not ok: %',h; end if;
  if (h->'stats'->>'totalRules')::int<>260 then raise exception 'Grammar hub rule count drifted: %',h; end if;
  if (h->'today'->>'count')::int<>20 or not (h->'today'->>'ready')::boolean then
    raise exception 'Grammar hub Today is not exact-20 ready: %',h;
  end if;
  if jsonb_array_length(h->'chapters')<>14 then raise exception 'Grammar hub chapter breadth drifted: %',h; end if;
end $$;

-- Today getter must return QuizRunner-compatible camelCase payloads and exact 20.
do $$
declare x jsonb; first_item jsonb;
begin
  x:=public.english_get_grammar_today();
  if not (x->>'ready')::boolean or (x->>'count')::int<>20 or jsonb_array_length(x->'items')<>20 then
    raise exception 'Grammar Today getter failed exact-20 contract: %',x;
  end if;
  first_item:=x->'items'->0;
  if coalesce(first_item->>'id','')='' or coalesce(first_item->>'questionType','')='' or jsonb_array_length(first_item->'options')<>4 then
    raise exception 'Grammar Today payload is not QuizRunner compatible: %',first_item;
  end if;
end $$;

-- Practice selectors are one-question-per-rule and bounded by requested size.
do $$
declare smart jsonb; weak jsonb; dueq jsonb; allq jsonb;
begin
  smart:=public.english_get_grammar_batch('smart',20,null);
  allq:=public.english_get_grammar_batch('all',20,null);
  weak:=public.english_get_grammar_batch('weak',20,null);
  dueq:=public.english_get_grammar_batch('due',20,null);
  if jsonb_array_length(smart)=0 or jsonb_array_length(smart)>20 then raise exception 'Smart Grammar batch invalid: %',smart; end if;
  if jsonb_array_length(allq)=0 or jsonb_array_length(allq)>20 then raise exception 'All Grammar batch invalid: %',allq; end if;
  if jsonb_array_length(weak)<1 then raise exception 'Weak Grammar batch should include the Stage 1 repeated-failure fixture'; end if;
  if exists(
    select 1 from (
      select value->>'ruleKey' k,count(*) c from jsonb_array_elements(smart) group by value->>'ruleKey' having count(*)>1
    ) d
  ) then raise exception 'Smart Grammar batch repeated a rule in one selection'; end if;
end $$;

-- Open the chapter/rule that owns the first published Grammar item. Read-only calls must not create evidence.
do $$
declare
  rkey text; chapter_name text; ch jsonb; rq jsonb; before_events integer; after_events integer;
begin
  select i.rule_key,r.chapter into rkey,chapter_name
  from english.grammar_daily_items i
  join english.grammar_rules r on r.rule_key=i.rule_key
  order by i.slot_no limit 1;

  select count(*) into before_events from english.grammar_rule_events;
  ch:=public.english_get_grammar_chapter(chapter_name);
  if not (ch->>'ok')::boolean or coalesce((ch->'stats'->>'totalRules')::int,0)<1 then
    raise exception 'Grammar chapter read model failed: %',ch;
  end if;
  rq:=public.english_get_grammar_rule_questions(rkey);
  if not (rq->>'readOnly')::boolean or (rq->>'count')::int<1 then
    raise exception 'Grammar rule read-only question bank failed: %',rq;
  end if;
  if jsonb_array_length(public.english_get_grammar_batch('smart',10,chapter_name))<1 then
    raise exception 'Chapter-scoped Smart Practice returned no available canonical question';
  end if;
  select count(*) into after_events from english.grammar_rule_events;
  if after_events<>before_events then
    raise exception 'Read-only Grammar World calls mutated evidence: before %, after %',before_events,after_events;
  end if;
end $$;

-- Invalid practice mode must fail closed.
do $$ begin
  begin
    perform public.english_get_grammar_batch('nonsense',20,null);
    raise exception 'Invalid Grammar mode unexpectedly succeeded';
  exception when others then
    if sqlerrm='Invalid Grammar mode unexpectedly succeeded' then raise; end if;
  end;
end $$;

select 'English Grammar Stage 2 PostgreSQL contracts passed' result;
