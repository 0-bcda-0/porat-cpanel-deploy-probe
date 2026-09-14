#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
worker="$repo_root/probe-worker.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fail(){ echo "FAIL $1" >&2; exit 1; }
pass(){ echo "PASS $1"; }

probe="$tmp/probe"
app="$tmp/app"
mkdir -p "$probe/inbox" "$probe/results" "$app/uploads" "$app/bin" "$tmp/public"

cat >"$app/bin/deploy-release.sh" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >"${MOCK_CAPTURE:?}"
printf '%s\n' "${PORAT_DEPLOY_APP_ROOT}" >>"${MOCK_CAPTURE}"
printf '%s\n' "${PORAT_DEPLOY_PUBLIC_ROOT}" >>"${MOCK_CAPTURE}"
printf '%s\n' "${PORAT_DEPLOY_BASE_URL}" >>"${MOCK_CAPTURE}"
printf '%s\n' "${PORAT_DEPLOY_EXPECTED_SESSION_COOKIE}" >>"${MOCK_CAPTURE}"
exit "${MOCK_EXIT:-0}"
MOCK
chmod +x "$app/bin/deploy-release.sh"

run_worker(){
  PORAT_CONTROLLER_PROBE_ROOT="$probe" \
  PORAT_CONTROLLER_DEV_APP_ROOT="$app" \
  PORAT_CONTROLLER_DEV_PUBLIC_ROOT="$tmp/public" \
  PORAT_CONTROLLER_DEV_BASE_URL='https://bcda.com.hr' \
  PORAT_CONTROLLER_DEV_COOKIE='porat_staff_dev_session' \
  MOCK_CAPTURE="$tmp/capture" MOCK_EXIT="${MOCK_EXIT:-0}" \
  bash "$worker"
}

sha='0123456789abcdef0123456789abcdef01234567'
sum='aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
printf 'archive' >"$app/uploads/$sha.tar.gz"
cat >"$probe/inbox/current.request" <<REQ
request_id=test-1
operation=deploy-development
sha=$sha
checksum=$sum
REQ
run_worker || fail 'valid DEV request failed'
grep -Fxq "deploy $sha $app/uploads/$sha.tar.gz $sum" "$tmp/capture" || fail 'deployer arguments incorrect'
grep -Fxq "$tmp/public" "$tmp/capture" || fail 'public root not derived'
grep -Fxq 'https://bcda.com.hr' "$tmp/capture" || fail 'base URL not derived'
grep -Fxq 'porat_staff_dev_session' "$tmp/capture" || fail 'cookie not derived'
grep -Fxq 'outcome=success' "$probe/results/test-1.result" || fail 'success result missing'
[[ ! -e "$app/uploads/$sha.tar.gz" ]] || fail 'archive not cleaned'
pass 'valid development deployment request'

cat >"$probe/inbox/current.request" <<REQ
request_id=test-2
operation=deploy-production
sha=$sha
checksum=$sum
REQ
set +e; run_worker >"$tmp/out" 2>&1; st=$?; set -e
[[ $st -eq 64 ]] || fail 'production operation was not rejected'
pass 'production operation rejected'

cat >"$probe/inbox/current.request" <<REQ
request_id=test-3
operation=deploy-development
sha=../../bad
checksum=$sum
REQ
set +e; run_worker >"$tmp/out" 2>&1; st=$?; set -e
[[ $st -eq 64 ]] || fail 'invalid SHA was not rejected'
pass 'invalid SHA rejected'

printf 'archive' >"$app/uploads/$sha.tar.gz"
cat >"$probe/inbox/current.request" <<REQ
request_id=test-4
operation=deploy-development
sha=$sha
checksum=$sum
path=/home/echosline/public_html
REQ
set +e; run_worker >"$tmp/out" 2>&1; st=$?; set -e
[[ $st -eq 64 ]] || fail 'arbitrary request field was not rejected'
pass 'arbitrary path field rejected'

printf 'archive' >"$app/uploads/$sha.tar.gz"
cat >"$probe/inbox/current.request" <<REQ
request_id=test-5
operation=deploy-development
sha=$sha
checksum=$sum
REQ
MOCK_EXIT=42
set +e; run_worker >"$tmp/out" 2>&1; st=$?; set -e
[[ $st -eq 42 ]] || fail 'deployer failure not propagated'
grep -Fxq 'outcome=failure' "$probe/results/test-5.result" || fail 'failure result missing'
grep -Fxq 'exit_status=42' "$probe/results/test-5.result" || fail 'failure exit status missing'
pass 'deployer failure propagated'

echo 'All controller tests passed.'
