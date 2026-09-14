#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
probe="$repo_root/scripts/cpanel-uapi-probe.sh"
test_root="$(mktemp -d)"
trap 'rm -rf -- "$test_root"' EXIT

fail() { printf 'FAIL  %s\n' "$1" >&2; exit 1; }
pass() { printf 'PASS  %s\n' "$1"; }

grep -Fq "temp_root=''" "$probe" || fail 'cleanup root is not initialized before the EXIT trap'
grep -Fq '[[ -z "${temp_root:-}" ]]' "$probe" || fail 'cleanup trap is not safe for an unset/empty root'

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

printf '%s\n' '{"status":1,"data":{"deploy_id":"42"},"errors":null,"messages":null,"metadata":{},"warnings":null}' >"$test_root/flat-success.json"
[[ "$(CPANEL_API_TOKEN=dummy "$probe" parse-response "$test_root/flat-success.json")" == '{"deploy_id":"42"}' ]] || fail 'flattened UAPI success envelope was not parsed'
flat_summary="$(CPANEL_API_TOKEN=dummy "$probe" summarize-response "$test_root/flat-success.json")"
grep -Fq '"envelope_shape":"flat-result"' <<<"$flat_summary" || fail 'flattened UAPI envelope shape was not identified'
grep -Fq '"status":1' <<<"$flat_summary" || fail 'flattened UAPI summary omitted top-level status'
grep -Fq '"data_type":"object"' <<<"$flat_summary" || fail 'flattened UAPI summary omitted data type'
pass 'flattened UAPI success parsing and safe summary'

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

sensitive_value='private-user-value-must-not-leak'
printf '%s\n' "{\"apiversion\":3,\"module\":\"Variables\",\"func\":\"get_user_information\",\"result\":{\"status\":0,\"data\":{\"home\":\"$sensitive_value\"},\"errors\":null,\"messages\":[],\"warnings\":null,\"metadata\":{\"reason\":\"$sensitive_value\"}}}" >"$test_root/diagnostic.json"
set +e
CPANEL_API_TOKEN="$secret" "$probe" summarize-response "$test_root/diagnostic.json" >"$test_root/diagnostic.out" 2>&1
status=$?
set -e
[[ $status -eq 0 ]] || fail 'safe UAPI envelope summary command failed'
grep -Fq '"status":0' "$test_root/diagnostic.out" || fail 'safe UAPI envelope summary omitted status'
grep -Fq '"data_type":"object"' "$test_root/diagnostic.out" || fail 'safe UAPI envelope summary omitted data type'
grep -Fq '"errors_type":"null"' "$test_root/diagnostic.out" || fail 'safe UAPI envelope summary omitted errors type'
grep -Fq '"messages_type":"array"' "$test_root/diagnostic.out" || fail 'safe UAPI envelope summary omitted messages type'
grep -Fq '"warnings_type":"null"' "$test_root/diagnostic.out" || fail 'safe UAPI envelope summary omitted warnings type'
grep -Fq '"metadata_type":"object"' "$test_root/diagnostic.out" || fail 'safe UAPI envelope summary omitted metadata type'
! grep -Fq "$sensitive_value" "$test_root/diagnostic.out" || fail 'safe UAPI envelope summary leaked response values'
pass 'safe UAPI failure envelope structure summary'

retrieve_sensitive='private-author-and-message-must-not-leak'
cat >"$test_root/deployment-retrieve.json" <<JSON
[{"deploy_id":7,"task_id":"task/old","repository_root":"/private/old","timestamps":{"queued":"1","succeeded":"2"},"repository_state":{"author":"$retrieve_sensitive"}},{"deploy_id":13,"task_id":"task/current","repository_root":"/private/current","timestamps":{"queued":"3","active":"4"},"repository_state":{"message":"$retrieve_sensitive"}}]
JSON
deployment_summary="$(CPANEL_API_TOKEN=dummy "$probe" summarize-deployment-retrieve "$test_root/deployment-retrieve.json" 13)"
grep -Fq '"data_type":"array"' <<<"$deployment_summary" || fail 'deployment retrieve summary omitted data type'
grep -Fq '"count":2' <<<"$deployment_summary" || fail 'deployment retrieve summary omitted item count'
grep -Fq '"deploy_id":13' <<<"$deployment_summary" || fail 'deployment retrieve summary omitted deploy identifier'
grep -Fq '"task_id":"task/current"' <<<"$deployment_summary" || fail 'deployment retrieve summary omitted task identifier'
grep -Fq '"matching_indices":[1]' <<<"$deployment_summary" || fail 'deployment retrieve summary did not correlate the requested identifier'
grep -Fq '"timestamp_key_sets"' <<<"$deployment_summary" || fail 'deployment retrieve summary omitted timestamp key sets'
! grep -Fq "$retrieve_sensitive" <<<"$deployment_summary" || fail 'deployment retrieve summary leaked repository state values'
! grep -Fq '/private/' <<<"$deployment_summary" || fail 'deployment retrieve summary leaked repository roots'
pass 'safe deployment retrieve shape and identifier summary'

mkdir -p "$test_root/bin"
cat >"$test_root/bin/curl" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail

output=''
while (($#)); do
  case "$1" in
    --output)
      output="$2"
      shift 2
      ;;
    --write-out)
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done

[[ -n "$output" ]] || { printf 'mock curl missing --output\n' >&2; exit 98; }

if [[ -n "${MOCK_COUNTER:-}" ]]; then
  count="$(cat "$MOCK_COUNTER")"
  response="${MOCK_RESPONSE_DIR:?}/$count.json"
  printf '%s\n' "$((count + 1))" >"$MOCK_COUNTER"
  cat "$response" >"$output"
else
  printf '%s' "${MOCK_BODY:-}" >"$output"
fi

printf '%s\t%s\t%s\t%s' \
  "${MOCK_HTTP_CODE:-200}" \
  "${MOCK_CONTENT_TYPE:-application/json}" \
  "${MOCK_REDIRECT_URL:-}" \
  "${MOCK_EFFECTIVE_URL:-https://cp077.mydataknox.com:2083/execute/mock}"
MOCK
chmod +x "$test_root/bin/curl"

run_poll() {
  local response_dir="$1" attempts="$2"
  printf '0\n' >"$test_root/counter"
  env CPANEL_API_BASE_URL=https://cp077.mydataknox.com:2083 \
    CPANEL_USER=echosline CPANEL_API_TOKEN=dummy CPANEL_CURL_BIN="$test_root/bin/curl" \
    CPANEL_POLL_INTERVAL_SECONDS=0 CPANEL_POLL_MAX_ATTEMPTS="$attempts" \
    MOCK_RESPONSE_DIR="$response_dir" MOCK_COUNTER="$test_root/counter" \
    MOCK_HTTP_CODE=200 MOCK_CONTENT_TYPE=application/json \
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

mkdir -p "$test_root/http-success"
printf '%s\n' '{"result":{"status":1,"data":[{"id":"41","state":"success"}],"errors":null}}' >"$test_root/http-success/0.json"
run_poll "$test_root/http-success" 1 >"$test_root/http-success.out" 2>&1 || fail 'HTTP 200 JSON response did not pass'
grep -Fq 'Deployment task 41 succeeded with status success' "$test_root/http-success.out" || fail 'HTTP 200 JSON response was not parsed'
pass 'HTTP 2xx JSON accepted'

run_http_failure() {
  local label="$1" code="$2" content_type="$3" body="$4" redirect="${5:-}"
  local output="$test_root/http-$label.out"
  set +e
  env CPANEL_API_BASE_URL=https://cp077.mydataknox.com:2083 \
    CPANEL_USER=echosline CPANEL_API_TOKEN="$secret" CPANEL_CURL_BIN="$test_root/bin/curl" \
    CPANEL_POLL_INTERVAL_SECONDS=0 CPANEL_POLL_MAX_ATTEMPTS=1 \
    MOCK_HTTP_CODE="$code" MOCK_CONTENT_TYPE="$content_type" MOCK_BODY="$body" \
    MOCK_REDIRECT_URL="$redirect" \
    "$probe" poll-deployment 41 >"$output" 2>&1
  status=$?
  set -e
  [[ $status -ne 0 ]] || fail "$label HTTP response was accepted"
  ! grep -Fq "$secret" "$output" || fail "$label HTTP classification leaked token"
  ! grep -Fq "$body" "$output" || fail "$label HTTP classification leaked raw response body"
}

html_body='<html><body>private diagnostic page</body></html>'
run_http_failure html 200 text/html "$html_body"
grep -Fq 'UAPI HTTP 2xx response was non-JSON: status=200 content_type=text/html' "$test_root/http-html.out" || fail 'HTTP 200 HTML was not safely classified'
grep -Fq 'body_bytes=' "$test_root/http-html.out" || fail 'HTTP 200 HTML classification omitted byte count'
grep -Fq 'body_sha256=' "$test_root/http-html.out" || fail 'HTTP 200 HTML classification omitted body hash'
pass 'HTTP 2xx non-JSON classified without body disclosure'

redirect_body='<html>redirect</html>'
run_http_failure redirect 302 text/html "$redirect_body" "https://cp077.mydataknox.com:2083/login/?token=$secret"
grep -Fq 'UAPI HTTP redirect rejected: status=302' "$test_root/http-redirect.out" || fail 'HTTP redirect was not rejected distinctly'
pass 'HTTP 3xx redirect rejected without token disclosure'

for code in 401 403; do
  auth_body="access denied $code"
  run_http_failure "auth-$code" "$code" text/html "$auth_body"
  grep -Fq "UAPI HTTP authentication/access failure: status=$code" "$test_root/http-auth-$code.out" || fail "HTTP $code was not classified as auth/access failure"
done
pass 'HTTP 401/403 classified safely'

cat >"$test_root/bin/no-network" <<'MOCK'
#!/usr/bin/env bash
printf 'network sentinel invoked\n' >&2
exit 99
MOCK
chmod +x "$test_root/bin/no-network"

assert_clone_url_rejected() {
  local label="$1" value="${2-__unset__}" output status
  output="$test_root/clone-$label.out"
  set +e
  if [[ "$value" == __unset__ ]]; then
    env -u CPANEL_CONTROLLER_CLONE_URL \
      CPANEL_API_BASE_URL=https://cp077.mydataknox.com:2083 CPANEL_USER=echosline CPANEL_API_TOKEN=dummy \
      CPANEL_CURL_BIN="$test_root/bin/no-network" "$probe" run-live-probe >"$output" 2>&1
  else
    CPANEL_API_BASE_URL=https://cp077.mydataknox.com:2083 CPANEL_USER=echosline CPANEL_API_TOKEN=dummy \
      CPANEL_CURL_BIN="$test_root/bin/no-network" CPANEL_CONTROLLER_CLONE_URL="$value" \
      "$probe" run-live-probe >"$output" 2>&1
  fi
  status=$?
  set -e
  [[ $status -eq 64 ]] || fail "live probe accepted $label controller clone URL"
  grep -Fq 'Controller clone URL is not approved' "$output" || fail "$label clone URL failure was unclear"
  ! grep -Fq 'network sentinel invoked' "$output" || fail "$label clone URL reached the network layer"
}

assert_clone_url_rejected missing
assert_clone_url_rejected empty ''
assert_clone_url_rejected malformed 'not-a-url'
assert_clone_url_rejected alternate 'https://github.com/0-bcda-0/another-repository.git'
assert_clone_url_rejected ssh-form 'git@github.com:0-bcda-0/porat-cpanel-deploy-probe.git'
assert_clone_url_rejected credential-bearing 'https://user:token@github.com/0-bcda-0/porat-cpanel-deploy-probe.git'
assert_clone_url_rejected arbitrary 'https://example.com/controller.git'
pass 'exact public controller clone URL allowlist before network access'

grep -Fq -- "--data-urlencode 'type=git'" "$probe" || fail 'VersionControl create omits required type=git parameter'
grep -Fq -- '--data-urlencode "source_repository=$source_repository"' "$probe" || fail 'VersionControl create omits source_repository payload'
grep -Fq -- 'source_repository="$(jq -cn --arg url "$clone_url"' "$probe" || fail 'source_repository JSON is not generated from the approved clone URL'
grep -Fq -- '{remote_name:"origin",url:$url}' "$probe" || fail 'source_repository JSON does not pin origin as the remote name'
! grep -Fq -- '--data-urlencode "clone_url=$clone_url"' "$probe" || fail 'obsolete clone_url parameter is still used for VersionControl create'
pass 'VersionControl create uses required git repository parameters'
grep -Fq -- '.source_repository.url' "$probe" || fail 'existing repository validation does not read source_repository.url'
pass 'existing repository validation reads the documented source URL field'

set +e
CPANEL_API_BASE_URL=https://cp077.mydataknox.com:2083 CPANEL_USER=echosline CPANEL_API_TOKEN=dummy \
  CPANEL_CURL_BIN="$test_root/bin/no-network" \
  CPANEL_CONTROLLER_CLONE_URL=https://github.com/0-bcda-0/porat-cpanel-deploy-probe.git \
  "$probe" run-live-probe >"$test_root/first-request-failure.out" 2>&1
status=$?
set -e
[[ $status -ne 0 ]] || fail 'failed first HTTPS request was accepted'
grep -Fq 'HTTPS UAPI structure probe request failed' "$test_root/first-request-failure.out" || fail 'first HTTPS failure was not reported'
! grep -Fq 'unbound variable' "$test_root/first-request-failure.out" || fail 'cleanup produced a secondary unbound-variable error'
pass 'clean exit after failed first HTTPS request'

echo 'All cPanel UAPI probe tests passed.'
