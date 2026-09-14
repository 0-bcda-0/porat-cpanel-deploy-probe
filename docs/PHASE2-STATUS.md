# Phase 2 cPanel UAPI capability probe status

Last updated: 2026-09-14 UTC (after Run #5)

## Purpose

This temporary public repository exists only to prove whether the Heavy Duty cPanel account on `cp077.mydataknox.com` can support a future SSH-less Porat Staff deployment controller. It is not the Porat Staff application repository and must not become an application deployment path by itself.

The intended future architecture is GitHub Actions -> cPanel UAPI upload/request -> cPanel Git deployment trigger -> controlled worker -> the existing transactional Porat Staff deployer. The cPanel Git layer is only a trigger; atomic release switching, rollback semantics, private `.env`, persistent uploads/weather data, and health checks remain responsibilities of the existing Porat Staff deployment design.

## Hard safety boundaries

Phase 2 is capability probing only. It must not deploy Porat Staff, modify production, change databases, change weather ingestion, replace the current SSH/SCP transport, or touch the deferred SamBoat/Google Calendar work.

The probe is restricted to `/home/echosline/cpanel-deploy-probe`. All Porat Staff DEV/PROD application roots, their public document roots, and the hosting account's main public web root are forbidden. The executable repository contract intentionally rejects those live paths anywhere in the probe repository, so this status document does not duplicate their literal values.

The workflow is manual (`workflow_dispatch`), runs on GitHub-hosted `ubuntu-24.04`, uses the `development` Environment, and must not receive SSH keys or use SSH/SCP. The temporary cPanel API token is a broad account credential: it must never be committed or logged and should be revoked after the probe.

## Probe history

### Run #1 — local safety failure

Run `34824603362`, initial SHA `6a1a66d312f8e72fe7bdae5f13b6605423c28cdf`.

The workflow stopped before any cPanel request because the approved controller clone URL leaked into the missing-value safety test. The fix moved the clone URL into the live step and strengthened URL validation.

### Run #2 — wrong-account token / HTTP 403

Run `34825033363`, SHA `a883b5b4696a197871576a4647b1a174f0d3fbdf`.

Local tests passed. The first HTTPS request reached cPanel but returned HTTP 403. Additional defects were found in the probe harness (`rg` availability and cleanup after a first-request failure) and fixed. The operator then discovered that the cPanel API token had been created on the wrong hosting account and replaced the GitHub secret with a dedicated token created for the `echosline` account.

### Run #3 — valid response path but insufficient HTTP diagnostics

Run `34825738585`, SHA `e9fbf453fbfd3c3ea056f70fd9f8ca333eacd4a9`.

The first request no longer returned 403, but the probe reported `Malformed UAPI JSON response`. This exposed a diagnostic gap: the client did not safely distinguish JSON, HTML, redirects, and HTTP authentication failures.

### Run #4 — HTTP layer proven, UAPI envelope reports failure

Run `34828669712`, SHA `c4077ac3c80d760390f829220b43babdc59c7193`.

All local safety tests passed on GitHub-hosted Ubuntu 24.04. Normal TLS worked, the cPanel endpoint returned HTTP 2xx JSON, and the response reached UAPI parsing. The first `Variables/get_user_information` request then failed with `UAPI request failed: ["unspecified UAPI error"]`. No Fileman upload, controller repository creation, or VersionControlDeployment action was attempted.

This proves that the current blocker is no longer basic GitHub networking, TLS, HTTP classification, or the earlier wrong-account 403. The next evidence needed is the non-sensitive structure of the first UAPI response envelope.

### Run #5 — live cp077 uses a flattened UAPI result envelope

Run `34830289792`, SHA `4b49a798056141c15859d11da039337043f7f14d`.

All local safety tests passed. The live probe again stopped before Fileman or Git deployment actions, but the diagnostic artifact was successfully retained. `first-uapi-envelope.json` reported the exact top-level key set `data`, `errors`, `messages`, `metadata`, `status`, and `warnings`; there was no `result` object and no `apiversion`, `module`, or `func` wrapper.

This is the key evidence from Run #5. Official cPanel UAPI documentation normally shows the transport response wrapped as `apiversion`/`module`/`func` plus a nested `result` object, while the live cp077 `/execute/...` response observed through MyDataKnox exposes the inner result object directly. The previous parser therefore interpreted a valid flattened result as a failure because it only read `.result.status`, `.result.data`, and `.result.errors`.

No sensitive response values were captured; only key names and value types were retained.

## Current root-cause hypothesis

The immediate blocker is a response-envelope compatibility mismatch in the probe client, not basic TLS, HTTP transport, or the earlier wrong-account token. The live cp077 endpoint returns the UAPI result payload flattened at the top level for the tested call. The probe must accept both the canonical nested cPanel form and this observed flattened form while continuing to fail closed on unknown shapes.

## Next change / Run #6

Run #6 adds dual-envelope parsing. A response is accepted only when it is either the canonical object with a `result` object or the observed flattened object containing `status` plus `data` or `errors`. Unknown JSON shapes remain rejected. The safe summarizer also records `envelope_shape` as `nested-result`, `flat-result`, or `unknown` without exposing response values.

Tests cover the new flattened success path before the implementation. If the first live UAPI call succeeds under this parser, the probe may continue into the already-approved isolated Phase 2 capability checks under `/home/echosline/cpanel-deploy-probe`. Any new failure is to be treated as the next evidence point; do not broaden scope to Porat Staff live roots, production, databases, weather, or SSH/SCP replacement.

## Adoption gates still outstanding

A production-capable SSH-less design is not approved yet. Phase 2 still needs to prove Fileman upload semantics, isolated cPanel-managed controller repository behavior, VersionControlDeployment create/retrieve and terminal statuses, deliberate non-zero failure propagation, unchanged-controller-HEAD retriggering, request/task/result correlation, execution environment/tool availability, bounded timeout behavior, and repeated DEV-only success. The broad cPanel API-token risk also requires explicit review before any production adoption.
