#!/usr/bin/env bash
set -euo pipefail

fail() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

if [[ $# -ne 4 ]]; then
  fail "usage: $0 BASE_URL EXPECTED_REVISION COMMIT_EPOCH MAX_LAG_SECONDS"
fi

command -v curl >/dev/null || fail "curl is required"
command -v jq >/dev/null || fail "jq is required"

base_url="${1%/}"
expected_revision="$2"
commit_epoch="$3"
max_lag_seconds="$4"
poll_seconds="${PUBLICATION_POLL_SECONDS:-15}"
connect_timeout_seconds="${PUBLICATION_CONNECT_TIMEOUT_SECONDS:-5}"
max_time_seconds="${PUBLICATION_MAX_TIME_SECONDS:-10}"
require_on_time="${PUBLICATION_REQUIRE_ON_TIME:-false}"

[[ "$expected_revision" =~ ^[0-9a-f]{40}$ ]] \
  || fail "EXPECTED_REVISION must be a full Git commit"
[[ "$commit_epoch" =~ ^[0-9]+$ ]] \
  || fail "COMMIT_EPOCH must be a non-negative integer"
[[ "$max_lag_seconds" =~ ^[1-9][0-9]*$ ]] \
  || fail "MAX_LAG_SECONDS must be a positive integer"
[[ "$poll_seconds" =~ ^[1-9][0-9]*$ ]] \
  || fail "PUBLICATION_POLL_SECONDS must be a positive integer"
[[ "$connect_timeout_seconds" =~ ^[1-9][0-9]*$ ]] \
  || fail "PUBLICATION_CONNECT_TIMEOUT_SECONDS must be a positive integer"
[[ "$max_time_seconds" =~ ^[1-9][0-9]*$ ]] \
  || fail "PUBLICATION_MAX_TIME_SECONDS must be a positive integer"
case "$require_on_time" in
  true|false) ;;
  *) fail "PUBLICATION_REQUIRE_ON_TIME must be true or false" ;;
esac

deadline=$((commit_epoch + max_lag_seconds))
attempt=0
last_revision="unavailable"

while true; do
  attempt=$((attempt + 1))
  request_epoch="$(date +%s)"
  manifest=""
  if manifest="$(curl --fail --silent --show-error --location \
    --connect-timeout "$connect_timeout_seconds" \
    --max-time "$max_time_seconds" \
    "${base_url}/deployment-manifest.json?revision-monitor=${expected_revision}-${request_epoch}-${attempt}" \
    2>/dev/null)"; then
    if ! last_revision="$(jq -r \
      'if (.source_revision | type) == "string" then .source_revision else "invalid" end' \
      <<< "$manifest" 2>/dev/null)"; then
      last_revision="invalid"
    fi
    if [[ "$last_revision" == "$expected_revision" ]]; then
      if published_at="$(jq -er \
        'select((.published_at | type) == "string" and (.published_at | length) > 0) | .published_at' \
        <<< "$manifest" 2>/dev/null)" \
        && jq -en --arg timestamp "$published_at" \
          '$timestamp | fromdateiso8601' >/dev/null 2>&1; then
        observed_epoch="$(date +%s)"
        if [[ "$require_on_time" == true ]] && (( observed_epoch > deadline )); then
          fail "live manifest first observed ${expected_revision} after the ${max_lag_seconds}s deadline"
        fi
        printf '%s\n' "$published_at"
        exit 0
      fi
      last_revision="invalid"
    fi
  fi

  now_epoch="$(date +%s)"
  if (( now_epoch >= deadline )); then
    fail "live manifest did not reach ${expected_revision} within ${max_lag_seconds}s (last revision: ${last_revision})"
  fi

  remaining_seconds=$((deadline - now_epoch))
  sleep_seconds="$poll_seconds"
  if (( sleep_seconds > remaining_seconds )); then
    sleep_seconds="$remaining_seconds"
  fi
  sleep "$sleep_seconds"
done
