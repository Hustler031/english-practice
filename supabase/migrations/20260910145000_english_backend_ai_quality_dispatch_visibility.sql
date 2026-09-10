-- Route learner answer doubts to the dedicated revision/quality worker, make the
-- dispatch immediate-but-best-effort, and expose reviewed rationale to Learning Insights.
-- Existing canonical questions are never changed by an answer review.

create or replace function english.kick_revision_worker(p_limit integer default 1)
returns bigint
language plpgsql
security definer
set search_path to 'pg_catalog','english','net'
as $$
declare
  v_token text;
  req bigint;
  has_revision boolean:=false;
  has_quality boolean:=false;
begin
  perform english.reconcile_context_worker_http();

  update english.question_revision_proposals
  set status='queued',next_attempt_at=now(),last_error='stale dedicated revision processing recovered',updated_at=now()
  where status='processing' and claimed_at<now()-interval '5 minutes' and attempts<3;
  update english.question_revision_proposals
  set status='failed',next_attempt_at=null,last_error=coalesce(last_error,'background revision retries exhausted'),updated_at=now()
  where status='processing' and claimed_at<now()-interval '5 minutes' and attempts>=3;

  update english.question_quality_reviews
  set status='queued',next_attempt_at=now(),last_error='stale dedicated answer review recovered',updated_at=now()
  where status='processing' and claimed_at<now()-interval '5 minutes' and attempts<3;
  update english.question_quality_reviews
  set status='failed',next_attempt_at=null,last_error=coalesce(last_error,'answer review retries exhausted'),updated_at=now()
  where status='processing' and claimed_at<now()-interval '5 minutes' and attempts>=3;

  select exists(
    select 1 from english.question_revision_proposals
    where status='queued' and attempts<3 and (next_attempt_at is null or next_attempt_at<=now())
  ) into has_revision;
  select exists(
    select 1 from english.question_quality_reviews
    where status='queued' and attempts<3 and (next_attempt_at is null or next_attempt_at<=now())
  ) into has_quality;

  if not has_revision and not has_quality then return 0; end if;

  select token into v_token
  from english.context_ai_runtime_guard
  where singleton=true;
  if v_token is null then raise exception 'context runtime guard missing'; end if;

  select net.http_post(
    url:='https://hytehindbmjdwcfptsic.supabase.co/functions/v1/english-revision-worker',
    body:=jsonb_build_object(
      'revisionLimit',greatest(1,least(1,coalesce(p_limit,1))),
      'reviewLimit',1
    ),
    params:='{}'::jsonb,
    headers:=jsonb_build_object('Content-Type','application/json','x-english-context-token',v_token),
    timeout_milliseconds:=65000
  ) into req;

  insert into english.context_worker_requests(request_id,lane,requested_at)
  values(req,'revision_quality_dedicated',now())
  on conflict(request_id) do nothing;
  return req;
end
$$;

create or replace function public.english_request_question_quality_review(p_question_id text, p_note text default null)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','public','english','auth'
as $$
declare
  uid uuid:=(select auth.uid());
  v_id uuid;
  v_note text:=nullif(trim(coalesce(p_note,'')),'');
begin
  if uid is null then raise exception 'authentication required'; end if;
  if not exists(
    select 1 from english.questions q
    where q.question_id=p_question_id and q.active and english.question_visible_to_user(uid,q.question_id)
  ) then raise exception 'question not found'; end if;
  if v_note is not null and char_length(v_note)>600 then raise exception 'review note must be at most 600 characters'; end if;

  select review_id into v_id
  from english.question_quality_reviews
  where user_id=uid and question_id=p_question_id and status in ('queued','processing')
  order by created_at desc limit 1;

  if v_id is not null then
    update english.question_quality_reviews
    set note=coalesce(v_note,note),updated_at=now()
    where review_id=v_id;
    begin perform english.kick_revision_worker(1); exception when others then null; end;
    return jsonb_build_object('ok',true,'reviewId',v_id,'status','queued','kind','canonical_review');
  end if;

  insert into english.question_quality_reviews(user_id,question_id,reason,note,status,next_attempt_at)
  values(uid,p_question_id,'correct_answer_doubtful',v_note,'queued',now())
  returning review_id into v_id;

  -- Immediate dispatch is best-effort; the existing one-minute cron remains the safety net.
  begin perform english.kick_revision_worker(1); exception when others then null; end;
  return jsonb_build_object('ok',true,'reviewId',v_id,'status','queued','kind','canonical_review');
end
$$;

create or replace function public.english_request_question_revision(
  p_question_id text,
  p_feedback_reason text,
  p_feedback_note text default null
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','public','english','auth'
as $$
declare
  uid uuid:=(select auth.uid());
  q english.questions%rowtype;
  v_reason text:=lower(trim(coalesce(p_feedback_reason,'')));
  v_note text:=nullif(trim(coalesce(p_feedback_note,'')),'');
  v_version integer;
  v_base_version integer:=0;
  v_base jsonb;
  v_id uuid;
begin
  if uid is null then raise exception 'authentication required'; end if;
  if v_reason='correct_answer_doubtful' then
    return public.english_request_question_quality_review(p_question_id,v_note);
  end if;

  select * into q from english.questions where question_id=p_question_id and active;
  if not found or not english.question_visible_to_user(uid,p_question_id) then raise exception 'question not found'; end if;
  if upper(coalesce(q.correct,'')) not in ('A','B','C','D') then raise exception 'question is not eligible for revision'; end if;
  if v_reason not in ('options_too_obvious','distractors_unrelated','explanation_weak','custom') then raise exception 'invalid improvement reason'; end if;
  if v_note is not null and char_length(v_note)>600 then raise exception 'feedback note must be at most 600 characters'; end if;
  if v_reason='custom' and coalesce(char_length(v_note),0)<3 then raise exception 'write a short improvement note'; end if;

  perform pg_advisory_xact_lock(hashtextextended(uid::text||'|'||p_question_id,0));
  select r.proposal_version,p.proposed_payload into v_base_version,v_base
  from english.user_question_revisions r
  join english.question_revision_proposals p on p.proposal_id=r.proposal_id
  where r.user_id=uid and r.question_id=p_question_id;

  if v_base is null then
    v_base:=jsonb_build_object(
      'question',q.question,'optionA',q.option_a,'optionB',q.option_b,'optionC',q.option_c,'optionD',q.option_d,
      'correctKey',upper(q.correct),'explanation',coalesce(q.explanation,''),'questionType',coalesce(q.question_type,''),
      'difficulty',coalesce(q.difficulty,''),'word',coalesce(q.word,'')
    );
    v_base_version:=0;
  end if;

  update english.question_revision_proposals
  set status='superseded',superseded_at=now(),updated_at=now()
  where user_id=uid and question_id=p_question_id and status in ('queued','processing','ready');

  select coalesce(max(proposal_version),0)+1 into v_version
  from english.question_revision_proposals
  where user_id=uid and question_id=p_question_id;

  insert into english.question_revision_proposals(
    user_id,question_id,proposal_version,base_version,feedback_reason,feedback_note,status,base_payload,next_attempt_at
  ) values(uid,p_question_id,v_version,v_base_version,v_reason,v_note,'queued',v_base,now())
  returning proposal_id into v_id;

  -- Explanation-only requests use the existing safe revision contract: same stem/options/key,
  -- rewritten explanation, independent critic, then learner preview before use.
  begin perform english.kick_revision_worker(1); exception when others then null; end;
  return jsonb_build_object('ok',true,'kind','revision','proposalId',v_id,'questionId',p_question_id,'version',v_version,'status','queued');
end
$$;

create or replace function english.apply_question_quality_review_result(
  p_token text,
  p_review_id uuid,
  p_critic jsonb,
  p_model text default 'gpt-5.6-luna',
  p_usage jsonb default '{}'::jsonb
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','english'
as $$
declare
  r english.question_quality_reviews%rowtype;
  q english.questions%rowtype;
  v_verdict text;
  v_conf numeric;
  v_critic jsonb;
  v_rationale text;
  v_concept_id text;
begin
  if not english.context_worker_authorized(p_token) then raise exception 'context worker unauthorized'; end if;
  select * into r from english.question_quality_reviews where review_id=p_review_id for update;
  if not found then raise exception 'quality review not found'; end if;
  if r.status='reviewed' then return jsonb_build_object('ok',true,'alreadyReviewed',true,'verdict',r.verdict); end if;
  if r.status<>'processing' then raise exception 'quality review is not claimed'; end if;

  v_verdict:=lower(trim(coalesce(p_critic->>'verdict','')));
  v_conf:=coalesce((p_critic->>'confidence')::numeric,0);
  if v_verdict not in ('valid','issue_suspected') or v_conf<0.70 then raise exception 'quality review critic result is insufficient'; end if;

  select * into q from english.questions where question_id=r.question_id;
  if not found then raise exception 'review question not found'; end if;
  select concept_id into v_concept_id from english.question_concept_mappings where question_id=r.question_id limit 1;

  -- Review rationale is learner-facing, so make it robust to runtime option shuffling too.
  v_rationale:=english.explanation_order_neutralized(
    coalesce(p_critic->>'rationale',''),q.option_a,q.option_b,q.option_c,q.option_d
  );
  v_critic:=coalesce(p_critic,'{}'::jsonb)
    || jsonb_build_object('rationale',v_rationale,'model',p_model,'usage',coalesce(p_usage,'{}'::jsonb));

  update english.question_quality_reviews
  set status='reviewed',verdict=v_verdict,critic=v_critic,reviewed_at=now(),last_error=null,updated_at=now()
  where review_id=p_review_id;

  begin
    perform english.log_learning_activity(
      r.user_id,
      case when v_verdict='valid' then 'quality_review_valid' else 'quality_review_issue' end,
      'Answer doubt reviewed',
      nullif(v_rationale,''),
      r.question_id,
      v_concept_id,
      null,
      null,
      jsonb_build_object('reviewId',p_review_id,'verdict',v_verdict,'confidence',v_conf,'model',p_model),
      now()
    );
  exception when others then null;
  end;

  return jsonb_build_object('ok',true,'reviewId',p_review_id,'status','reviewed','verdict',v_verdict);
end
$$;

create or replace function public.english_get_question_quality_updates(p_limit integer default 20)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'pg_catalog','public','english','auth'
as $$
declare
  uid uuid:=auth.uid();
  v_limit integer:=greatest(5,least(40,coalesce(p_limit,20)));
  v_items jsonb:='[]'::jsonb;
  v_summary jsonb:='{}'::jsonb;
begin
  if uid is null then raise exception 'authentication required'; end if;

  with recent as (
    select qr.*,q.word,q.topic,q.question,q.option_a,q.option_b,q.option_c,q.option_d,q.correct,
      coalesce(nullif(btrim(q.word),''),nullif(left(btrim(q.question),96),''),'English question') display_name
    from english.question_quality_reviews qr
    join english.questions q on q.question_id=qr.question_id
    where qr.user_id=uid
    order by qr.created_at desc
    limit v_limit
  )
  select coalesce(jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
    'reviewId',review_id,
    'questionId',question_id,
    'displayName',display_name,
    'topic',coalesce(nullif(btrim(topic),''),'English'),
    'learnerNote',nullif(left(coalesce(note,''),600),''),
    'status',status,
    'verdict',verdict,
    'rationale',case when status='reviewed' then nullif(english.explanation_order_neutralized(coalesce(critic->>'rationale',''),option_a,option_b,option_c,option_d),'') else null end,
    'confidence',case when status='reviewed' then critic->'confidence' else null end,
    'markedAnswer',case upper(coalesce(correct,'')) when 'A' then option_a when 'B' then option_b when 'C' then option_c when 'D' then option_d else null end,
    'recommendedAnswer',case upper(coalesce(critic->>'recommendedCorrectKey','')) when 'A' then option_a when 'B' then option_b when 'C' then option_c when 'D' then option_d else null end,
    'createdAt',created_at,
    'reviewedAt',reviewed_at
  )) order by created_at desc),'[]'::jsonb) into v_items
  from recent;

  select jsonb_build_object(
    'total',count(*),
    'pending',count(*) filter(where status in ('queued','processing')),
    'reviewed',count(*) filter(where status='reviewed'),
    'valid',count(*) filter(where status='reviewed' and verdict='valid'),
    'issues',count(*) filter(where status='reviewed' and verdict='issue_suspected'),
    'failed',count(*) filter(where status='failed')
  ) into v_summary
  from english.question_quality_reviews
  where user_id=uid;

  return jsonb_build_object('ok',true,'summary',v_summary,'items',v_items);
end
$$;

revoke all on function public.english_get_question_quality_updates(integer) from public,anon;
grant execute on function public.english_get_question_quality_updates(integer) to authenticated;
