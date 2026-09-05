# Live managed migration ledger

Project: `hytehindbmjdwcfptsic`

This manifest tracks the managed Supabase execution ledger for the revision platform. English, GK and Maths migrations are mirrored in execution order.

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
| 20260829070255 | english_read_path_performance_polish | exact mirror |
| 20260829070759 | english_home_snapshot_read_write_fix | exact mirror |
| 20260830121830 | maths_lossless_data_foundation | exact mirror |
| 20260830121917 | maths_historical_evidence_ledger | exact mirror |
| 20260830123431 | maths_complete_migration_schema | exact mirror |
| 20260830123600 | maths_migration_parse_helpers | exact mirror |
| 20260830123722 | maths_complete_learning_evidence | exact mirror |
| 20260830123745 | maths_complete_session_evidence | exact mirror |
| 20260830123836 | maths_complete_diagram_and_bank_ledger | exact mirror |
| 20260830124036 | maths_normalize_seen_exposures | exact mirror |
| 20260830124331 | maths_persistent_integrity_report | exact mirror |
| 20260830124444 | maths_persistent_reconciliation | exact mirror |
| 20260830124700 | maths_migration_final_hardening | exact mirror |
| 20260830172024 | maths_v2_runtime_core | exact mirror |
| 20260830172110 | maths_v2_read_surfaces | exact mirror |
| 20260830172204 | maths_v2_session_and_state_rpcs | exact mirror |
| 20260830172224 | maths_v2_runtime_permissions | exact mirror |
| 20260830172323 | maths_v2_home_target_fix | exact mirror |
| 20260830172541 | maths_v2_local_safe_preview | exact mirror |
| 20260830174557 | maths_v2_new_pool_parity | exact mirror |
| 20260830174613 | maths_v2_formula_revision_parity | exact mirror |
| 20260830174627 | maths_v2_new_count_and_helper_hardening | exact mirror |
| 20260830174714 | maths_v2_local_safe_formula_parity | exact mirror |
| 20260830175430 | maths_v2_option_rotation_parity | exact mirror |
| 20260830191345 | maths_v2_final_audit_hardening | exact mirror |
| 20260830192647 | maths_v2_restore_diagram_ledger | exact mirror |
| 20260830193148 | maths_v2_session_snapshot_repair | exact mirror |
| 20260830193522 | maths_v2_chapter_group_boundary_fix | exact mirror |

## Current runtime closure

The managed execution sequence is now represented in `supabase/managed-migrations/` from the first foundation migration through the current backend-finalization migration. `20260828211355` is the sole intentional portability exception: its repository form removes the concrete live owner UUID and resolves the user at runtime instead of publishing an account identifier.

The finalization migrations add category-aware Daily intelligence, durable selection rationale, actionable Daily counts, module-level progress intelligence, old-app day/10-day/30-day revision hierarchy, authenticated-only RPC writes, health/reconciliation checks, top-level Central Intelligence, Smart central revision, strict user-state isolation from shared canonical content, owner-scoped Saved-generated question provenance across practice pools, a consolidated cached Home snapshot, canonical Hindu question serving/submission, covering indexes for the hottest English learning relationships, backend-owned Saved study-day metadata, backend Starred guidance so explanatory intelligence can stay aligned with selection logic, read-path RLS/index performance polish for the English schema without changing user-visible access semantics, and a write-safe Home snapshot wrapper so its nested Phrasal hub can use temporary working tables without failing inside a read-only STABLE transaction.

Saved-generated questions carry an explicit owner in `english.question_origins`; foreign generated questions are hidden from direct reads and RPC payloads, generic mutation RPCs reject them, shared practice sets cannot contain private generated questions, and health checks detect invisible-state or ownership leakage.

`supabase/migrations/20260829_001_english_behavior_parity.sql` remains a consolidated convenience artifact, but disaster recovery and audit should use the ordered managed-migration mirror in this directory.

**Rule:** no V2 cutover may rely on an unversioned manual SQL change. GPT enrichment/scheduling remains a separate content workflow rather than an untracked schema/runtime change.

## Stage 1 reconciliation (2026-09-05)

| Version | Migration | Repository mirror |
|---|---|---|
| 20260904192910 | english_dedicated_revision_worker_schedule | live ledger recorded; exact SQL recovery pending export, runtime source recovered below |
| 20260904193012 | english_phrasal_maintenance_and_ai_budgets | live ledger recorded; exact SQL recovery pending export |
| 20260904193504 | english_dedicated_revision_claim | live ledger recorded; equivalent queue hardening is tracked in 20260905090000 |
| 20260905090000 | english_ai_architecture_stage1 | additive lifecycle/error-code/retry observability mirror |

Live English function inventory is checked by the Stage 1 audit bundle. `english-revision-worker` source is now Git-managed; its dedicated ownership is enforced by `.github/scripts/validate-english-ai-architecture.cjs`.
