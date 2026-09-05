-- My Saved must practice the exact validated enrichment the learner sees in Manage.
-- A same-word canonical question may be a useful concept variant, but it must not
-- silently replace the saved enrichment payload. Create an owner-scoped immutable
-- variant when no exact learner-visible payload already exists, and safely relink
-- legacy mismatches without rewriting historical attempts or canonical questions.

create or replace function english.ensure_saved_enrichment_exact_question(
  p_user_id uuid,
  p_saved_id text
)
returns text
language plpgsql
security definer
set search_path to 'pg_catalog','public','english','auth'
as $function$
declare
  s english.saved_items%rowtype;
  t english.saved_item_types%rowtype;
  v_type text;
  v_topic text;
  v_qtype text;
  v_cat text;
  v_question text;
  v_a text;
  v_b text;
  v_c text;
  v_d text;
  v_correct text;
  v_expl text;
  v_existing text;
  v_digest text;
  v_qid text;
  v_concept_id text;
  v_mapping_confidence numeric;
begin
  if p_user_id is null then
    raise exception 'User is required';
  end if;

  select * into s
  from english.saved_items
  where user_id=p_user_id
    and saved_id=btrim(p_saved_id)
    and active;

  if not found then
    raise exception 'Saved item not found';
  end if;

  if lower(btrim(coalesce(s.gpt_status,'')))<>'ready' then
    raise exception 'GPT review is not ready yet';
  end if;

  v_question:=nullif(btrim(coalesce(s.question,'')),'');
  v_a:=nullif(btrim(coalesce(s.option_a,'')),'');
  v_b:=nullif(btrim(coalesce(s.option_b,'')),'');
  v_c:=nullif(btrim(coalesce(s.option_c,'')),'');
  v_d:=nullif(btrim(coalesce(s.option_d,'')),'');
  v_correct:=upper(btrim(coalesce(s.correct_option,'')));
  v_expl:=nullif(btrim(coalesce(s.explanation,'')),'');

  if nullif(btrim(coalesce(s.word,'')),'') is null
     or nullif(btrim(coalesce(s.meaning,'')),'') is null
     or v_question is null
     or v_a is null
     or v_b is null
     or v_c is null
     or v_d is null
     or v_correct not in ('A','B','C','D')
     or v_expl is null then
    raise exception 'Ready enrichment is incomplete';
  end if;

  select * into t
  from english.saved_item_types
  where user_id=p_user_id and saved_id=s.saved_id;

  v_type:=english.resolve_saved_type(
    coalesce(t.capture_type,'AUTO'),
    s.word,s.meaning,s.context,s.part_of_speech,s.question,s.explanation
  );
  v_topic:=case v_type
    when 'SM' then 'Spelling Mistakes'
    when 'OWS' then 'One Word Substitution'
    when 'PV' then 'Phrasal Verbs'
    when 'IP' then 'Idioms & Phrases'
    when 'CU' then 'Grammar / Usage'
    else 'Vocabulary'
  end;
  v_qtype:=case v_type
    when 'SM' then 'Spelling'
    when 'OWS' then 'One Word Substitution'
    when 'CU' then 'Concept / Usage'
    else 'Meaning'
  end;
  v_cat:=english.canonical_category(v_topic);

  -- Exact learner-visible payload reuse is safe. Same word alone is not enough.
  select q.question_id into v_existing
  from english.questions q
  left join english.question_origins o on o.question_id=q.question_id
  where q.active
    and english.question_visible_to_user(p_user_id,q.question_id)
    and english.canonical_category(q.topic)=v_cat
    and lower(btrim(coalesce(q.word,'')))=lower(btrim(s.word))
    and btrim(coalesce(q.question,''))=v_question
    and btrim(coalesce(q.option_a,''))=v_a
    and btrim(coalesce(q.option_b,''))=v_b
    and btrim(coalesce(q.option_c,''))=v_c
    and btrim(coalesce(q.option_d,''))=v_d
    and upper(btrim(coalesce(q.correct,'')))=v_correct
    and btrim(coalesce(q.explanation,''))=v_expl
  order by
    case when coalesce(o.origin_kind,'core')='core' then 0
         when o.owner_user_id=p_user_id then 1
         else 2 end,
    q.created_at,
    q.question_id
  limit 1;

  if v_existing is not null then
    update english.saved_items
    set status='Added',practice_question_id=v_existing,updated_at=now()
    where user_id=p_user_id and saved_id=s.saved_id;

    insert into english.saved_item_types(user_id,saved_id,capture_type,resolved_type,updated_at)
    values(p_user_id,s.saved_id,coalesce(t.capture_type,'AUTO'),v_type,now())
    on conflict(user_id,saved_id) do update
      set resolved_type=excluded.resolved_type,updated_at=excluded.updated_at;

    return v_existing;
  end if;

  select scm.concept_id,scm.mapping_confidence
  into v_concept_id,v_mapping_confidence
  from english.saved_concept_mappings scm
  where scm.user_id=p_user_id and scm.saved_id=s.saved_id;

  -- Include saved identity and the validated payload in the ID. A later enrichment
  -- revision gets a new canonical variant rather than silently mutating an old one.
  v_digest:=upper(substr(md5(concat_ws('|',
    p_user_id::text,
    s.saved_id,
    v_topic,
    btrim(s.word),
    v_question,
    v_a,v_b,v_c,v_d,v_correct,v_expl
  )),1,20));
  v_qid:='MYWORD_EXACT_'||v_digest;

  insert into english.questions(
    question_id,topic,word,question,option_a,option_b,option_c,option_d,
    correct,explanation,subtopic,question_type,source_file,source_page,
    concept_id,difficulty,source_id,learning_status,content_status,seen_count,
    exam_relevance,tip,usage_note,active,created_at,updated_at
  ) values(
    v_qid,v_topic,s.word,v_question,v_a,v_b,v_c,v_d,
    v_correct,v_expl,'My Saved Words',v_qtype,'My Saved Words','',
    coalesce(v_concept_id,'MYWORD_'||v_digest),'Medium','MY_SAVED_WORDS',
    'New','Active',0,'User-saved '||v_type,
    case when nullif(btrim(s.synonyms),'') is not null
         then 'Recall with: '||s.synonyms
         else 'Captured during practice for deliberate revision.' end,
    coalesce(nullif(btrim(s.example),''),s.context),true,now(),now()
  ) on conflict(question_id) do nothing;

  -- A hash collision must never relink a learner to different content.
  if not exists(
    select 1 from english.questions q
    where q.question_id=v_qid
      and btrim(coalesce(q.question,''))=v_question
      and btrim(coalesce(q.option_a,''))=v_a
      and btrim(coalesce(q.option_b,''))=v_b
      and btrim(coalesce(q.option_c,''))=v_c
      and btrim(coalesce(q.option_d,''))=v_d
      and upper(btrim(coalesce(q.correct,'')))=v_correct
      and btrim(coalesce(q.explanation,''))=v_expl
  ) then
    raise exception 'Saved enrichment question identity collision';
  end if;

  insert into english.question_origins(
    question_id,origin_kind,origin_ref,owner_user_id,created_at
  ) values(
    v_qid,'saved_generated',s.saved_id,p_user_id,now()
  )
  on conflict(question_id) do update
    set origin_kind='saved_generated',
        origin_ref=excluded.origin_ref,
        owner_user_id=excluded.owner_user_id
    where english.question_origins.owner_user_id is null
       or english.question_origins.owner_user_id=p_user_id;

  -- Preserve concept identity immediately when Saved semantic mapping is known.
  if v_concept_id is not null then
    insert into english.question_concept_mappings(
      question_id,concept_id,mapping_confidence,mapping_method,
      review_status,relation_type,created_at,updated_at
    ) values(
      v_qid,v_concept_id,coalesce(v_mapping_confidence,0.90),
      'saved_exact_enrichment','mapped','variant',now(),now()
    )
    on conflict(question_id) do nothing;
  end if;

  update english.saved_items
  set status='Added',practice_question_id=v_qid,updated_at=now()
  where user_id=p_user_id and saved_id=s.saved_id;

  insert into english.saved_item_types(user_id,saved_id,capture_type,resolved_type,updated_at)
  values(p_user_id,s.saved_id,coalesce(t.capture_type,'AUTO'),v_type,now())
  on conflict(user_id,saved_id) do update
    set resolved_type=excluded.resolved_type,updated_at=excluded.updated_at;

  return v_qid;
end
$function$;

revoke execute on function english.ensure_saved_enrichment_exact_question(uuid,text) from public,anon,authenticated;
grant execute on function english.ensure_saved_enrichment_exact_question(uuid,text) to service_role;

create or replace function public.english_promote_saved_item(p_saved_id text)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','public','english','auth'
as $function$
declare
  uid uuid:=auth.uid();
  s english.saved_items%rowtype;
  t english.saved_item_types%rowtype;
  v_qid text;
  v_origin_kind text;
  v_type text;
begin
  if uid is null then raise exception 'Authentication required'; end if;

  select * into s
  from english.saved_items
  where saved_id=btrim(p_saved_id) and user_id=uid and active;
  if not found then raise exception 'Saved item not found'; end if;

  v_qid:=english.ensure_saved_enrichment_exact_question(uid,s.saved_id);

  select * into t
  from english.saved_item_types
  where user_id=uid and saved_id=s.saved_id;
  v_type:=coalesce(t.resolved_type,english.resolve_saved_type(
    coalesce(t.capture_type,'AUTO'),s.word,s.meaning,s.context,
    s.part_of_speech,s.question,s.explanation
  ));

  select coalesce(o.origin_kind,'core') into v_origin_kind
  from english.questions q
  left join english.question_origins o on o.question_id=q.question_id
  where q.question_id=v_qid;

  return jsonb_build_object(
    'ok',true,
    'question_id',v_qid,
    'linked',coalesce(v_origin_kind,'core')<>'saved_generated',
    'resolved_type',v_type
  );
end
$function$;

revoke execute on function public.english_promote_saved_item(text) from public,anon;
grant execute on function public.english_promote_saved_item(text) to authenticated,service_role;

-- One-time repair: relink only complete Ready saved items whose current practice
-- payload differs. Historical attempts remain untouched on their original question.
do $repair$
declare
  r record;
begin
  for r in
    select s.user_id,s.saved_id
    from english.saved_items s
    join english.questions q on q.question_id=s.practice_question_id
    where s.active
      and lower(btrim(coalesce(s.gpt_status,'')))='ready'
      and btrim(coalesce(s.meaning,''))<>''
      and btrim(coalesce(s.question,''))<>''
      and btrim(coalesce(s.option_a,''))<>''
      and btrim(coalesce(s.option_b,''))<>''
      and btrim(coalesce(s.option_c,''))<>''
      and btrim(coalesce(s.option_d,''))<>''
      and upper(btrim(coalesce(s.correct_option,''))) in ('A','B','C','D')
      and btrim(coalesce(s.explanation,''))<>''
      and (
        btrim(coalesce(s.question,''))<>btrim(coalesce(q.question,''))
        or btrim(coalesce(s.option_a,''))<>btrim(coalesce(q.option_a,''))
        or btrim(coalesce(s.option_b,''))<>btrim(coalesce(q.option_b,''))
        or btrim(coalesce(s.option_c,''))<>btrim(coalesce(q.option_c,''))
        or btrim(coalesce(s.option_d,''))<>btrim(coalesce(q.option_d,''))
        or upper(btrim(coalesce(s.correct_option,'')))<>upper(btrim(coalesce(q.correct,'')))
        or btrim(coalesce(s.explanation,''))<>btrim(coalesce(q.explanation,''))
      )
  loop
    perform english.ensure_saved_enrichment_exact_question(r.user_id,r.saved_id);
  end loop;
end
$repair$;
