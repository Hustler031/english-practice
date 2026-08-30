# GK V2 Supabase ledger

Project: `hytehindbmjdwcfptsic`

This document separates three things deliberately:

1. the historical migration versions verified in the live `supabase_migrations.schema_migrations` ledger;
2. exact repository-managed migrations that are safe to apply forward from the current live project; and
3. a reconstructed clean-database recovery baseline. The recovery baseline is **not** represented as an original historical migration and is kept outside `managed-migrations` so it cannot be accidentally replayed against production.

## Verified live historical ledger

| Version | Live migration | Repository status |
|---|---|---|
| 20260829105829 | gk_v2_source_identity_and_raw_evidence | historical live foundation; original SQL was not recovered exactly |
| 20260829120011 | gk_enable_http_import_transport | historical live foundation; original SQL was not recovered exactly |
| 20260829120326 | gk_canonical_payload_import_transport | historical live foundation; original SQL was not recovered exactly |
| 20260829121729 | gk_v2_backend_read_write_foundation | historical live foundation; original SQL was not recovered exactly |
| 20260829123912 | gk_v2_source_study_date | historical live foundation; original SQL was not recovered exactly |
| 20260829155628 | gk_lock_down_staging_tables | historical live foundation; original SQL was not recovered exactly |
| 20260829155742 | protect_gk_migration_evidence_tables | historical live foundation; original SQL was not recovered exactly |
| 20260829160249 | gk_v2_lane_contract_fix | historical live foundation; original SQL was not recovered exactly |
| 20260829160500 | gk_v2_lane_and_subject_browse | historical live foundation; original SQL was not recovered exactly |
| 20260829160511 | gk_v2_runtime_rpc_permissions | historical live foundation; original SQL was not recovered exactly |
| 20260829161319 | gk_v2_native_api | historical live foundation; original SQL was not recovered exactly |
| 20260829163754 | gk_lane_recall_guess_parity | historical live foundation; original SQL was not recovered exactly |
| 20260829164200 | gk_active_exposure_summary | historical live foundation; original SQL was not recovered exactly |
| 20260830025704 | gk_v2_local_safe_read_surface | exact repository mirror: `20260830025704_gk_v2_local_safe_read_surface.sql` |
| 20260830032146 | gk_v2_view_parity_reads | exact repository mirror |
| 20260830032730 | gk_v2_starred_group_view_parity | exact repository mirror |
| 20260830033040 | gk_v2_starred_group_selector_wiring | exact repository mirror |
| 20260830034447 | gk_v2_scoped_concept_route_keys | exact repository mirror |

The historical versions above remain the truthful production history. Missing original SQL is **not** recreated under those version numbers.

## Reconstructed clean-database baseline

Recovery file:

`supabase/recovery-baselines/gk_v2_reconstructed_pre25704_baseline.sql`

This is a deterministic reconstruction of the effective GK foundation immediately required by the repository-managed `20260830025704+` layer. It was reconstructed from the live PostgreSQL catalog and records:

- the `gk` tables and exact required column types/defaults;
- primary keys, foreign keys and uniqueness constraints;
- runtime indexes required by the foundation;
- RLS enablement and the pre-25704 ownership/read policies;
- staging/evidence-table protection;
- the canonical admin import transport.

It contains **no canonical question rows and no user learning evidence**. It does not replay Attempts, Exposures, QuestionState, Sessions, notes, flags or Demand Sets. Legacy `demand_sets` intentionally starts without `user_id`; the forward audit migration adds ownership without fabricating an owner for historical rows.

The recovery file lives outside `managed-migrations` by design. It must never be applied to the existing production project merely to make the historical ledger look complete.

## Repository-managed forward GK migrations

After the reconstructed baseline, the repository-managed GK runtime is built by applying the tracked `20260830025704+` migrations in version order:

| File | Purpose |
|---|---|
| `20260830025704_gk_v2_local_safe_read_surface.sql` | authenticated read surface and canonical library/selector compatibility |
| `20260830032146_gk_v2_view_parity_reads.sql` | scope, lecture-part, New, Guessed and Flagged read parity |
| `20260830032730_gk_v2_starred_group_view_parity.sql` | Starred day-group selector |
| `20260830033040_gk_v2_starred_group_selector_wiring.sql` | Starred age-route wiring |
| `20260830034447_gk_v2_scoped_concept_route_keys.sql` | subject/topic-scoped concept route identity |
| `20260830072000_gk_uuid_min_compat.sql` | internal `gk.min(uuid)` aggregate required by legacy-owner compatibility logic on PostgreSQL versions without built-in `min(uuid)` |
| `20260830073000_gk_v2_final_runtime_parity.sql` | forward runtime recovery: raw-evidence intelligence, missing mutation/session RPCs, Demand ownership column, guarded canonical answer corrections and RPC-only private-table access |
| `20260830074500_gk_v2_final_audit_corrections.sql` | final live-schema corrections: seven-argument submit compatibility, same-session retention exclusion, exact Daily tiers, idempotent manual tools, exact pause position, Demand RLS and active answer-key constraint |
| `20260830075000_gk_v2_selector_uid_disambiguation.sql` | final central-selector correction removing PL/pgSQL caller/legacy-owner identifier ambiguity without changing selection semantics |

`20260830072000`, `20260830073000`, `20260830074500` and `20260830075000` were created during the final pre-deployment audit and are repository-forward migrations; they are not represented here as already deployed production history.

## Canonical content and historical evidence recovery

Schema reproducibility is separate from data recovery.

A clean environment uses this sequence:

1. apply `gk_v2_reconstructed_pre25704_baseline.sql`;
2. import canonical GK content through the protected canonical import transport or an equivalent audited content seed;
3. apply the repository-managed `20260830025704+` GK migrations in version order;
4. import historical user evidence only when performing a real disaster-recovery/data migration, never as part of schema bootstrap.

The schema baseline therefore does not invent or embed the current user's learning history. The historical raw evidence remains authoritative in production.

## Unsafe draft history

Earlier branch-only GK drafts dated `20260829100000`, `20260830013000`, `20260830020500`, `20260830023000`, `20260830025000`, and `20260830030000` were never the verified live migration ledger. Some contained evidence-derived `question_state` rebuilds. They remain excluded from the deployable managed-migration directory and must not be reintroduced.

## Mechanical recovery gate

The GK GitHub validation workflow creates a fresh PostgreSQL database, applies:

- the reconstructed pre-25704 recovery baseline;
- all tracked `20260830025704+` GK migrations in version order;
- executable runtime/security/evidence assertions.

Only a successful clean-room workflow proves that repository-managed material can reproduce the required backend structure and current runtime contract. Production cutover must remain blocked if that clean-room test or any later validation fails.
