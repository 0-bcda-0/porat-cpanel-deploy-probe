#!/usr/bin/env bash
set -u -o pipefail
umask 077

readonly probe_root='/home/echosline/cpanel-deploy-probe'
readonly inbox="$probe_root/inbox"
readonly results="$probe_root/results"
readonly request_file="$inbox/current.request"

mkdir -p "$inbox" "$results" || exit 70

request_id='bootstrap'
mode='success'
if [[ -f "$request_file" ]]; then
  while IFS='=' read -r key value; do
    case "$key" in
      request_id) request_id="$value" ;;
      mode) mode="$value" ;;
      *) printf 'Unrecognized request field\n' >&2; exit 64 ;;
    esac
  done <"$request_file"
fi

[[ "$request_id" =~ ^[A-Za-z0-9-]{1,80}$ ]] || { printf 'Invalid request ID\n' >&2; exit 64; }
[[ "$mode" == success || "$mode" == fail ]] || { printf 'Invalid probe mode\n' >&2; exit 64; }

result_file="$results/$request_id.result"
temporary="$results/.$request_id.result.$$"
{
  printf 'request_id=%s\n' "$request_id"
  printf 'mode=%s\n' "$mode"
  printf 'execution_user=%s\n' "$(id -un 2>/dev/null || printf unavailable)"
  printf 'working_directory=%s\n' "$PWD"
  printf 'path=%s\n' "$PATH"
  printf 'bash=%s\n' "$(command -v bash 2>/dev/null || printf unavailable)"
  printf 'tar=%s\n' "$(command -v tar 2>/dev/null || printf unavailable)"
  printf 'sha256sum=%s\n' "$(command -v sha256sum 2>/dev/null || printf unavailable)"
  printf 'realpath=%s\n' "$(command -v realpath 2>/dev/null || printf unavailable)"
  printf 'php=%s\n' "$(command -v php 2>/dev/null || printf unavailable)"
  printf 'curl=%s\n' "$(command -v curl 2>/dev/null || printf unavailable)"
  printf 'git=%s\n' "$(command -v git 2>/dev/null || printf unavailable)"
  printf 'jq=%s\n' "$(command -v jq 2>/dev/null || printf unavailable)"
  printf 'controller_head=%s\n' "$(git rev-parse HEAD 2>/dev/null || printf unavailable)"
  printf 'recorded_at_utc=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  if [[ "$mode" == fail ]]; then printf 'outcome=deliberate-failure\n'; else printf 'outcome=success\n'; fi
} >"$temporary" || exit 70
chmod 600 "$temporary" || exit 70
mv -f "$temporary" "$result_file" || exit 70

if [[ "$mode" == fail ]]; then
  printf 'Harmless deliberate failure for request %s\n' "$request_id" >&2
  exit 42
fi
printf 'Harmless probe completed for request %s\n' "$request_id"
