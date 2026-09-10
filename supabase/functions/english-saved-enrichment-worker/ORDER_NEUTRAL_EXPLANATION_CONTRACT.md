# My Saved explanation order-neutral contract

Answer options are shuffled at runtime. Learner-facing explanations must therefore be independent of option position.

Required behavior:
- Explain all four choices using their actual answer text or term.
- Never identify a choice as A/B/C/D, 1/2/3/4, first/second/third/fourth option, `Correct: B`, `B is correct`, or equivalent positional notation.
- Deterministic validation rejects positional explanation references before publish.
- The database write boundary remains the final global enforcement layer.

This contract changes explanation wording only; it does not change routing, answer keys, mastery, attempts, or Daily Focus membership.
