#!/usr/bin/env bash
set -euo pipefail
umask 077

readonly approved_api_origin='https://cp077.mydataknox.com:2083'
readonly approved_cpanel_user='echosline'
readonly approved_controller_clone_url='https://github.com/0-bcda-0/porat-cpanel-deploy-probe.git'
readonly probe_root='/home/echosline/cpanel-deploy-probe'
readonly controller_root="$probe_root/controller"
temp_root=''

cleanup() {
  [[ -z "${temp_root:-}" ]] || rm -rf -- "$temp_root"
}
trap cleanup EXIT

safe_error() {
  local message="$1" token="${CPANEL_API_TOKEN:-}"
  if [[ -n "$token" ]]; then
    message="${message//"$token"/[REDACTED]}"
  fi
  printf '%s\n' "$message" >&2
}

validate_config() {
  if [[ "${CPANEL_API_BASE_URL:-}" != "$approved_api_origin" ]]; then
    safe_error 'API origin is not approved'
    return 64
  fi
  if [[ "${CPANEL_USER:-}" != "$approved_cpanel_user" ]]; then
    safe_error 'cPanel user is not approved'
    return 64
  fi
  if [[ -z "${CPANEL_API_TOKEN:-}" ]]; then
    safe_error 'CPANEL_API_TOKEN is required'
    return 64
  fi
}

parse_response() {
  local response_file="$1" status data errors
  if ! jq -e . "$response_file" >/dev/null 2>&1; then
    safe_error 'Malformed UAPI JSON response'
    return 65
  fi
  status="$(jq -r '.result.status // empty' "$response_file")"
  if [[ "$status" != 1 ]]; then
    errors="$(jq -c '.result.errors // ["unspecified UAPI error"]' "$response_file")"
    safe_error "UAPI request failed: $errors"
    return 1
  fi
  data="$(jq -c '.result.data' "$response_file")"
  printf '%s\n' "$data"
}

uapi_get() {
  local endpoint="$1" response_file curl_bin="${CPANEL_CURL_BIN:-curl}"
  shift
  validate_config
  response_file="$(mktemp)"
  if ! "$curl_bin" --silent --show-error --fail-with-body \
    --connect-timeout 10 --max-time 30 \
    --header "Authorization: cpanel ${CPANEL_USER}:${CPANEL_API_TOKEN}" \
    --get "${CPANEL_API_BASE_URL}/execute/${endpoint}" "$@" >"$response_file"; then
    safe_error 'HTTPS UAPI request failed'
    rm -f -- "$response_file"
    return 1
  fi
  parse_response "$response_file"
  rm -f -- "$response_file"
}

uapi_upload() {
  local directory="$1" source="$2" filename="$3" response_file
  local curl_bin="${CPANEL_CURL_BIN:-curl}"
  validate_config
  response_file="$(mktemp)"
  if ! "$curl_bin" --silent --show-error --fail-with-body \
    --connect-timeout 10 --max-time 30 \
    --header "Authorization: cpanel ${CPANEL_USER}:${CPANEL_API_TOKEN}" \
    --form-string "dir=$directory" \
    --form "file-1=@${source};filename=${filename}" \
    "${CPANEL_API_BASE_URL}/execute/Fileman/upload_files" >"$response_file"; then
    safe_error 'HTTPS Fileman upload failed'
    rm -f -- "$response_file"
    return 1
  fi
  parse_response "$response_file"
  rm -f -- "$response_file"
}

uapi_envelope_summary() {
  local endpoint="$1" response_file curl_bin="${CPANEL_CURL_BIN:-curl}"
  shift
  validate_config
  response_file="$(mktemp)"
  if ! "$curl_bin" --silent --show-error --fail-with-body \
    --connect-timeout 10 --max-time 30 \
    --header "Authorization: cpanel ${CPANEL_USER}:${CPANEL_API_TOKEN}" \
    --get "${CPANEL_API_BASE_URL}/execute/${endpoint}" "$@" >"$response_file"; then
    safe_error 'HTTPS UAPI structure probe failed'
    rm -f -- "$response_file"
    return 1
  fi
  if ! jq -e . "$response_file" >/dev/null 2>&1; then
    safe_error 'Malformed UAPI JSON response'
    rm -f -- "$response_file"
    return 65
  fi
  jq -c '{top_level_keys:(keys|sort),result_keys:(.result|keys|sort),status:.result.status,data_type:(.result.data|type),errors_type:(.result.errors|type)}' "$response_file"
  rm -f -- "$response_file"
}

poll_deployment() {
  local deploy_id="$1" attempts="${CPANEL_POLL_MAX_ATTEMPTS:-30}"
  local interval="${CPANEL_POLL_INTERVAL_SECONDS:-5}" attempt data state
  [[ "$deploy_id" =~ ^[A-Za-z0-9._:-]+$ ]] || { safe_error 'Invalid deployment task ID'; return 64; }
  [[ "$attempts" =~ ^[1-9][0-9]*$ ]] || { safe_error 'Invalid polling attempt bound'; return 64; }
  [[ "$interval" =~ ^[0-9]+$ ]] || { safe_error 'Invalid polling interval'; return 64; }

  for ((attempt = 1; attempt <= attempts; attempt++)); do
    data="$(uapi_get 'VersionControlDeployment/retrieve')"
    state="$(jq -r --arg id "$deploy_id" '
      [.[] | select(((.id // .deploy_id // "") | tostring) == $id)][0]
      | (.state // .status // empty)
    ' <<<"$data")"
    if [[ -z "$state" ]]; then
      safe_error 'Deployment task was not present in retrieve response'
      return 65
    fi
    case "$state" in
      success|succeeded|complete|completed)
        printf 'Deployment task %s succeeded with status %s\n' "$deploy_id" "$state"
        return 0
        ;;
      failed|failure|error)
        safe_error "Deployment task $deploy_id failed with status $state"
        return 1
        ;;
      queued|waiting|pending|processing|running)
        ;;
      *)
        safe_error "Unexpected deployment status: $state"
        return 65
        ;;
    esac
    if ((attempt < attempts)); then sleep "$interval"; fi
  done
  safe_error 'Polling timed out; deployment was not retriggered'
  return 75
}

create_deployment() {
  local data deploy_id
  data="$(uapi_get 'VersionControlDeployment/create' --data-urlencode "repository_root=$controller_root")"
  deploy_id="$(jq -r '
    if type == "object" then (.deploy_id // .id // .task_id // empty)
    elif type == "string" or type == "number" then tostring
    else empty end
  ' <<<"$data")"
  [[ -n "$deploy_id" ]] || { safe_error 'Deployment create response did not contain a task ID'; return 65; }
  printf '%s\n' "$deploy_id"
}

ensure_controller_repository() {
  local clone_url="$1" repositories matches
  [[ "$clone_url" == "$approved_controller_clone_url" ]] || {
    safe_error 'Controller clone URL is not approved'
    return 64
  }
  repositories="$(uapi_get 'VersionControl/retrieve')"
  matches="$(jq -r --arg root "$controller_root" '[.[] | select(.repository_root == $root)] | length' <<<"$repositories")"
  case "$matches" in
    0)
      uapi_get 'VersionControl/create' \
        --data-urlencode "repository_root=$controller_root" \
        --data-urlencode 'name=porat-cpanel-deploy-probe' \
        --data-urlencode "clone_url=$clone_url" >/dev/null
      ;;
    1)
      local registered_url
      registered_url="$(jq -r --arg root "$controller_root" '.[] | select(.repository_root == $root) | (.clone_url // .source_repository // .url // empty)' <<<"$repositories")"
      if [[ -n "$registered_url" && "$registered_url" != "$clone_url" ]]; then
        safe_error 'Existing probe repository has an unexpected clone URL'
        return 65
      fi
      ;;
    *) safe_error 'Multiple controller repositories matched the approved root'; return 65 ;;
  esac
}

remote_file_content() {
  local directory="$1" filename="$2" data
  data="$(uapi_get 'Fileman/get_file_content' \
    --data-urlencode "dir=$directory" --data-urlencode "file=$filename")"
  jq -r 'if type == "string" then . else (.content // .file_content // empty) end' <<<"$data"
}

write_request() {
  local file="$1" request_id="$2" mode="$3"
  printf 'request_id=%s\nmode=%s\n' "$request_id" "$mode" >"$file"
}

run_one_probe() {
  local request_id="$1" mode="$2" request_file="$3" deploy_id poll_output result
  write_request "$request_file" "$request_id" "$mode"
  uapi_upload 'cpanel-deploy-probe/inbox' "$request_file" 'current.request' >/dev/null
  deploy_id="$(create_deployment)"
  if [[ "$mode" == fail ]]; then
    set +e
    poll_output="$(poll_deployment "$deploy_id" 2>&1)"
    local status=$?
    set -e
    [[ $status -eq 1 ]] || { safe_error "Deliberate failure task was not reported as failed: $poll_output"; return 65; }
  else
    poll_output="$(poll_deployment "$deploy_id")"
  fi
  result="$(remote_file_content 'cpanel-deploy-probe/results' "$request_id.result")"
  grep -Fxq "request_id=$request_id" <<<"$result" || { safe_error 'Request/result correlation failed'; return 65; }
  grep -Fxq "mode=$mode" <<<"$result" || { safe_error 'Controller result mode did not match request'; return 65; }
  printf '%s|%s|%s\n' "$deploy_id" "$poll_output" "$result"
}

run_live_probe() {
  local clone_url="${CPANEL_CONTROLLER_CLONE_URL:-}" fixture request_file
  local bootstrap_id first second deliberate first_head second_head info success_format failure_format
  validate_config
  [[ "$clone_url" == "$approved_controller_clone_url" ]] || {
    safe_error 'Controller clone URL is not approved'
    return 64
  }
  temp_root="$(mktemp -d)"
  mkdir -p probe-results

  uapi_get 'Variables/get_user_information' >/dev/null
  success_format="$(uapi_envelope_summary 'Variables/get_user_information')"
  ensure_controller_repository "$clone_url"

  bootstrap_id="$(create_deployment)"
  poll_deployment "$bootstrap_id" >"$temp_root/bootstrap.status"

  fixture="$temp_root/upload-fixture.txt"
  printf 'first fixture value\n' >"$fixture"
  uapi_upload 'cpanel-deploy-probe/inbox' "$fixture" 'upload-fixture.txt' >"$temp_root/upload-relative.json"
  printf 'second fixture value\n' >"$fixture"
  uapi_upload '/home/echosline/cpanel-deploy-probe/inbox' "$fixture" 'upload-fixture.txt' >"$temp_root/upload-absolute.json"
  [[ "$(remote_file_content 'cpanel-deploy-probe/inbox' 'upload-fixture.txt')" == 'second fixture value' ]] || {
    safe_error 'Fileman collision did not produce the expected observable content'
    return 65
  }
  info="$(uapi_get 'Fileman/get_file_information' --data-urlencode 'path=/home/echosline/cpanel-deploy-probe/inbox/upload-fixture.txt')"
  failure_format="$(uapi_envelope_summary 'Fileman/get_file_content' \
    --data-urlencode 'dir=cpanel-deploy-probe/inbox' \
    --data-urlencode 'file=harmless-does-not-exist')"
  [[ "$(jq -r '.status' <<<"$failure_format")" != 1 ]] || {
    safe_error 'Harmless missing-file request did not produce a UAPI failure envelope'
    return 65
  }

  request_file="$temp_root/current.request"
  local prefix="gh-${GITHUB_RUN_ID:-local}-${GITHUB_RUN_ATTEMPT:-1}"
  first="$(run_one_probe "$prefix-success-1" success "$request_file")"
  second="$(run_one_probe "$prefix-success-2" success "$request_file")"
  deliberate="$(run_one_probe "$prefix-failure" fail "$request_file")"
  first_head="$(cut -d'|' -f3- <<<"$first" | sed -n 's/^controller_head=//p')"
  second_head="$(cut -d'|' -f3- <<<"$second" | sed -n 's/^controller_head=//p')"
  [[ -n "$first_head" && "$first_head" == "$second_head" ]] || {
    safe_error 'Unchanged-controller-HEAD retrigger was not proven'
    return 65
  }

  {
    printf '# cPanel capability probe observations\n\n'
    printf '- Date (UTC): `%s`\n' "$(date -u +%Y-%m-%d)"
    printf '- API origin: `%s` (normal curl TLS verification)\n' "$approved_api_origin"
    printf '- Probe root: `%s`\n' "$probe_root"
    printf '- Controller HEAD reused: `%s`\n' "$first_head"
    printf '- Bootstrap task ID: `%s`\n' "$bootstrap_id"
    printf '- First success task ID: `%s`\n' "${first%%|*}"
    printf '- Second success task ID: `%s`\n' "${second%%|*}"
    printf '- Deliberate failure task ID: `%s`\n' "${deliberate%%|*}"
    printf '- Relative Fileman destination syntax: accepted\n'
    printf '- Absolute Fileman destination syntax: accepted\n'
    printf '- Same-name collision: replaced content with the second fixture\n'
    printf '- UAPI success envelope shape: `%s`\n' "$success_format"
    printf '- UAPI failure envelope shape: `%s`\n' "$failure_format"
    printf '\n## File metadata returned by cp077\n\n```json\n%s\n```\n' "$(jq -c . <<<"$info")"
    printf '\n## Controller execution environment\n\n```text\n%s\n```\n' "$(cut -d'|' -f3- <<<"$second")"
    printf '\nThe deliberate non-zero command was reported as a failed deployment task. Each uploaded request ID was recovered from its controller result and correlated with the task ID returned by `VersionControlDeployment::create`.\n'
  } >probe-results/observations.md
}

usage() {
  printf 'Usage: %s {validate-config|parse-response FILE|poll-deployment TASK_ID|run-live-probe}\n' "$0" >&2
  exit 64
}

case "${1:-}" in
  validate-config)
    validate_config
    ;;
  parse-response)
    [[ $# -eq 2 ]] || usage
    parse_response "$2"
    ;;
  poll-deployment)
    [[ $# -eq 2 ]] || usage
    poll_deployment "$2"
    ;;
  run-live-probe)
    [[ $# -eq 1 ]] || usage
    run_live_probe
    ;;
  *) usage ;;
esac
