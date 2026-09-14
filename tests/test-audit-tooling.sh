#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
output="$(mktemp)"
trap 'rm -f -- "$output"' EXIT

set +e
AUDIT_GREP_BIN=definitely-not-installed "$repo_root/tests/test-repository-contract.sh" >"$output" 2>&1
status=$?
set -e

[[ $status -ne 0 ]]
grep -Fq 'required safety-audit grep is unavailable' "$output"
echo 'Missing safety-audit tooling fails closed.'
