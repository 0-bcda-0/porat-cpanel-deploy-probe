# Phase 2 cPanel UAPI capability probe status

Last updated: 2026-09-14 UTC (after Run #8)

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

### Run #6 — dual-envelope parser works; repository creation reached cPanel validation

Run `34831946621`, SHA `0d3c648f59d3f80f35b9279a268521f6acb0e2f4`.

All local safety tests passed, including the flattened-envelope regression. The live probe successfully passed the initial `Variables/get_user_information` call under the dual-envelope parser and continued to `VersionControl/retrieve` / controller repository setup for the first time.

The next cPanel response failed closed with `Provide the “type” parameter for the “Cpanel::VersionControl::new” function.` No Fileman upload, VersionControlDeployment task, Porat Staff application deployment, database change, weather change, or SSH/SCP replacement occurred.

Official cPanel UAPI documentation for `VersionControl/create` marks `type` as required with the only supported value `git`. For cloning an existing repository it also defines `source_repository` as a JSON object containing `remote_name` and `url`. The probe had been sending the non-documented `clone_url` parameter instead.

### Run #7 — controller repository and cPanel deployment execution proven

Run `34832738021`, SHA `51da7cfbccbb660e8720dbce4b6f4a96918d72d0`.

The corrected `VersionControl/create` contract (`type=git` plus documented `source_repository`) succeeded. The isolated controller repository was registered under the approved probe root and `VersionControlDeployment/create` returned a deployment identifier. The run stopped only because the probe poller expected a generic `state`/`status` field that cp077 does not expose for these deployment records.

### Run #8 — live cp077 deployment status model identified

Run `34835125243`, SHA `4bcd00b9f37964ed58e709d084b4cc290582e330`.

All local safety tests passed. The diagnostic artifact proved that `VersionControlDeployment/retrieve` returns an array of records containing `deploy_id`, `task_id`, and a `timestamps` object. The newly created deployment correlated exactly by `deploy_id`, and its timestamps contained `queued`, `active`, and `succeeded`. This proves that the cPanel deployment executed successfully; the remaining blocker is solely the probe poller interpreting the wrong status model.


## Current root-cause hypothesis

The transport, token authentication, flattened UAPI parsing, isolated cPanel Git repository registration, deployment creation, deployment retrieval, and successful controller execution are proven. The immediate blocker is local probe logic: cp077 represents deployment lifecycle through `timestamps.queued`, `timestamps.active`, `timestamps.succeeded`, and `timestamps.failed`, while the current poller still expects generic `state`/`status` fields.

## Next change / Run #9

Run #9 is the consolidation run. The poller accepts correlation by `deploy_id`, `task_id`, or legacy `id`, derives state from the observed cPanel timestamp model with fail-first precedence, tolerates a bounded initial visibility delay, and retains the legacy state/status fallback for test compatibility. The same run then continues through the already-written isolated Fileman upload/overwrite checks, success worker execution, deliberate non-zero failure propagation, request/result correlation, and unchanged-controller-HEAD retrigger check. A machine-readable `capabilities.json` is emitted only if the full probe reaches the end successfully.

No Porat Staff DEV/PROD application roots, database, weather ingestion, SSH/SCP path, or deferred SamBoat/Google Calendar work are part of Run #9.

## Adoption gates still outstanding

A production-capable SSH-less design is not approved yet. Phase 2 still needs to prove Fileman upload semantics, isolated cPanel-managed controller repository behavior, VersionControlDeployment create/retrieve and terminal statuses, deliberate non-zero failure propagation, unchanged-controller-HEAD retriggering, request/task/result correlation, execution environment/tool availability, bounded timeout behavior, and repeated DEV-only success. The broad cPanel API-token risk also requires explicit review before any production adoption.
