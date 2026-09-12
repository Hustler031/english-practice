# ENGLISH V2 — PDF VOCABULARY ONE-TIME INGEST FINAL AUDIT REPORT

**Status:** COMPLETE  
**Date:** 2026-09-05  
**Repository:** `Hustler031/english-practice`  
**Production data platform:** Supabase  
**Audit branch:** `english-pdf-vocabulary-ingest-20260905`  
**Application baseline SHA:** `97ee6246521be7ea4429e201063a78aee126ee0c`  
**Audit PR:** #124 — `Audit PDF vocabulary one-time ingest`

## 1. Source reconciliation

Source PDF: `2024-01-09-0.2589246185826186(2).pdf`  
Title: `Samundramanthan Of Vocabulary / English With Rani Ma'am`

- Pages audited: **22 / 22**
- Numbered primary entries: **200 / 200**
- Headword forms: **201**  
  - Entry 18 contains two headword forms: PERTINACIOUS / TENACIOUS.
- Total lexical occurrences extracted/reconciled: **3,925**
- Unique normalized lexical candidates: **3,234**
- Candidates left without a disposition: **0**
- Needs Review: **0**

### Unique-candidate disposition

| Disposition | Count |
|---|---:|
| RELATED_NOT_SELECTED | 2,356 |
| ALREADY_IN_BANK_EXACT | 388 |
| REJECT_LOW_VALUE | 306 |
| PROMOTED_NEW | 131 |
| FAMILY_DUPLICATE | 38 |
| REJECT_MALFORMED_OR_UNCERTAIN | 15 |
| **Total** | **3,234** |

Canonical already-covered candidates = **426** (388 exact + 38 family duplicates).  
Low-value/malformed/uncertain rejects = **321** (306 + 15).

## 2. Primary-headword reconciliation

The PDF's 200 numbered entries contain **201 headword forms**.

- Already present in the canonical bank before this ingest: **193**
- Newly promoted: **8**
- Missing after reconciliation: **0**

The eight previously missing primary headword forms promoted were:

`TENACIOUS`, `ALACRITY`, `AMASS`, `SCRUPLES`, `IOTA`, `FOREWORD`, `AMISS`, `MAIM`.

## 3. Production write

Production **was changed**, but only the canonical English Vocabulary content/data required by this one-time ingest.

Source ID: `PDF_VOCAB_SAMUNDRAMANTHAN_20240109`  
New Question_ID prefix: `VOC_PDF_20260905_`

A guarded transaction created:

- **131** new canonical Vocabulary questions
- **131** active canonical concepts
- **131** primary question→concept mappings

The transaction contained collision/malformed/count guards and would abort rather than leave a partial import.

No parallel PDF bank, PDF scheduler, PDF learning category, or alternate learner-state system was created.

## 4. Bank Coverage / Central Intelligence integration

Vocabulary Bank Coverage:

- Before: **403**
- After: **534**
- Exact delta: **+131**

The increase equals the promoted-question count exactly.

Concept integration:

- Promoted questions: **131**
- Active concepts: **131**
- Primary mappings: **131**
- Mapping coverage: **100%**

## 5. Learner-history integrity

Post-ingest checks found **zero seeded learner evidence** for the new Question_IDs / Concept_IDs in the checked learner-state surfaces:

- Attempts: 0
- Question state: 0
- Difficult state: 0
- Mastery events: 0
- Star events: 0
- Quiz-session exposures: 0
- Daily current: 0
- Daily history: 0
- Concept evidence: 0
- Concept evidence events: 0

Therefore the import expanded the bank without representing any imported item as previously studied, mastered, difficult, starred, exposed, or attempted.

## 6. Validation evidence

### A. Post-ingest production assertions — PASS

Direct post-write database assertions verified:

- 131 questions
- 131 active concepts
- 131 primary mappings
- Vocabulary Bank Coverage = 534
- exact coverage delta = +131
- zero checked learner evidence/history for the new content

### B. Application baseline validation — PASS

The exact application baseline SHA used for this ingest,
`97ee6246521be7ea4429e201063a78aee126ee0c`,
has successful GitHub Actions validation for the current English application baseline, including:

- English migration reconciliation
- My Saved enrichment worker
- Daily 120
- Daily Hindu boundary
- Concept Dashboard / Central Intelligence surface
- Validate English V2 Web

The successful English V2 Web run includes the repository's fresh-session/revision contracts, English reliability/learning contracts, GK boundary, Maths boundary, TypeScript, and production build.

### C. Specialized safeguard baseline — PASS

The latest applicable specialized workflows preceding the final baseline also completed successfully, including:

- Phrasal atomic Daily validation
- Content ChatGPT bridge validation
- Stage 2 DB hardening
- Stage 2 worker ACL
- Stage 2 audit / architecture safeguards

These are code-baseline safeguards; the PDF ingest itself changed canonical database content, not those implementation paths.

### D. Audit PR behavior

PR #124 is documentation/audit-only. Repository path filters do not require a fresh application build merely because audit files are added. The production content assertions above therefore provide the ingest-specific validation, while the successful application SHA workflows provide the code-baseline validation.

## 7. Machine-readable reconciliation artifacts

The audit bundle contains:

1. `english_pdf_vocab_reconciliation_unique_candidates.csv` — **3,234** unique candidates with disposition/reason/canonical IDs.
2. `english_pdf_vocab_reconciliation_occurrences.csv` — **3,925** extracted lexical occurrences.
3. `english_pdf_vocab_headword_reconciliation.csv` — **201** primary headword forms.
4. `english_pdf_vocab_reconciliation_compact.csv` — compact unique-candidate mapping.
5. `english_pdf_vocab_reconciliation_summary.json` — reconciliation and promotion totals.
6. `english_pdf_vocab_promoted_131.json` — the **131** promoted canonical records.
7. This final audit report.

## 8. Residual risk

The source PDF's synonym/antonym lists contain noisy, loose, inflected, easy, or malformed lexical material. Those source relationships were treated as provenance rather than blindly as dictionary equivalence. This is why 306 low-value candidates and 15 malformed/uncertain artifacts were rejected, and why 2,356 valid related terms were retained in reconciliation without being promoted as standalone questions.

The family-duplicate classification is intentionally conservative. Exact live-word and proposed Concept_ID collisions for the 131 promoted records were checked before the transactional write.

**Residual blocking issues: none identified.**  
**Needs Review: 0.**

## 9. Final state

- Source fully inventoried: **YES**
- Every unique candidate dispositioned: **YES**
- Every occurrence reconciled: **YES**
- All primary headword forms accounted: **YES**
- Canonical promotion complete: **YES**
- Central Intelligence mapping complete: **YES**
- Bank Coverage reconciliation exact: **YES**
- Learner history preserved: **YES**
- Application code changed for this ingest: **NO**
- Production canonical Vocabulary data changed: **YES**
- Production deployment required: **NO**
- PR merged: **NO** — PR #124 remains an audit/review PR; no merge was performed as part of this task.

**Final result: ONE-TIME PDF VOCABULARY INGEST COMPLETE.**
