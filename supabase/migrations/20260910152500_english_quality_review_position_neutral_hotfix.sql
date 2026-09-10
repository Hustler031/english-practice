-- Learner-facing answer-review rationale must never depend on mutable A/B/C/D positions.
-- This is intentionally scoped to quality-review text only; canonical questions, keys,
-- attempts, mastery, routing and verdicts are untouched.

create or replace function english.quality_review_rationale_neutralized(
  p_text text,
  p_a text,
  p_b text,
  p_c text,
  p_d text
)
returns text
language plpgsql
immutable
parallel safe
set search_path to 'pg_catalog','english'
as $$
declare
  v text:=english.explanation_order_neutralized(p_text,p_a,p_b,p_c,p_d);
  qa text:='“'||coalesce(nullif(btrim(p_a),''),'this answer')||'”';
  qb text:='“'||coalesce(nullif(btrim(p_b),''),'this answer')||'”';
  qc text:='“'||coalesce(nullif(btrim(p_c),''),'this answer')||'”';
  qd text:='“'||coalesce(nullif(btrim(p_d),''),'this answer')||'”';
  ra text;
  rb text;
  rc text;
  rd text;
begin
  if coalesce(v,'')='' then return v; end if;
  ra:=replace(qa,E'\\',E'\\\\');
  rb:=replace(qb,E'\\',E'\\\\');
  rc:=replace(qc,E'\\',E'\\\\');
  rd:=replace(qd,E'\\',E'\\\\');

  -- Common critic prose: “In A, …; in C, …”.
  v:=regexp_replace(v,'(^|[^[:alnum:]_])In[[:space:]]+A([^[:alnum:]_]|$)',E'\\1For '||ra||E'\\2','g');
  v:=regexp_replace(v,'(^|[^[:alnum:]_])In[[:space:]]+B([^[:alnum:]_]|$)',E'\\1For '||rb||E'\\2','g');
  v:=regexp_replace(v,'(^|[^[:alnum:]_])In[[:space:]]+C([^[:alnum:]_]|$)',E'\\1For '||rc||E'\\2','g');
  v:=regexp_replace(v,'(^|[^[:alnum:]_])In[[:space:]]+D([^[:alnum:]_]|$)',E'\\1For '||rd||E'\\2','g');
  v:=regexp_replace(v,'(^|[^[:alnum:]_])in[[:space:]]+A([^[:alnum:]_]|$)',E'\\1for '||ra||E'\\2','g');
  v:=regexp_replace(v,'(^|[^[:alnum:]_])in[[:space:]]+B([^[:alnum:]_]|$)',E'\\1for '||rb||E'\\2','g');
  v:=regexp_replace(v,'(^|[^[:alnum:]_])in[[:space:]]+C([^[:alnum:]_]|$)',E'\\1for '||rc||E'\\2','g');
  v:=regexp_replace(v,'(^|[^[:alnum:]_])in[[:space:]]+D([^[:alnum:]_]|$)',E'\\1for '||rd||E'\\2','g');

  -- “supports B”, “rather than A”, and “marked key A” are also position-dependent.
  v:=regexp_replace(v,'(^|[^[:alnum:]_])([Ss]upports?|[Ss]upported|[Ss]upporting)[[:space:]]+A([^[:alnum:]_]|$)',E'\\1\\2 '||ra||E'\\3','g');
  v:=regexp_replace(v,'(^|[^[:alnum:]_])([Ss]upports?|[Ss]upported|[Ss]upporting)[[:space:]]+B([^[:alnum:]_]|$)',E'\\1\\2 '||rb||E'\\3','g');
  v:=regexp_replace(v,'(^|[^[:alnum:]_])([Ss]upports?|[Ss]upported|[Ss]upporting)[[:space:]]+C([^[:alnum:]_]|$)',E'\\1\\2 '||rc||E'\\3','g');
  v:=regexp_replace(v,'(^|[^[:alnum:]_])([Ss]upports?|[Ss]upported|[Ss]upporting)[[:space:]]+D([^[:alnum:]_]|$)',E'\\1\\2 '||rd||E'\\3','g');
  v:=regexp_replace(v,'(^|[^[:alnum:]_])marked[[:space:]]+key[[:space:]]+A([^[:alnum:]_]|$)',E'\\1marked answer '||ra||E'\\2','g');
  v:=regexp_replace(v,'(^|[^[:alnum:]_])marked[[:space:]]+key[[:space:]]+B([^[:alnum:]_]|$)',E'\\1marked answer '||rb||E'\\2','g');
  v:=regexp_replace(v,'(^|[^[:alnum:]_])marked[[:space:]]+key[[:space:]]+C([^[:alnum:]_]|$)',E'\\1marked answer '||rc||E'\\2','g');
  v:=regexp_replace(v,'(^|[^[:alnum:]_])marked[[:space:]]+key[[:space:]]+D([^[:alnum:]_]|$)',E'\\1marked answer '||rd||E'\\2','g');
  v:=regexp_replace(v,'(^|[^[:alnum:]_])rather[[:space:]]+than[[:space:]]+A([^[:alnum:]_]|$)',E'\\1rather than '||ra||E'\\2','g');
  v:=regexp_replace(v,'(^|[^[:alnum:]_])rather[[:space:]]+than[[:space:]]+B([^[:alnum:]_]|$)',E'\\1rather than '||rb||E'\\2','g');
  v:=regexp_replace(v,'(^|[^[:alnum:]_])rather[[:space:]]+than[[:space:]]+C([^[:alnum:]_]|$)',E'\\1rather than '||rc||E'\\2','g');
  v:=regexp_replace(v,'(^|[^[:alnum:]_])rather[[:space:]]+than[[:space:]]+D([^[:alnum:]_]|$)',E'\\1rather than '||rd||E'\\2','g');

  -- “B is the only defensible option” style verdicts.
  v:=regexp_replace(v,'(^|[^[:alnum:]_])A[[:space:]]+is[[:space:]]+the[[:space:]]+only[[:space:]]+(defensible|valid|correct|plausible)([^[:alnum:]_]|$)',E'\\1'||ra||E' is the only \\2\\3','g');
  v:=regexp_replace(v,'(^|[^[:alnum:]_])B[[:space:]]+is[[:space:]]+the[[:space:]]+only[[:space:]]+(defensible|valid|correct|plausible)([^[:alnum:]_]|$)',E'\\1'||rb||E' is the only \\2\\3','g');
  v:=regexp_replace(v,'(^|[^[:alnum:]_])C[[:space:]]+is[[:space:]]+the[[:space:]]+only[[:space:]]+(defensible|valid|correct|plausible)([^[:alnum:]_]|$)',E'\\1'||rc||E' is the only \\2\\3','g');
  v:=regexp_replace(v,'(^|[^[:alnum:]_])D[[:space:]]+is[[:space:]]+the[[:space:]]+only[[:space:]]+(defensible|valid|correct|plausible)([^[:alnum:]_]|$)',E'\\1'||rd||E' is the only \\2\\3','g');

  -- Clean duplicate exact-option echoes left by older positional prose conversions.
  v:=replace(v,qa||', '||qa||',',qa||',');
  v:=replace(v,qb||', '||qb||',',qb||',');
  v:=replace(v,qc||', '||qc||',',qc||',');
  v:=replace(v,qd||', '||qd||',',qd||',');
  v:=replace(v,qa||', '||qa,qa);
  v:=replace(v,qb||', '||qb,qb);
  v:=replace(v,qc||', '||qc,qc);
  v:=replace(v,qd||', '||qd,qd);
  return v;
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

  v_rationale:=english.quality_review_rationale_neutralized(
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

-- Repair previously stored learner-facing review text only.
update english.question_quality_reviews qr
set critic=jsonb_set(
      qr.critic,
      '{rationale}',
      to_jsonb(english.quality_review_rationale_neutralized(
        coalesce(qr.critic->>'rationale',''),q.option_a,q.option_b,q.option_c,q.option_d
      )),
      true
    ),
    updated_at=now()
from english.questions q
where q.question_id=qr.question_id
  and qr.status='reviewed'
  and qr.critic is not null;
