# Final validation addendum — PDF vocabulary ingest

After the production one-time PDF Vocabulary ingest and audit packaging, the existing `Validate English V2 Web` job for the exact application baseline SHA `97ee6246521be7ea4429e201063a78aee126ee0c` was manually re-run without modifying application code.

Fresh rerun result: **SUCCESS**.

The rerun passed all substantive steps:

- dependency installation;
- English fresh-session migration syntax;
- question revision migration behavior;
- English V2 fresh-session and mastery contracts;
- existing English reliability and learning contracts;
- shared GK contracts;
- Maths source boundary and contracts;
- TypeScript (`npm run typecheck`);
- production build (`npm run build`).

Ingest-specific post-write production assertions separately passed: 131 questions, 131 active concepts, 131 primary mappings, Vocabulary Bank Coverage 403 → 534 (+131), and zero seeded learner evidence/history in the checked learner-state surfaces.

No deployment or merge was performed by this audit branch/PR.
