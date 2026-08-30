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

## Localhost-first safety decision

The earlier branch-only GK SQL drafts dated `20260829100000`, `20260830013000`, `20260830020500`, `20260830023000`, `20260830025000`, and `20260830030000` were never the live migration ledger. Some contained evidence-derived `question_state` rebuilds. They were removed from the deployable `managed-migrations` directory once the actual live ledger was inspected.

`20260830025704_gk_v2_local_safe_read_surface.sql` is intentionally read-model-only: it creates/replaces helper/read RPC functions and grants, but does not update/insert/delete canonical GK content, attempts, exposures, question state, sessions, or English data.

## Cutover gate

Localhost integration may rely on the current live GK foundation plus the exact read-surface mirror above. Production cutover remains blocked until the pre-`20260830025704` live GK foundation is either recovered as exact managed SQL or captured as an approved deterministic baseline. No future cutover should rely on untracked SQL.
