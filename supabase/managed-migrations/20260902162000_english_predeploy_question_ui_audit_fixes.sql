-- Final pre-deployment audit fixes for English V2.
-- Keeps the existing Targeted session architecture intact while exposing a due-only learner route,
-- and keeps related-practice bank-first without serving an unproven/trivial alternate.

create or replace function public.english_get_targeted_due_session(
  p_count integer default 15,
  p_session_nonce text default null
) returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','public','english','auth'
as $$
declare
  uid uuid:=auth.uid();
  n integer:=greatest(1,least(30,coalesce(p_count,15)));
  base jsonb;
  outv jsonb;
begin
  if uid is null then raise exception 'Authentication required'; end if;
  base:=public.english_get_targeted_session(30,null,null,p_session_nonce);
  select coalesce(jsonb_agg(x.item order by x.ord),'[]'::jsonb)
  into outv
  from (
    select e.item,e.ord
    from jsonb_array_elements(coalesce(base,'[]'::jsonb)) with ordinality e(item,ord)
    where e.item->>'targetedKind'='confusion'
       or nullif(e.item->>'conceptNextReview','') is null
       or (e.item->>'conceptNextReview')::timestamptz<=now()
    order by e.ord
    limit n
  ) x;
  return coalesce(outv,'[]'::jsonb);
end $$;
revoke all on function public.english_get_targeted_due_session(integer,text) from public,anon;
grant execute on function public.english_get_targeted_due_session(integer,text) to authenticated,service_role;

create or replace function public.english_request_related_practice(p_question_id text,p_note text default null)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','public','english','auth'
as $$
declare
  uid uuid:=(select auth.uid());
  cid text;
  v_anchor text;
  v_bank text;
  v_job uuid;
  v_existing english.targeted_transfer_jobs%rowtype;
  v_terms jsonb;
  v_note text:=nullif(trim(coalesce(p_note,'')),'');
begin
  if uid is null then raise exception 'authentication required'; end if;
  if v_note is not null and char_length(v_note)>600 then raise exception 'related-practice note must be at most 600 characters'; end if;

  select m.concept_id,nullif(trim(q.word),'') into cid,v_anchor
  from english.questions q
  join english.question_concept_mappings m on m.question_id=q.question_id
  where q.question_id=p_question_id and q.active and english.question_visible_to_user(uid,q.question_id);
  if cid is null then raise exception 'question concept is unavailable'; end if;

  v_terms:=english.confusable_terms_for_concept(cid,8);
  if v_anchor is not null and not coalesce(v_terms @> jsonb_build_array(v_anchor),false) then
    v_terms:=jsonb_build_array(v_anchor)||coalesce(v_terms,'[]'::jsonb);
  end if;

  -- Bank-first remains mandatory, but an unknown Medium/easy-looking alternate is not automatically
  -- treated as suitable. Reuse only a genuinely hard bank item or one with observed learner evidence.
  select q2.question_id into v_bank
  from english.questions q2
  join english.question_concept_mappings m2 on m2.question_id=q2.question_id
  left join english.question_quality_metrics qm on qm.user_id=uid and qm.question_id=q2.question_id
  where m2.concept_id=cid
    and q2.question_id<>p_question_id
    and q2.active
    and english.question_visible_to_user(uid,q2.question_id)
    and upper(coalesce(q2.correct,'')) in ('A','B','C','D')
    and not coalesce(qm.too_easy,false)
    and (
      lower(trim(coalesce(q2.difficulty,''))) in ('hard','difficult','advanced')
      or (coalesce(qm.attempts,0)>=2 and coalesce(qm.observed_difficulty,0)>=0.35)
    )
  order by
    case when lower(trim(coalesce(q2.difficulty,''))) in ('hard','difficult','advanced') then 0 else 1 end,
    coalesce(qm.observed_difficulty,0.5) desc,
    q2.question_id
  limit 1;

  if v_bank is not null then
    perform english.route_to_targeted(uid,v_bank,'Related Practice','Learner explicitly requested related/confusable practice; suitable existing bank item reused first');
    update english.learning_route_state
    set metadata=coalesce(metadata,'{}'::jsonb)||jsonb_build_object(
      'targeted_kind','transfer_check','explicit_related_practice',true,
      'source_question_id',p_question_id,'request_note',v_note,'confusable_terms',v_terms
    ),updated_at=now()
    where user_id=uid and question_id=v_bank;
    return jsonb_build_object('ok',true,'status','ready','source','bank_first','questionId',v_bank);
  end if;

  select * into v_existing
  from english.targeted_transfer_jobs
  where user_id=uid and concept_id=cid and source_question_id=p_question_id;

  if found then
    if v_existing.status='done'
       and v_existing.generated_question_id is not null
       and coalesce((v_existing.metadata->>'explicitRelatedPractice')::boolean,false) then
      perform english.route_to_targeted(uid,v_existing.generated_question_id,'Related Practice','Existing validated related-practice question reused');
      return jsonb_build_object('ok',true,'status','ready','source','generated_existing','questionId',v_existing.generated_question_id);
    end if;

    if v_existing.status='done' and not coalesce((v_existing.metadata->>'explicitRelatedPractice')::boolean,false) then
      -- The one-row legacy transfer job was created for another intent. Re-queue that job for this explicit
      -- request rather than silently serving a transfer that was never checked as a confusable-word item.
      update english.targeted_transfer_jobs
      set reason='Explicit related/confusable practice requested',status='queued',attempts=0,
        generated_question_id=null,processed_at=null,next_attempt_at=now(),last_error=null,
        metadata=coalesce(metadata,'{}'::jsonb)||jsonb_build_object(
          'explicitRelatedPractice',true,'requestNote',v_note,'confusableTerms',v_terms,'requestedAt',now()
        ),updated_at=now()
      where job_id=v_existing.job_id
      returning job_id into v_job;
    else
      update english.targeted_transfer_jobs
      set reason='Explicit related/confusable practice requested',
        metadata=coalesce(metadata,'{}'::jsonb)||jsonb_build_object(
          'explicitRelatedPractice',true,'requestNote',v_note,'confusableTerms',v_terms,'requestedAt',now()
        ),
        status=case when status='failed' then 'queued' else status end,
        attempts=case when status='failed' then 0 else attempts end,
        next_attempt_at=case when status='failed' then now() else next_attempt_at end,
        last_error=case when status='failed' then null else last_error end,
        updated_at=now()
      where job_id=v_existing.job_id
      returning job_id into v_job;
    end if;
  else
    insert into english.targeted_transfer_jobs(
      user_id,concept_id,source_question_id,related_term,reason,status,metadata,next_attempt_at
    ) values(
      uid,cid,p_question_id,null,'Explicit related/confusable practice requested','queued',
      jsonb_build_object('explicitRelatedPractice',true,'requestNote',v_note,'confusableTerms',v_terms,'requestedAt',now()),now()
    ) returning job_id into v_job;
  end if;

  return jsonb_build_object('ok',true,'status','queued','source','generation_queue','jobId',v_job);
end $$;
revoke all on function public.english_request_related_practice(text,text) from public,anon;
grant execute on function public.english_request_related_practice(text,text) to authenticated,service_role;
