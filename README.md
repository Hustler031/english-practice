# English Practice / Revision System

This repository contains the shared V2 web application used for the English learning system and integrated modules such as GK.

## Current production architecture

- **Frontend:** Next.js application in `web-v2/`
- **Backend / learning data:** Supabase
- **Production hosting:** Cloudflare Workers
- **Cloudflare Worker:** `english-practice`
- **Production branch:** `main`
- **Cloudflare root directory:** `web-v2`

Legacy Apps Script code may remain in the repository for history/reference, but it is **not the V2 production deployment path**.

---

# Production deployment runbook

## Permanent Cloudflare settings

Cloudflare → Workers & Pages → `english-practice` → Settings → Builds

Keep these values exactly:

```text
Production branch: main
Root directory: web-v2
Build command: npm run build
Deploy command: npx wrangler deploy
Builds for non-production branches: OFF
```

Do not change the production branch back to `cloudflare-hosting-prep`. That branch was only used during initial Cloudflare hosting setup and is now legacy.

## Normal deployment workflow

For English, GK, or any other module inside `web-v2`:

1. Develop on the relevant feature/integration branch.
2. Validate the branch before production:

```bash
cd web-v2
npm run typecheck
npm run build
```

3. Fix only genuine validation failures. Do not make unrelated changes during the deployment step.
4. Merge the verified feature branch into `main`.
5. A push/merge to `main` automatically triggers the Cloudflare production build for Worker `english-practice`.
6. Wait for the GitHub check named:

```text
Workers Builds: english-practice
```

7. Production is considered deployed only when that Cloudflare check reports **success**.
8. Perform a read-only smoke test of the affected routes after deployment.

## Module flow

```text
English feature branch ─┐
GK integration branch ──┼─> verify ─> main ─> Cloudflare Worker `english-practice`
Future V2 modules ───────┘
```

GK does **not** require a separate Cloudflare deployment when it is integrated into `web-v2`; its routes deploy with the same Worker after the verified GK branch is merged into `main`.

## Important deployment rules

- **Do not use `[skip ci]` / `[skip actions]` on a production-candidate commit.** It can cause Cloudflare/GitHub automation to skip the deployment.
- Do not deploy an unverified feature branch directly to production.
- Do not use `cloudflare-hosting-prep` as the normal production branch.
- Do not enable non-production Cloudflare builds unless there is a specific temporary need.
- Do not modify Maths/GK/English internals merely to make a deployment trigger run; first distinguish a code/build failure from a Cloudflare configuration failure.
- Production smoke tests should be read-only wherever possible and must not intentionally mutate learning data.
- A successful local/GitHub `npm run build` does **not** by itself mean production is deployed; the Cloudflare Workers build must also succeed.

## If a Cloudflare build fails

1. Open Cloudflare → Workers & Pages → `english-practice` → Deployments/Builds.
2. Open the failed build and inspect the first real error in the build log.
3. Confirm the permanent settings above before changing application code.
4. If the code is unchanged and the failure is configuration-related, correct the Cloudflare setting and retry/retrigger the build.
5. Do not redesign UI or alter learning logic as a deployment workaround.

## Production safety

The application contains Local Safe protections for localhost development against the production Supabase backend. Do not weaken or bypass those protections during deployment/testing.
