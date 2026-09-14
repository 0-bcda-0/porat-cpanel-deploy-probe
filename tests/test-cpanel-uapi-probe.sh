#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
probe="$repo_root/scripts/cpanel-uapi-probe.sh"
test_root="$(mktemp -d)"
trap 'rm -rf -- "$test_root"' EXIT

fail() { printf 'FAIL  %s\n' "$1" >&2; exit 1; }
pass() { printf 'PASS  %s\n' "$1"; }

set +e
CPANEL_API_BASE_URL=https://example.com:2083 CPANEL_USER=echosline CPANEL_API_TOKEN=dummy "$probe" validate-config >"$test_root/origin.out" 2>&1
status=$?
set -e
[[ $status -eq 64 ]] || fail 'unapproved API origin was not rejected'
grep -Fq 'API origin is not approved' "$test_root/origin.out" || fail 'origin rejection was not explicit'
pass 'exact API origin allowlist'

printf '{broken' >"$test_root/malformed.json"
set +e
CPANEL_API_TOKEN=dummy "$probe" parse-response "$test_root/malformed.json" >"$test_root/malformed.out" 2>&1
status=$?
set -e
[[ $status -ne 0 ]] || fail 'malformed JSON was accepted'
grep -Fq 'Malformed UAPI JSON response' "$test_root/malformed.out" || fail 'malformed JSON error was unclear'
pass 'malformed UAPI JSON rejection'

printf '%s\n' '{"result":{"status":1,"data":{"deploy_id":"41"},"errors":null}}' >"$test_root/success.json"
[[ "$(CPANEL_API_TOKEN=dummy "$probe" parse-response "$test_root/success.json")" == '{"deploy_id":"41"}' ]] || fail 'successful UAPI data was not returned'
pass 'UAPI success parsing'

secret='probe-token-must-not-leak'
printf '%s\n' "{\"result\":{\"status\":0,\"data\":null,\"errors\":[\"denied $secret\"]}}" >"$test_root/failure.json"
set +e
CPANEL_API_TOKEN="$secret" "$probe" parse-response "$test_root/failure.json" >"$test_root/failure.out" 2>&1
status=$?
set -e
[[ $status -ne 0 ]] || fail 'failed UAPI envelope was accepted'
grep -Fq 'UAPI request failed' "$test_root/failure.out" || fail 'UAPI failure was unclear'
! grep -Fq "$secret" "$test_root/failure.out" || fail 'secret appeared in UAPI error output'
pass 'UAPI failure parsing and secret-safe errors'

mkdir -p "$test_root/bin"
cat >"$test_root/bin/curl" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
response="${MOCK_RESPONSE_DIR:?}/$(cat "${MOCK_COUNTER:?}").json"
count="$(cat "${MOCK_COUNTER:?}")"
printf '%s\n' "$((count + 1))" >"${MOCK_COUNTER:?}"
cat "$response"
MOCK
chmod +x "$test_root/bin/curl"

run_poll() {
  local response_dir="$1" attempts="$2"
  printf '0\n' >"$test_root/counter"
  env CPANEL_API_BASE_URL=https://cp077.mydataknox.com:2083 \
    CPANEL_USER=echosline CPANEL_API_TOKEN=dummy CPANEL_CURL_BIN="$test_root/bin/curl" \
    CPANEL_POLL_INTERVAL_SECONDS=0 CPANEL_POLL_MAX_ATTEMPTS="$attempts" \
    MOCK_RESPONSE_DIR="$response_dir" MOCK_COUNTER="$test_root/counter" \
    "$probe" poll-deployment 41
}

mkdir -p "$test_root/unexpected"
printf '%s\n' '{"result":{"status":1,"data":[{"id":"41","state":"mystery"}],"errors":null}}' >"$test_root/unexpected/0.json"
set +e; run_poll "$test_root/unexpected" 1 >"$test_root/unexpected.out" 2>&1; status=$?; set -e
[[ $status -eq 65 ]] || fail 'unexpected deployment status did not fail closed'
grep -Fq 'Unexpected deployment status: mystery' "$test_root/unexpected.out" || fail 'unexpected status was not identified'
pass 'unexpected deployment status rejection'

mkdir -p "$test_root/timeout"
printf '%s\n' '{"result":{"status":1,"data":[{"id":"41","state":"processing"}],"errors":null}}' >"$test_root/timeout/0.json"
cp "$test_root/timeout/0.json" "$test_root/timeout/1.json"
set +e; run_poll "$test_root/timeout" 2 >"$test_root/timeout.out" 2>&1; status=$?; set -e
[[ $status -eq 75 ]] || fail 'bounded polling did not time out'
grep -Fq 'Polling timed out; deployment was not retriggered' "$test_root/timeout.out" || fail 'timeout safety message was missing'
[[ "$(cat "$test_root/counter")" -eq 2 ]] || fail 'poller exceeded its attempt bound'
pass 'bounded polling timeout without retrigger'

set +e
CPANEL_API_BASE_URL=https://cp077.mydataknox.com:2083 CPANEL_USER=echosline CPANEL_API_TOKEN=dummy \
  "$probe" run-live-probe >"$test_root/live-config.out" 2>&1
status=$?
set -e
[[ $status -eq 64 ]] || fail 'live probe accepted missing controller clone URL'
grep -Fq 'Controller clone URL is not approved' "$test_root/live-config.out" || fail 'live probe clone URL failure was unclear'
pass 'exact public controller clone URL allowlist'

echo 'All cPanel UAPI probe tests passed.'
