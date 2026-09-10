-- Backfill only learner-facing review rationale. No question, answer key, attempt,
-- mastery, routing, or review verdict is changed.
update english.question_quality_reviews qr
set critic=jsonb_set(
  qr.critic,
  '{rationale}',
  to_jsonb(english.explanation_order_neutralized(
    coalesce(qr.critic->>'rationale',''),
    q.option_a,q.option_b,q.option_c,q.option_d
  )),
  true
),
updated_at=now()
from english.questions q
where q.question_id=qr.question_id
  and qr.status='reviewed'
  and qr.critic is not null
  and not english.explanation_is_order_neutral(
    coalesce(qr.critic->>'rationale',''),
    q.option_a,q.option_b,q.option_c,q.option_d
  );
