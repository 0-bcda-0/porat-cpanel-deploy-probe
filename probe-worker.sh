#!/usr/bin/env bash
set -u -o pipefail
umask 077

readonly default_probe_root='/home/echosline/cpanel-deploy-probe'
readonly default_dev_app_root='/home/echosline/apps/porat-staff-v2'
readonly default_dev_public_root='/home/echosline/bcda.com.hr'
readonly default_dev_base_url='https://bcda.com.hr'
readonly default_dev_cookie='porat_staff_dev_session'

probe_root="${PORAT_CONTROLLER_PROBE_ROOT:-$default_probe_root}"
dev_app_root="${PORAT_CONTROLLER_DEV_APP_ROOT:-$default_dev_app_root}"
dev_public_root="${PORAT_CONTROLLER_DEV_PUBLIC_ROOT:-$default_dev_public_root}"
dev_base_url="${PORAT_CONTROLLER_DEV_BASE_URL:-$default_dev_base_url}"
dev_cookie="${PORAT_CONTROLLER_DEV_COOKIE:-$default_dev_cookie}"

inbox="$probe_root/inbox"
results="$probe_root/results"
request_file="$inbox/current.request"

mkdir -p "$inbox" "$results" || exit 70

request_id=''
operation=''
mode=''
sha=''
checksum=''
archive_name=''

if [[ ! -f "$request_file" ]]; then
  printf 'Missing request file\n' >&2
  exit 64
fi

while IFS='=' read -r key value || [[ -n "$key" || -n "$value" ]]; do
  case "$key" in
    request_id) request_id="$value" ;;
    operation) operation="$value" ;;
    mode) mode="$value" ;;
    sha) sha="$value" ;;
    checksum) checksum="$value" ;;
    archive_name) archive_name="$value" ;;
    '') ;;
    *) printf 'Unrecognized request field\n' >&2; exit 64 ;;
  esac
done <"$request_file"

[[ "$request_id" =~ ^[A-Za-z0-9-]{1,80}$ ]] || { printf 'Invalid request ID\n' >&2; exit 64; }

write_result() {
  local outcome="$1" status="$2"
  local result_file="$results/$request_id.result"
  local temporary="$results/.$request_id.result.$$"
  {
    printf 'request_id=%s\n' "$request_id"
    printf 'operation=%s\n' "$operation"
    [[ -n "$sha" ]] && printf 'sha=%s\n' "$sha"
    printf 'outcome=%s\n' "$outcome"
    printf 'exit_status=%s\n' "$status"
    printf 'controller_head=%s\n' "$(git rev-parse HEAD 2>/dev/null || printf unavailable)"
    printf 'recorded_at_utc=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  } >"$temporary" || exit 70
  chmod 600 "$temporary" || exit 70
  mv -f "$temporary" "$result_file" || exit 70
}

if [[ "$operation" == 'deploy-development' ]]; then
  [[ "$sha" =~ ^[0-9a-f]{40}$ ]] || { printf 'Invalid deployment SHA\n' >&2; exit 64; }
  [[ "$checksum" =~ ^[0-9a-f]{64}$ ]] || { printf 'Invalid deployment checksum\n' >&2; exit 64; }
  [[ -z "$mode" ]] || { printf 'Mode is not valid for deployment requests\n' >&2; exit 64; }
  expected_archive_name="${sha}-${request_id}.tar.gz"
  [[ "$archive_name" == "$expected_archive_name" ]] || { printf 'Invalid deployment archive name\n' >&2; exit 64; }

  archive="$dev_app_root/uploads/$archive_name"
  deployer="$dev_app_root/bin/deploy-release.sh"

  [[ -d "$dev_app_root" && ! -L "$dev_app_root" ]] || { printf 'Approved DEV app root is unavailable\n' >&2; exit 70; }
  [[ -d "$dev_app_root/uploads" && ! -L "$dev_app_root/uploads" ]] || { printf 'Approved DEV uploads root is unavailable\n' >&2; exit 70; }
  [[ -f "$archive" && ! -L "$archive" ]] || { printf 'Expected uploaded archive is unavailable\n' >&2; exit 70; }
  [[ -f "$deployer" && ! -L "$deployer" ]] || { printf 'Stable DEV deployer is unavailable\n' >&2; exit 70; }

  set +e
  env \
    PORAT_DEPLOY_APP_ROOT="$dev_app_root" \
    PORAT_DEPLOY_PUBLIC_ROOT="$dev_public_root" \
    PORAT_DEPLOY_BASE_URL="$dev_base_url" \
    PORAT_DEPLOY_EXPECTED_SESSION_COOKIE="$dev_cookie" \
    bash "$deployer" deploy "$sha" "$archive" "$checksum"
  status=$?
  set -e

  rm -f -- "$archive"

  if [[ $status -eq 0 ]]; then
    write_result success 0
    exit 0
  fi

  write_result failure "$status"
  exit "$status"
fi

# Preserve the harmless capability-probe modes for the existing probe workflow.
if [[ -z "$operation" && ( "$mode" == 'success' || "$mode" == 'fail' ) ]]; then
  write_result "$([[ "$mode" == success ]] && printf success || printf deliberate-failure)" "$([[ "$mode" == success ]] && printf 0 || printf 42)"
  [[ "$mode" == success ]] && exit 0
  printf 'Harmless deliberate failure for request %s\n' "$request_id" >&2
  exit 42
fi

printf 'Invalid or unsupported operation\n' >&2
exit 64
