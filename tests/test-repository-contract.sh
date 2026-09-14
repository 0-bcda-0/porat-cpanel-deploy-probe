#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
workflow="$repo_root/.github/workflows/cpanel-capability-probe.yml"
controller="$repo_root/.cpanel.yml"
worker="$repo_root/probe-worker.sh"

fail() { printf 'FAIL  %s\n' "$1" >&2; exit 1; }

grep_bin="${AUDIT_GREP_BIN:-grep}"
command -v "$grep_bin" >/dev/null 2>&1 || fail 'required safety-audit grep is unavailable'

[[ -f "$workflow" && -f "$controller" && -f "$worker" ]] || fail 'probe workflow/controller files are missing'
grep -Fq 'workflow_dispatch:' "$workflow" || fail 'workflow is not manually dispatched'
! grep -Eq '^  (push|pull_request):' "$workflow" || fail 'workflow has an automatic trigger'
grep -Fq 'runs-on: ubuntu-24.04' "$workflow" || fail 'workflow is not pinned to ubuntu-24.04'
grep -Fq 'environment: development' "$workflow" || fail 'workflow is not bound to development'
grep -Fq 'CPANEL_API_TOKEN: ${{ secrets.CPANEL_API_TOKEN }}' "$workflow" || fail 'workflow does not consume the dedicated secret'
grep -Fq 'tests/test-audit-tooling.sh' "$workflow" || fail 'workflow does not run the missing-audit-tool regression'
! grep -Eq '^      CPANEL_CONTROLLER_CLONE_URL:' "$workflow" || fail 'controller clone URL leaks into local safety-test environment'
grep -Eq '^          CPANEL_CONTROLLER_CLONE_URL: https://github.com/0-bcda-0/porat-cpanel-deploy-probe.git$' "$workflow" || fail 'live step lacks the exact controller clone URL'

if "$grep_bin" -Eri '(ssh|scp|rsync|DEPLOY_SSH|id_ed25519)' "$workflow" "$controller" "$worker" "$repo_root/scripts"; then
  fail 'SSH transport appeared in probe implementation'
fi
if "$grep_bin" -Er '/home/echosline/(apps/porat-staff|bcda\.com\.hr|porat-staff\.com\.hr|public_html)' "$repo_root" --exclude-dir=.git; then
  fail 'live application or public root appeared in probe repository'
fi
grep -Fq '/home/echosline/cpanel-deploy-probe' "$worker" || fail 'worker is not confined to the approved probe root'
grep -Fq 'StrictHostKeyChecking' "$repo_root/scripts/cpanel-uapi-probe.sh" && fail 'SSH option appeared in UAPI client'

echo 'Probe repository contract tests passed.'
