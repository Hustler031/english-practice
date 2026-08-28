# Live managed migration ledger

Project: `hytehindbmjdwcfptsic`

The following versions are present in the Supabase managed migration ledger, in execution order:

| Version | Migration |
|---|---|
| 20260828200009 | 001_revision_platform_foundation |
| 20260828200143 | 002_temporary_migration_ingest |
| 20260828200321 | 003_core_application_tables |
| 20260828200332 | 004_remove_temporary_ingest_rpc |
| 20260828203004 | 002_rls_and_access_policies |
| 20260828203147 | 003_english_user_assignment_pipeline |
| 20260828203207 | 004_harden_legacy_parsers |
| 20260828203336 | 005_harden_english_assignment_failure_path |
| 20260828204804 | english_behavior_parity_schema |
| 20260828205342 | english_behavior_raw_staging |
| 20260828205449 | english_behavior_finalize_pipeline |
| 20260828205959 | fix_english_behavior_finalizer_digest_path |
| 20260828210556 | english_learning_profile_and_core_rpcs |
| 20260828210833 | english_daily_selection_rpcs |
| 20260828211130 | english_saved_item_core_rpcs |
| 20260828211148 | english_saved_enrichment_and_promotion_rpcs |
| 20260828211355 | english_hindu_vocab_registry_recovery |
| 20260828211448 | english_read_model_helpers |
| 20260828211523 | english_primary_read_rpcs |
| 20260828211549 | fix_english_demand_batch_ranking |
| 20260828211613 | fix_english_demand_batch_ambiguity |
| 20260828211722 | english_source_practice_rpcs |
| 20260828211739 | english_new_practice_rpcs |
| 20260828211850 | english_hindu_vocab_rpcs |
| 20260828211919 | english_harden_user_state_rls |
| 20260828212147 | fix_english_save_word_insert_shape |
| 20260828213734 | english_phrasal_concept_engine |
| 20260828213831 | english_phrasal_mastery_batch_rpc |
| 20260828213939 | english_phrasal_mastery_hub_rpcs |

## Repository mirror rule

The managed Supabase ledger above is the exact record of what has executed. Repository SQL is being materialized from that ledger, not reconstructed from memory. The existing `supabase/migrations/20260829_001_english_behavior_parity.sql` is an earlier consolidated repository artifact and must not be mistaken for the complete live ledger.

No V2 cutover may rely on an unversioned manual production SQL change.
