# Live managed migration ledger

Project: `hytehindbmjdwcfptsic`

This manifest tracks the managed Supabase execution ledger for English V2. The live ledger currently contains **56 migrations**.

| Version | Migration | Repository mirror |
|---|---|---|
| 20260828200009 | 001_revision_platform_foundation | exact mirror |
| 20260828200143 | 002_temporary_migration_ingest | exact mirror |
| 20260828200321 | 003_core_application_tables | exact mirror |
| 20260828200332 | 004_remove_temporary_ingest_rpc | exact mirror |
| 20260828203004 | 002_rls_and_access_policies | exact mirror |
| 20260828203147 | 003_english_user_assignment_pipeline | exact mirror |
| 20260828203207 | 004_harden_legacy_parsers | exact mirror |
| 20260828203336 | 005_harden_english_assignment_failure_path | exact mirror |
| 20260828204804 | english_behavior_parity_schema | exact mirror |
| 20260828205342 | english_behavior_raw_staging | exact mirror |
| 20260828205449 | english_behavior_finalize_pipeline | exact mirror |
| 20260828205959 | fix_english_behavior_finalizer_digest_path | exact mirror |
| 20260828210556 | english_learning_profile_and_core_rpcs | exact mirror |
| 20260828210833 | english_daily_selection_rpcs | exact mirror |
| 20260828211130 | english_saved_item_core_rpcs | exact mirror |
| 20260828211148 | english_saved_enrichment_and_promotion_rpcs | exact mirror |
| 20260828211355 | english_hindu_vocab_registry_recovery | portable mirror; live owner UUID deliberately not published |
| 20260828211448 | english_read_model_helpers | exact mirror |
| 20260828211523 | english_primary_read_rpcs | exact mirror |
| 20260828211549 | fix_english_demand_batch_ranking | exact mirror |
| 20260828211613 | fix_english_demand_batch_ambiguity | exact mirror |
| 20260828211722 | english_source_practice_rpcs | exact mirror |
| 20260828211739 | english_new_practice_rpcs | exact mirror |
| 20260828211850 | english_hindu_vocab_rpcs | exact mirror |
| 20260828211919 | english_harden_user_state_rls | exact mirror |
| 20260828212147 | fix_english_save_word_insert_shape | exact mirror |
| 20260828213734 | english_phrasal_concept_engine | exact mirror |
| 20260828213831 | english_phrasal_mastery_batch_rpc | exact mirror |
| 20260828213939 | english_phrasal_mastery_hub_rpcs | exact mirror |
| 20260829002305 | english_progress_demand_bank_parity | exact mirror |
| 20260829002527 | english_central_starred_saved_intelligence | exact mirror |
| 20260829002559 | english_saved_history_batch | exact mirror |
| 20260829003100 | english_central_revision_selection | exact mirror |
| 20260829003403 | english_hindu_central_state_payload | exact mirror |
| 20260829020331 | english_starred_hub_current_day | exact mirror |
| 20260829025357 | english_starred_manual_parity_counts | exact mirror |
| 20260829025434 | english_starred_manual_items_rpc | exact mirror |
| 20260829030252 | english_starred_rotation_read_stats | exact mirror |
| 20260829030331 | english_starred_rotation_read_stats_due_weak | exact mirror |
| 20260829031226 | english_remaining_module_parity_reads | exact mirror |
| 20260829031244 | english_mastered_restore_read | exact mirror |
| 20260829031328 | english_bank_coverage_detail_review_parity | exact mirror |
| 20260829031556 | english_bank_coverage_today_items_parity | exact mirror |
| 20260829031637 | english_bank_coverage_seen_batch_parity | exact mirror |
| 20260829035529 | english_daily_intelligence_finalization | exact mirror |
| 20260829035704 | english_progress_intelligence_finalization | exact mirror |
| 20260829035855 | english_revision_hierarchy_parity | exact mirror |
| 20260829040040 | english_security_health_and_user_state_finalization | exact mirror |
| 20260829040216 | english_starred_selection_signal_parity | exact mirror |
| 20260829040726 | english_central_intelligence_finalization | exact mirror |
| 20260829040854 | english_hindu_user_state_isolation | exact mirror |
| 20260829042238 | english_saved_generated_provenance_owner | exact mirror |
| 20260829042302 | english_saved_generated_runtime_isolation | exact mirror |
| 20260829042511 | english_owner_isolation_health_finalization | exact mirror |
| 20260829063737 | english_preview_final_polish_backend | exact mirror |
| 20260829064811 | english_ui_intelligence_centralization | exact mirror |

## Current runtime closure

The managed execution sequence is now represented in `supabase/managed-migrations/` from the first foundation migration through the current backend-finalization migration. `20260828211355` is the sole intentional portability exception: its repository form removes the concrete live owner UUID and resolves the user at runtime instead of publishing an account identifier.

The finalization migrations add category-aware Daily intelligence, durable selection rationale, actionable Daily counts, module-level progress intelligence, old-app day/10-day/30-day revision hierarchy, authenticated-only RPC writes, health/reconciliation checks, top-level Central Intelligence, Smart central revision, strict user-state isolation from shared canonical content, owner-scoped Saved-generated question provenance across practice pools, a consolidated cached Home snapshot, canonical Hindu question serving/submission, covering indexes for the hottest English learning relationships, backend-owned Saved study-day metadata, and backend Starred guidance so explanatory intelligence can stay aligned with selection logic.

Saved-generated questions carry an explicit owner in `english.question_origins`; foreign generated questions are hidden from direct reads and RPC payloads, generic mutation RPCs reject them, shared practice sets cannot contain private generated questions, and health checks detect invisible-state or ownership leakage.

`supabase/migrations/20260829_001_english_behavior_parity.sql` remains a consolidated convenience artifact, but disaster recovery and audit should use the ordered managed-migration mirror in this directory.

**Rule:** no V2 cutover may rely on an unversioned manual SQL change. GPT enrichment/scheduling remains a separate content workflow rather than an untracked schema/runtime change.
