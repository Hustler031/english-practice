-- Make newly saved/requeued My Saved items durable and fast without weakening
-- failure backoff. New pending work gets an immediate kick from the save RPC;
-- this migration adds a durable pending row plus a one-minute busy-worker
-- watchdog. Retry failures remain on the existing five-minute recovery lane.

create or replace function english.on_saved_enrichment_pending_queue()
returns trigger
language plpgsql
security definer
set search_path to 'pg_catalog','english'
as $$
begin
  if coalesce(new.active,true)
     and lower(btrim(coalesce(new.gpt_status,''))) in ('','pending gpt','needs enrichment')
     and (tg_op='INSERT' or old.gpt_status is distinct from new.gpt_status)
  then
    insert into english.saved_enrichment_item_state(
      user_id,saved_id,state,attempt_count,lease_id,last_attempt_at,last_error,
      last_error_at,next_attempt_at,updated_at,last_success_at,last_error_class,
      transient_failure_count
    ) values(
      new.user_id,new.saved_id,'pending',0,null,null,null,null,null,now(),null,null,0
    )
    on conflict(user_id,saved_id) do update set
      state='pending',attempt_count=0,lease_id=null,last_error=null,
      last_error_at=null,next_attempt_at=null,updated_at=now(),
      last_error_class=null,transient_failure_count=0
    where english.saved_enrichment_item_state.state<>'processing';
  end if;
  return new;
end;
$$;

drop trigger if exists english_saved_enrichment_pending_queue on english.saved_items;
create trigger english_saved_enrichment_pending_queue
after insert or update of gpt_status on english.saved_items
for each row execute function english.on_saved_enrichment_pending_queue();

-- Heal only genuinely new Pending GPT rows that pre-date the trigger. Do not
-- fast-lane the historical Needs Enrichment/retrying backlog.
insert into english.saved_enrichment_item_state(
  user_id,saved_id,state,attempt_count,lease_id,last_attempt_at,last_error,
  last_error_at,next_attempt_at,updated_at,last_success_at,last_error_class,
  transient_failure_count
)
select s.user_id,s.saved_id,'pending',0,null,null,null,null,null,now(),null,null,0
from english.saved_items s
where s.active
  and lower(btrim(coalesce(s.gpt_status,'')))='pending gpt'
  and not exists(
    select 1 from english.saved_enrichment_item_state es
    where es.user_id=s.user_id and es.saved_id=s.saved_id
  )
on conflict(user_id,saved_id) do nothing;

-- Pending work is always first, and the limit is applied AFTER ordering. This
-- closes both the prior starvation bug and the subtler unordered-LIMIT hole.
create or replace function english.maintenance_saved_enrichment_batch(p_limit integer default 10)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','public','english','auth'
as $$
declare
  v_owner uuid;
  v_owner_count integer;
  v_limit integer:=greatest(1,least(25,coalesce(p_limit,10)));
  v_items jsonb;
begin
  select count(*),max(o.user_id::text)::uuid into v_owner_count,v_owner
  from (select distinct s.user_id from english.saved_items s where s.active) o;
  if v_owner_count=0 then return jsonb_build_object('ok',true,'count',0,'items','[]'::jsonb); end if;
  if v_owner_count<>1 then raise exception 'Saved enrichment maintenance requires exactly one active owner'; end if;

  select coalesce(
    jsonb_agg((to_jsonb(x) - '_priority' - '_queue_at') order by x._priority,x._queue_at,x.created_at asc nulls last),
    '[]'::jsonb
  ) into v_items
  from (
    select
      s.saved_id as "savedId",coalesce(s.word,'') as word,coalesce(s.meaning,'') as meaning,coalesce(s.context,'') as context,
      coalesce(s.origin_question_id,'') as "originQuestionId",coalesce(q.topic,'') as "originTopic",
      coalesce(s.origin_module,'') as "originModule",coalesce(s.source,'') as source,
      coalesce(s.part_of_speech,'') as "partOfSpeech",coalesce(s.synonyms,'') as synonyms,coalesce(s.antonyms,'') as antonyms,
      coalesce(s.example,'') as example,coalesce(s.explanation,'') as explanation,coalesce(s.question,'') as question,
      coalesce(s.option_a,'') as "optionA",coalesce(s.option_b,'') as "optionB",coalesce(s.option_c,'') as "optionC",coalesce(s.option_d,'') as "optionD",
      coalesce(s.correct_option,'') as "correctOption",coalesce(s.gpt_status,'Pending GPT') as "gptStatus",
      coalesce(t.capture_type,'AUTO') as "captureType",
      english.resolve_saved_type_for_enrichment(
        coalesce(t.capture_type,'AUTO'),coalesce(t.learning_intent,'AUTO'),s.word,s.context,coalesce(q.topic,'')
      ) as "resolvedType",
      coalesce(t.learning_intent,'AUTO') as "learningIntent",
      coalesce(t.learning_intent_origin,'LEGACY_UNKNOWN') as "learningIntentOrigin",
      english.resolve_saved_learning_intent_authoritative(
        coalesce(t.learning_intent,'AUTO'),
        s.word,
        english.resolve_saved_type_for_enrichment(
          coalesce(t.capture_type,'AUTO'),coalesce(t.learning_intent,'AUTO'),s.word,s.context,coalesce(q.topic,'')
        )
      ) as "requiredLearningIntent",
      case
        when coalesce(es.state,'')='pending' then 0
        when lower(btrim(coalesce(s.gpt_status,'')))='ready' then 1
        when lower(btrim(coalesce(s.gpt_status,'')))='pending gpt' or btrim(coalesce(s.gpt_status,''))='' then 2
        when lower(btrim(coalesce(s.gpt_status,'')))='needs enrichment' then 3
        else 4
      end as _priority,
      case
        when coalesce(es.state,'')='pending' then coalesce(es.updated_at,s.updated_at,s.created_at,now())
        else coalesce(s.created_at,s.updated_at,now())
      end as _queue_at,
      s.created_at,s.updated_at,s.gpt_updated_at
    from english.saved_items s
    left join english.saved_item_types t on t.user_id=s.user_id and t.saved_id=s.saved_id
    left join english.saved_enrichment_item_state es on es.user_id=s.user_id and es.saved_id=s.saved_id
    left join english.questions q on q.question_id=s.origin_question_id
    where s.active and s.user_id=v_owner
      and coalesce(es.state,'') not in ('processing','failed')
      and not(coalesce(es.state,'')='retrying' and es.next_attempt_at is not null and es.next_attempt_at>now())
      and (
        btrim(coalesce(s.gpt_status,''))=''
        or lower(btrim(coalesce(s.gpt_status,''))) in ('pending gpt','needs enrichment')
        or (lower(btrim(coalesce(s.gpt_status,'')))='needs review'
            and (s.gpt_updated_at is null or coalesce(s.updated_at,s.created_at)>s.gpt_updated_at+interval '1 second'))
        or (lower(btrim(coalesce(s.gpt_status,'')))='ready' and (
          btrim(coalesce(s.meaning,''))='' or btrim(coalesce(s.question,''))='' or
          btrim(coalesce(s.option_a,''))='' or btrim(coalesce(s.option_b,''))='' or
          btrim(coalesce(s.option_c,''))='' or btrim(coalesce(s.option_d,''))='' or
          upper(btrim(coalesce(s.correct_option,''))) not in ('A','B','C','D') or
          btrim(coalesce(s.explanation,''))=''
        ))
      )
    order by _priority asc,_queue_at asc,s.created_at asc nulls last
    limit v_limit
  ) x;

  return jsonb_build_object('ok',true,'count',jsonb_array_length(v_items),'items',v_items);
end;
$$;

create or replace function english.kick_saved_enrichment_pending_if_needed()
returns bigint
language plpgsql
security definer
set search_path to 'pg_catalog','english'
as $$
declare
  v_busy boolean:=false;
  v_pending boolean:=false;
begin
  perform english.reconcile_saved_enrichment_worker_http();

  select coalesce(lease_id is not null and lease_expires_at>now(),false)
  into v_busy
  from english.saved_enrichment_worker_state
  where singleton=true;
  if v_busy then return null; end if;

  -- Self-heal a missing durable row only for fresh Pending GPT items.
  insert into english.saved_enrichment_item_state(
    user_id,saved_id,state,attempt_count,lease_id,last_attempt_at,last_error,
    last_error_at,next_attempt_at,updated_at,last_success_at,last_error_class,
    transient_failure_count
  )
  select s.user_id,s.saved_id,'pending',0,null,null,null,null,null,now(),null,null,0
  from english.saved_items s
  where s.active
    and lower(btrim(coalesce(s.gpt_status,'')))='pending gpt'
    and not exists(
      select 1 from english.saved_enrichment_item_state es
      where es.user_id=s.user_id and es.saved_id=s.saved_id
    )
  on conflict(user_id,saved_id) do nothing;

  select exists(
    select 1
    from english.saved_enrichment_item_state es
    join english.saved_items s
      on s.user_id=es.user_id and s.saved_id=es.saved_id and s.active
    where es.state='pending'
      and lower(btrim(coalesce(s.gpt_status,''))) in ('','pending gpt','needs enrichment')
  ) into v_pending;

  if v_pending then return english.kick_saved_enrichment_worker(1); end if;
  return null;
end;
$$;

-- Named pg_cron schedule: fast watchdog for pending/new work only.
select cron.schedule(
  'english-saved-enrichment-pending-fast',
  '* * * * *',
  'select english.kick_saved_enrichment_pending_if_needed();'
);
