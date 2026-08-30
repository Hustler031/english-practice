# GK V2 Supabase ledger

Project: `hytehindbmjdwcfptsic`

This file records the live GK V2 migration sequence verified from `supabase_migrations.schema_migrations` during the localhost-first integration on 2026-08-30.

| Version | Live migration | Repository status |
|---|---|---|
| 20260829105829 | gk_v2_source_identity_and_raw_evidence | live foundation; original managed SQL is not present in this branch |
| 20260829120011 | gk_enable_http_import_transport | live foundation; original managed SQL is not present in this branch |
| 20260829120326 | gk_canonical_payload_import_transport | live foundation; original managed SQL is not present in this branch |
| 20260829121729 | gk_v2_backend_read_write_foundation | live foundation; original managed SQL is not present in this branch |
| 20260829123912 | gk_v2_source_study_date | live foundation; original managed SQL is not present in this branch |
| 20260829155628 | gk_lock_down_staging_tables | live foundation; original managed SQL is not present in this branch |
| 20260829155742 | protect_gk_migration_evidence_tables | live foundation; original managed SQL is not present in this branch |
| 20260829160249 | gk_v2_lane_contract_fix | live foundation; original managed SQL is not present in this branch |
| 20260829160500 | gk_v2_lane_and_subject_browse | live foundation; original managed SQL is not present in this branch |
| 20260829160511 | gk_v2_runtime_rpc_permissions | live foundation; original managed SQL is not present in this branch |
| 20260829161319 | gk_v2_native_api | live foundation; original managed SQL is not present in this branch |
| 20260829163754 | gk_lane_recall_guess_parity | live foundation; original managed SQL is not present in this branch |
| 20260829164200 | gk_active_exposure_summary | live foundation; original managed SQL is not present in this branch |
| 20260830025704 | gk_v2_local_safe_read_surface | exact repository mirror: `20260830025704_gk_v2_local_safe_read_surface.sql` |
| 20260830032146 | gk_v2_view_parity_reads | exact repository mirror; read-only old-view support for true scope All, lecture Parts, New Practice, Guessed and Flagged Content |
| 20260830032730 | gk_v2_starred_group_view_parity | exact repository mirror; read-only Starred day-group random/smart/all selector |
| 20260830033040 | gk_v2_starred_group_selector_wiring | exact repository mirror; routes existing Starred age URLs to the group selector without changing data |
| 20260830034447 | gk_v2_scoped_concept_route_keys | exact repository mirror; read-only subject/topic-scoped concept route keys prevent duplicate React keys and ambiguous concept routing |

## Localhost-first safety decision

The earlier branch-only GK SQL drafts dated `20260829100000`, `20260830013000`, `20260830020500`, `20260830023000`, `20260830025000`, and `20260830030000` were never the live migration ledger. Some contained evidence-derived `question_state` rebuilds. They were removed from the deployable `managed-migrations` directory once the actual live ledger was inspected.

The tracked GK migrations from `20260830025704` onward are read-model/runtime-function changes only. They create or replace helper/read RPC functions and grants; they do not update/insert/delete canonical GK content, attempts, exposures, question state, sessions, notes, flags, demand-set rows, or English data.

The view-parity layer restores old product behavior that the first React shell had flattened: Content library → lecture → Main/Rapid 20-question Parts, dedicated New Practice hierarchy, dedicated Starred and Guessed libraries, Flagged Content review, and true large-scope Practice All reads. Starred day groups preserve the old Random 10 / Smart 20 / Practice All semantics through a read-only selector.

The scoped concept-key layer addresses legacy concept IDs reused across more than one subject/topic scope. UI/read routes now carry `Subject|Topic|CanonicalConcept` while the canonical database `concept_id` itself is left unchanged. This removes duplicate React keys such as `POL3-C005` and prevents a concept route from mixing similarly named concept IDs across topics.

## Cutover gate

Localhost integration may rely on the current live GK foundation plus the exact read-surface mirrors above. Production cutover remains blocked until the pre-`20260830025704` live GK foundation is either recovered as exact managed SQL or captured as an approved deterministic baseline. No future cutover should rely on untracked SQL.
