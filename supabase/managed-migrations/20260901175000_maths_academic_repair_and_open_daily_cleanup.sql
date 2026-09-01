-- Final Academic / Calculation boundary hardening.
-- 1) Generic repair serves Academic questions only; Calculation remediation lives in Exam Prep Calculation.
-- 2) Archive already-created open Daily sessions contaminated by Calculation without deleting attempts/history.

create or replace function maths._repair_candidate_ids(p_uid uuid,p_count integer default 5,p_reason text default null)
returns text[]
language sql
stable
security definer
set search_path to 'pg_catalog','public','maths'
as $$
with queue as (
  select rq.*
  from maths.repair_queue rq
  where rq.user_id=p_uid
    and rq.status in('open','waiting_confirmation')
    and (rq.due_at<=now() or rq.priority='P0')
    and (p_reason is null or rq.reason=upper(p_reason))
  order by case rq.priority when 'P0' then 1 when 'P1' then 2 when 'P2' then 3 else 4 end,
           rq.priority_score desc,rq.due_at
  limit 30
),
candidates as (
  select q.repair_id,q.priority,q.priority_score,q.question_id source_question,r.question_id,
         row_number() over(partition by q.repair_id order by
           (r.question_id<>coalesce(q.question_id,'')) desc,
           (coalesce(st.mastered,false)=false) desc,
           coalesce(st.attempts,0),
           abs(hashtext(r.question_id||q.repair_id::text))
         ) family_rank
  from queue q
  join maths.question_families f on q.scope_type='family' and f.family_id=q.scope_id and f.active
  join maths.runtime_questions r on r.question_id=f.question_id and r.runtime_active and r.academic_eligible
  left join maths.question_state st on st.user_id=p_uid and st.question_id=r.question_id

  union all

  select q.repair_id,q.priority,q.priority_score,q.question_id,r.question_id,
         row_number() over(partition by q.repair_id order by
           (r.question_id<>coalesce(q.question_id,'')) desc,
           (coalesce(st.mastered,false)=false) desc,
           coalesce(st.attempts,0),
           abs(hashtext(r.question_id||q.repair_id::text))
         )
  from queue q
  join maths.question_concepts c on q.scope_type='concept' and c.concept_id=q.scope_id and c.active
  join maths.runtime_questions r on r.question_id=c.question_id and r.runtime_active and r.academic_eligible
  left join maths.question_state st on st.user_id=p_uid and st.question_id=r.question_id

  union all

  select q.repair_id,q.priority,q.priority_score,q.question_id,r.question_id,1
  from queue q
  join maths.runtime_questions r on q.scope_type='question' and r.question_id=q.scope_id and r.runtime_active and r.academic_eligible
),
ranked as (
  select distinct on(question_id) question_id,
    case priority when 'P0' then 1 when 'P1' then 2 when 'P2' then 3 else 4 end p,
    priority_score,family_rank
  from candidates
  where family_rank<=3
  order by question_id,p,priority_score desc,family_rank
)
select coalesce(array_agg(question_id order by p,priority_score desc,family_rank),array[]::text[])
from (select * from ranked order by p,priority_score desc,family_rank limit greatest(1,least(coalesce(p_count,5),30))) x
$$;

-- Preserve contaminated Daily attempts as historical evidence, but prevent the invalid session from resuming as Academic Daily.
update maths.sessions s
set mode='daily_leak_archived',
    completed=true,
    updated_at=now(),
    params=coalesce(s.params,'{}'::jsonb)||jsonb_build_object(
      'archivedCalculationLeak',true,
      'archivedAt',now()::text,
      'archiveReason','Calculation question leaked through historical repair injection; evidence preserved, Academic Daily regenerated on next start.'
    )
where not s.completed
  and lower(coalesce(s.mode,''))='daily'
  and exists(
    select 1
    from maths.session_questions sq
    join maths.runtime_questions r on r.question_id=sq.question_id
    where sq.session_id=s.session_id
      and (coalesce(r.bank_calculation,false) or coalesce(r.in_calc_set,false) or upper(coalesce(r.practice_bank,''))='CALCULATION_AI')
  );
