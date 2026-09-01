-- Repair the English concept foundation after an interrupted statement batch.
with src as (
  select q.question_id,
    coalesce(nullif(trim(q.concept_id), ''), 'C_' || md5(lower(trim(coalesce(q.topic,'English') || '|' || coalesce(q.subtopic,q.question_type,'Unclassified') || '|' || coalesce(q.word,''))))) concept_id,
    'F_' || md5(lower(trim(coalesce(q.topic,'English') || '|' || coalesce(q.subtopic,q.question_type,'Unclassified')))) family_id,
    case when nullif(trim(q.concept_id), '') is not null then .95 else .78 end mapping_confidence,
    case when nullif(trim(q.concept_id), '') is not null then 'existing_concept_id' else 'deterministic_metadata' end mapping_method,
    case when nullif(trim(q.concept_id), '') is not null then 'verified' else 'mapped' end review_status
  from english.questions q where coalesce(q.active,true)
)
insert into english.question_concept_mappings(question_id,concept_id,family_id,mapping_confidence,mapping_method,review_status)
select question_id,concept_id,family_id,mapping_confidence,mapping_method,review_status from src
on conflict(question_id) do nothing;

update english.questions q set concept_id=m.concept_id,updated_at=now()
from english.question_concept_mappings m
where m.question_id=q.question_id and (q.concept_id is null or trim(q.concept_id)='');

create or replace function english.recompute_concept_evidence(p_user_id uuid,p_concept_id text) returns void
language plpgsql security definer set search_path=pg_catalog,english as $$
declare r record; score numeric;
begin
 select count(*)::int attempts,count(*) filter(where a.correct is true)::int correct,count(*) filter(where a.correct is false)::int wrong,
 count(distinct a.question_id)::int distinct_questions,count(distinct coalesce(a.module,'practice'))::int distinct_variants,
 count(*) filter(where a.correct is true and a.attempted_at<now()-interval '3 days')::int delayed_successes,
 count(*) filter(where a.correct is false and a.attempted_at>now()-interval '7 days')::int recent_failures,max(a.attempted_at) last_attempt_at
 into r from english.attempts a join english.question_concept_mappings m on m.question_id=a.question_id
 where a.user_id=p_user_id and m.concept_id=p_concept_id;
 score:=greatest(0,least(100,coalesce(r.correct,0)*12+coalesce(r.delayed_successes,0)*8+least(coalesce(r.distinct_questions,0),4)*5-coalesce(r.wrong,0)*14-coalesce(r.recent_failures,0)*10));
 insert into english.concept_evidence(user_id,concept_id,attempts,correct,wrong,distinct_questions,distinct_variants,delayed_successes,recent_failures,confidence_score,coverage_state,last_attempt_at,updated_at)
 values(p_user_id,p_concept_id,coalesce(r.attempts,0),coalesce(r.correct,0),coalesce(r.wrong,0),coalesce(r.distinct_questions,0),coalesce(r.distinct_variants,0),coalesce(r.delayed_successes,0),coalesce(r.recent_failures,0),score,
 case when score>=78 and coalesce(r.delayed_successes,0)>=1 and coalesce(r.distinct_questions,0)>=2 then 'exam_ready' when score>=55 and coalesce(r.distinct_questions,0)>=2 then 'secure' when coalesce(r.attempts,0)>0 and coalesce(r.recent_failures,0)>0 then 'retention_risk' when coalesce(r.attempts,0)>0 then 'seen' else 'unseen' end,r.last_attempt_at,now())
 on conflict(user_id,concept_id) do update set attempts=excluded.attempts,correct=excluded.correct,wrong=excluded.wrong,distinct_questions=excluded.distinct_questions,distinct_variants=excluded.distinct_variants,delayed_successes=excluded.delayed_successes,recent_failures=excluded.recent_failures,confidence_score=excluded.confidence_score,coverage_state=excluded.coverage_state,last_attempt_at=excluded.last_attempt_at,updated_at=now();
end $$;
revoke all on function english.recompute_concept_evidence(uuid,text) from public;

create or replace function english.on_attempt_concept_evidence() returns trigger
language plpgsql security definer set search_path=pg_catalog,english as $$
declare cid text;
begin select m.concept_id into cid from english.question_concept_mappings m where m.question_id=NEW.question_id;
if cid is not null then perform english.recompute_concept_evidence(NEW.user_id,cid); end if; return NEW; end $$;
revoke all on function english.on_attempt_concept_evidence() from public;
drop trigger if exists english_attempt_concept_evidence on english.attempts;
create trigger english_attempt_concept_evidence after insert on english.attempts for each row execute function english.on_attempt_concept_evidence();

do $$ declare u record; c record; begin
 for u in select distinct user_id from english.attempts where user_id is not null loop
  for c in select distinct m.concept_id from english.attempts a join english.question_concept_mappings m on m.question_id=a.question_id where a.user_id=u.user_id loop
   perform english.recompute_concept_evidence(u.user_id,c.concept_id);
  end loop;
 end loop;
end $$;

create or replace function english.english_get_concept_intelligence_summary() returns jsonb
language plpgsql security invoker set search_path=pg_catalog,english as $$
declare uid uuid:=(select auth.uid()); outv jsonb;
begin if uid is null then raise exception 'authentication required'; end if;
select jsonb_build_object('concepts',(select count(*) from english.concepts where active),'mapped_questions',(select count(*) from english.question_concept_mappings),'unresolved_mappings',(select count(*) from english.question_concept_mappings where review_status='unresolved'),'needs_review',(select count(*) from english.question_concept_mappings where review_status='needs_review'),'seen',(select count(*) from english.concept_evidence where user_id=uid and coverage_state='seen'),'secure',(select count(*) from english.concept_evidence where user_id=uid and coverage_state='secure'),'exam_ready',(select count(*) from english.concept_evidence where user_id=uid and coverage_state='exam_ready'),'weak',(select count(*) from english.concept_evidence where user_id=uid and coverage_state in('weak','retention_risk')),'retention_risk',(select count(*) from english.concept_evidence where user_id=uid and coverage_state='retention_risk')) into outv; return outv; end $$;
grant execute on function english.english_get_concept_intelligence_summary() to authenticated;

create or replace function english.english_record_guess(p_question_id text,p_attempt_id text default null) returns jsonb
language plpgsql security invoker set search_path=pg_catalog,english as $$
declare uid uuid:=(select auth.uid()); cid text;
begin if uid is null then raise exception 'authentication required'; end if;
select m.concept_id into cid from english.question_concept_mappings m where m.question_id=p_question_id;
insert into english.learner_confidence_signals(user_id,question_id,attempt_id,signal) values(uid,p_question_id,p_attempt_id,'guessed');
if cid is not null then update english.concept_evidence set guessed=guessed+1,confidence_score=greatest(0,confidence_score-10),coverage_state=case when coverage_state='exam_ready' then 'retention_risk' else coverage_state end,updated_at=now() where user_id=uid and concept_id=cid; end if;
return jsonb_build_object('ok',true,'signal','guessed','concept_id',cid); end $$;
grant execute on function english.english_record_guess(text,text) to authenticated;

create or replace function english.english_get_concept_intelligence_detail(p_kind text default 'all') returns jsonb
language sql security invoker set search_path=pg_catalog,english as $$
select coalesce(jsonb_agg(to_jsonb(x) order by x.priority_score desc,x.confidence_score asc),'[]'::jsonb) from (
select c.concept_id,c.domain,c.skill_family,c.name,c.exam_relevance,c.priority_score,coalesce(e.coverage_state,'unseen') coverage_state,coalesce(e.confidence_score,0) confidence_score,coalesce(e.attempts,0) attempts,coalesce(e.wrong,0) wrong,e.next_review
from english.concepts c left join english.concept_evidence e on e.concept_id=c.concept_id and e.user_id=(select auth.uid())
where c.active and (p_kind='all' or (p_kind='weak' and coalesce(e.coverage_state,'unseen') in('weak','retention_risk')) or (p_kind='retention' and coalesce(e.coverage_state,'unseen')='retention_risk') or (p_kind='coverage' and coalesce(e.coverage_state,'unseen') in('unseen','seen','secure','exam_ready'))) ) x;
$$;
grant execute on function english.english_get_concept_intelligence_detail(text) to authenticated;