# Live managed migration ledger

Project: `hytehindbmjdwcfptsic`

The following versions are present in the Supabase managed migration ledger, in execution order:

| Version | Migration | Repository mirror |
|---|---|---|
| 20260828200009 | 001_revision_platform_foundation | ledger only |
| 20260828200143 | 002_temporary_migration_ingest | ledger only |
| 20260828200321 | 003_core_application_tables | ledger only |
| 20260828200332 | 004_remove_temporary_ingest_rpc | ledger only |
| 20260828203004 | 002_rls_and_access_policies | ledger only |
| 20260828203147 | 003_english_user_assignment_pipeline | ledger only |
| 20260828203207 | 004_harden_legacy_parsers | ledger only |
| 20260828203336 | 005_harden_english_assignment_failure_path | ledger only |
| 20260828204804 | english_behavior_parity_schema | consolidated historical artifact |
| 20260828205342 | english_behavior_raw_staging | consolidated historical artifact |
| 20260828205449 | english_behavior_finalize_pipeline | consolidated historical artifact |
| 20260828205959 | fix_english_behavior_finalizer_digest_path | consolidated historical artifact |
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

## Repository mirror rule

The managed Supabase ledger above is the exact record of what has executed. Repository SQL is materialized from that ledger, not reconstructed from memory. The V2 runtime layer from `20260828210556` onward is now fully represented in `supabase/managed-migrations/`; the Hindu recovery mirror intentionally replaces the concrete single-user UUID with a runtime single-user guard so an account identifier is not committed to this public repository.

The earlier foundation/import migrations remain recoverable from Supabase's managed ledger and the migration/legacy snapshots, while `supabase/migrations/20260829_001_english_behavior_parity.sql` remains the earlier consolidated repository artifact. It must not be mistaken for the exact pre-runtime managed ledger.

No V2 cutover may rely on an unversioned manual production SQL change.
