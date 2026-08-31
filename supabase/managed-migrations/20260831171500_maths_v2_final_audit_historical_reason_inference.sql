-- Backfill only derived Maths performance inference, never canonical attempt/result history.
-- Uses the same conservative heuristics as the live attempt trigger.

with classified as (
  select pe.evidence_id,
         case
           when pe.correctness='wrong' and (coalesce(r.in_formula_revision,false) or lower(coalesce(pe.evidence_source,'')) like '%formula%') then 'FOR'
           when pe.correctness='wrong' and (coalesce(r.bank_calculation,false) or coalesce(r.in_calc_set,false) or lower(coalesce(pe.evidence_source,'')) like '%calculation%') then 'CAL'
           when pe.correctness='wrong' and pe.timing_class='wrong_fast' then 'APP'
           when pe.correctness='wrong' and pe.timing_class='wrong_slow' then 'TIME'
           when pe.correctness='correct' and pe.slow_correct then 'TIME'
         end inferred_reason,
         case
           when pe.correctness='wrong' and (coalesce(r.in_formula_revision,false) or lower(coalesce(pe.evidence_source,'')) like '%formula%') then .72
           when pe.correctness='wrong' and (coalesce(r.bank_calculation,false) or coalesce(r.in_calc_set,false) or lower(coalesce(pe.evidence_source,'')) like '%calculation%') then .78
           when pe.correctness='wrong' and pe.timing_class='wrong_fast' then .62
           when pe.correctness='wrong' and pe.timing_class='wrong_slow' then .58
           when pe.correctness='correct' and pe.slow_correct then .72
         end confidence
  from maths.performance_evidence pe
  left join maths.runtime_questions r on r.question_id=pe.question_id
  where pe.inferred_reason is null and pe.user_confirmed_reason is null
), updated as (
  update maths.performance_evidence pe
  set inferred_reason=c.inferred_reason,
      inference_confidence=c.confidence,
      metadata=coalesce(pe.metadata,'{}'::jsonb)||jsonb_build_object('inferenceBackfill','2026-08-31-final-audit'),
      updated_at=now()
  from classified c
  where pe.evidence_id=c.evidence_id and c.inferred_reason is not null
  returning pe.evidence_id
)
select count(*) from updated;

update maths.repair_queue rq
set reason=pe.final_reason,
    metadata=coalesce(rq.metadata,'{}'::jsonb)||jsonb_build_object('diagnosisNeeded',false,'reasonSource','derived_timing_inference'),
    updated_at=now()
from maths.performance_evidence pe
where rq.source_evidence_id=pe.evidence_id
  and rq.reason is null
  and pe.final_reason is not null
  and rq.status in('open','in_progress','waiting_confirmation');
