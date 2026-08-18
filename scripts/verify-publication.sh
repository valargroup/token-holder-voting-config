#!/usr/bin/env bash
set -euo pipefail

fail() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

if [[ $# -lt 2 || $# -gt 3 ]]; then
  fail "usage: $0 BASE_URL EXPECTED_DIRECTORY [EXPECTED_SOURCE_REVISION]"
fi

command -v curl >/dev/null || fail "curl is required"
command -v jq >/dev/null || fail "jq is required"

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
base_url="${1%/}"
expected_dir="$(cd "$2" && pwd)"
expected_revision="${3:-}"
temp_root="${TMPDIR:-/tmp}"
download_dir="$(mktemp -d "${temp_root%/}/voting-config-publication.XXXXXXXXXX")"
trap 'rm -rf "$download_dir"' EXIT

connect_timeout_seconds="${VERIFY_CONNECT_TIMEOUT_SECONDS:-10}"
max_time_seconds="${VERIFY_MAX_TIME_SECONDS:-30}"
retry_count="${VERIFY_RETRY_COUNT:-8}"
retry_delay_seconds="${VERIFY_RETRY_DELAY_SECONDS:-2}"
retry_max_time_seconds="${VERIFY_RETRY_MAX_TIME_SECONDS:-120}"
verification_deadline_seconds="${VERIFY_DEADLINE_SECONDS:-180}"
poll_interval_seconds="${VERIFY_POLL_INTERVAL_SECONDS:-5}"
github_outage_isolation="${VERIFY_GITHUB_OUTAGE_ISOLATION:-false}"
gateway_fallback="${VERIFY_GATEWAY_FALLBACK:-false}"
gateway_primary="${VERIFY_GATEWAY_PRIMARY:-false}"

[[ "$connect_timeout_seconds" =~ ^[1-9][0-9]*$ ]] \
  || fail "VERIFY_CONNECT_TIMEOUT_SECONDS must be a positive integer"
[[ "$max_time_seconds" =~ ^[1-9][0-9]*$ ]] \
  || fail "VERIFY_MAX_TIME_SECONDS must be a positive integer"
[[ "$retry_count" =~ ^[0-9]+$ ]] \
  || fail "VERIFY_RETRY_COUNT must be a non-negative integer"
[[ "$retry_delay_seconds" =~ ^[0-9]+$ ]] \
  || fail "VERIFY_RETRY_DELAY_SECONDS must be a non-negative integer"
[[ "$retry_max_time_seconds" =~ ^[1-9][0-9]*$ ]] \
  || fail "VERIFY_RETRY_MAX_TIME_SECONDS must be a positive integer"
[[ "$verification_deadline_seconds" =~ ^[1-9][0-9]*$ ]] \
  || fail "VERIFY_DEADLINE_SECONDS must be a positive integer"
[[ "$poll_interval_seconds" =~ ^[0-9]+$ ]] \
  || fail "VERIFY_POLL_INTERVAL_SECONDS must be a non-negative integer"
case "$github_outage_isolation" in
  true|false) ;;
  *) fail "VERIFY_GITHUB_OUTAGE_ISOLATION must be true or false" ;;
esac
case "$gateway_fallback" in
  true|false) ;;
  *) fail "VERIFY_GATEWAY_FALLBACK must be true or false" ;;
esac
case "$gateway_primary" in
  true|false) ;;
  *) fail "VERIFY_GATEWAY_PRIMARY must be true or false" ;;
esac
if [[ "$gateway_fallback" == true && "$gateway_primary" == true ]]; then
  fail "VERIFY_GATEWAY_FALLBACK and VERIFY_GATEWAY_PRIMARY are mutually exclusive"
fi

curl_network_args=()
if [[ "$github_outage_isolation" == true ]]; then
  github_outage_curl_args=()
  # shellcheck disable=SC1091
  source "${script_dir}/lib/github-outage-curl.sh"
  curl_network_args=("${github_outage_curl_args[@]}")
fi
curl_request_args=()
if [[ "$gateway_fallback" == true ]]; then
  curl_request_args=(--header 'X-Voting-Config-Rehearsal: github-outage')
fi

verification_deadline=$((SECONDS + verification_deadline_seconds))

if command -v sha256sum >/dev/null; then
  sha256_file() { sha256sum "$1" | awk '{print $1}'; }
elif command -v shasum >/dev/null; then
  sha256_file() { shasum -a 256 "$1" | awk '{print $1}'; }
else
  fail "sha256sum or shasum is required"
fi

bounded_curl() {
  local remaining_seconds=$((verification_deadline - SECONDS))
  local request_max_time="$max_time_seconds"
  local request_retry_max_time="$retry_max_time_seconds"

  (( remaining_seconds > 0 )) || return 28
  if (( request_max_time > remaining_seconds )); then
    request_max_time="$remaining_seconds"
  fi
  if (( request_retry_max_time > remaining_seconds )); then
    request_retry_max_time="$remaining_seconds"
  fi

  curl \
    "${curl_network_args[@]}" \
    "${curl_request_args[@]}" \
    --connect-timeout "$connect_timeout_seconds" \
    --max-time "$request_max_time" \
    --retry "$retry_count" \
    --retry-delay "$retry_delay_seconds" \
    --retry-max-time "$request_retry_max_time" \
    --retry-all-errors \
    "$@"
}

wait_for_expected() {
  local description="$1"
  shift
  local reported_wait=false

  until "$@"; do
    if (( SECONDS >= verification_deadline )); then
      fail "verification deadline expired while waiting for ${description}"
    fi
    if [[ "$reported_wait" == false ]]; then
      printf 'Waiting for %s\n' "$description" >&2
      reported_wait=true
    fi
    sleep "$poll_interval_seconds"
  done
}

fetch() {
  local path="$1"
  local destination="$2"
  bounded_curl --fail --silent --show-error --location \
    "${base_url}/${path}?publication-check=$(date +%s)" \
    --output "$destination"
}

compare_path_once() {
  local path="$1"
  local downloaded
  downloaded="$download_dir/$(printf '%s' "$path" | tr '/' '_')"
  fetch "$path" "$downloaded" || return 1
  [[ "$(sha256_file "$expected_dir/$path")" == "$(sha256_file "$downloaded")" ]]
}

compare_path() {
  local path="$1"
  [[ -f "$expected_dir/$path" ]] || fail "missing expected file: ${path}"
  wait_for_expected "published bytes for ${path}" compare_path_once "$path"
}

header_matches_once() {
  local path="$1"
  local header_name="$2"
  local pattern="$3"
  local header_value
  header_value="$(bounded_curl --fail --silent --show-error --location --head \
    --output /dev/null --write-out "%header{${header_name}}" \
    "${base_url}/${path}?header-check=$(date +%s)" | tr -d '\r')" || return 1
  grep -Eiq "$pattern" <<< "$header_value"
}

header_matches() {
  local path="$1"
  local header_name="$2"
  local pattern="$3"
  wait_for_expected "header for ${path}: ${header_name}=${pattern}" \
    header_matches_once "$path" "$header_name" "$pattern"
}

response_header_matches_once() {
  local path="$1"
  local header_name="$2"
  local pattern="$3"
  local header_value
  header_value="$(bounded_curl --fail --silent --show-error --location \
    --output /dev/null --write-out "%header{${header_name}}" \
    "${base_url}/${path}?response-header-check=$(date +%s)" | tr -d '\r')" || return 1
  grep -Eiq "$pattern" <<< "$header_value"
}

response_header_matches() {
  local path="$1"
  local header_name="$2"
  local pattern="$3"
  wait_for_expected "response header for ${path}: ${header_name}=${pattern}" \
    response_header_matches_once "$path" "$header_name" "$pattern"
}

source_paths=(
  prod/dynamic-voting-config.json
  prod/pir.json
  prod/static-voting-config.json
  stage/dynamic-voting-config.json
  stage/pir.json
  stage/static-voting-config.json
  test/prod-static-voting-config-duplicate.json
  test/static-voting-config-duplicate.json
)

paths=(
  "${source_paths[@]}"
  prod/static-voting-config.json.sha256
  stage/static-voting-config.json.sha256
  test/prod-static-voting-config-duplicate.json.sha256
  test/static-voting-config-duplicate.json.sha256
  deployment-manifest.json
)

prod_static_sha256="$(sha256_file "$expected_dir/prod/static-voting-config.json")"
stage_static_sha256="$(sha256_file "$expected_dir/stage/static-voting-config.json")"
prod_duplicate_sha256="$(sha256_file "$expected_dir/test/prod-static-voting-config-duplicate.json")"
stage_duplicate_sha256="$(sha256_file "$expected_dir/test/static-voting-config-duplicate.json")"
[[ -f "$expected_dir/pins/prod/${prod_static_sha256}/static-voting-config.json" ]] \
  || fail "expected snapshot is missing its current production immutable pin"
[[ -f "$expected_dir/pins/stage/${stage_static_sha256}/static-voting-config.json" ]] \
  || fail "expected snapshot is missing its current staging immutable pin"
[[ -f "$expected_dir/pins/test/prod/${prod_duplicate_sha256}/static-voting-config.json" ]] \
  || fail "expected snapshot is missing its production duplicate immutable pin"
[[ -f "$expected_dir/pins/test/stage/${stage_duplicate_sha256}/static-voting-config.json" ]] \
  || fail "expected snapshot is missing its staging duplicate immutable pin"

while IFS= read -r expected_pin; do
  pin_path="${expected_pin#"$expected_dir/"}"
  paths+=("$pin_path")
  if [[ "$pin_path" == */static-voting-config.json ]]; then
    source_paths+=("$pin_path")
  fi
done < <(find "$expected_dir/pins" -type f -print | sort)

for path in "${paths[@]}"; do
  compare_path "$path"
done

short_cache_pattern='^[[:space:]]*public,[[:space:]]*max-age=60,[[:space:]]*must-revalidate,[[:space:]]*stale-if-error=86400[[:space:]]*$'
static_cache_pattern='^[[:space:]]*public,[[:space:]]*max-age=300,[[:space:]]*must-revalidate,[[:space:]]*stale-if-error=86400[[:space:]]*$'
immutable_cache_pattern='^[[:space:]]*public,[[:space:]]*max-age=31536000,[[:space:]]*immutable[[:space:]]*$'

header_matches prod/dynamic-voting-config.json cache-control "$short_cache_pattern"
header_matches stage/dynamic-voting-config.json cache-control "$short_cache_pattern"
header_matches prod/pir.json cache-control "$short_cache_pattern"
header_matches stage/pir.json cache-control "$short_cache_pattern"
header_matches deployment-manifest.json cache-control "$short_cache_pattern"
header_matches prod/static-voting-config.json cache-control "$static_cache_pattern"
header_matches stage/static-voting-config.json cache-control "$static_cache_pattern"
header_matches test/prod-static-voting-config-duplicate.json cache-control "$static_cache_pattern"
header_matches test/static-voting-config-duplicate.json cache-control "$static_cache_pattern"
header_matches "pins/prod/${prod_static_sha256}/static-voting-config.json" \
  cache-control "$immutable_cache_pattern"
header_matches "pins/stage/${stage_static_sha256}/static-voting-config.json" \
  cache-control "$immutable_cache_pattern"
header_matches "pins/test/prod/${prod_duplicate_sha256}/static-voting-config.json" \
  cache-control "$immutable_cache_pattern"
header_matches "pins/test/stage/${stage_duplicate_sha256}/static-voting-config.json" \
  cache-control "$immutable_cache_pattern"
header_matches prod/dynamic-voting-config.json access-control-allow-origin \
  '^[[:space:]]*\*[[:space:]]*$'
if [[ "$gateway_fallback" == true ]]; then
  expected_gateway_origin='cloudflare'
elif [[ "$gateway_primary" == true ]]; then
  expected_gateway_origin='github'
else
  response_header_matches stage/dynamic-voting-config.json x-voting-config-origin \
    '^[[:space:]]*(github|cloudflare)[[:space:]]*$'
fi
if [[ -n "${expected_gateway_origin:-}" ]]; then
  for source_path in "${source_paths[@]}"; do
    response_header_matches "$source_path" x-voting-config-origin \
      "^[[:space:]]*${expected_gateway_origin}[[:space:]]*$"
  done
fi
response_header_matches deployment-manifest.json x-voting-config-origin \
  '^[[:space:]]*cloudflare[[:space:]]*$'

if [[ -n "$expected_revision" ]]; then
  header_matches stage/dynamic-voting-config.json x-voting-config-revision \
    "^[[:space:]]*${expected_revision}[[:space:]]*$"
  jq -e --arg expected "$expected_revision" '.source_revision == $expected' \
    "$download_dir/deployment-manifest.json" >/dev/null \
    || fail "deployment manifest does not identify ${expected_revision}"
fi

for env_name in prod stage; do
  expected_dynamic_url="https://voting.valargroup.dev/${env_name}/dynamic-voting-config.json"
  jq -e --arg expected "$expected_dynamic_url" '.dynamic_config_url == $expected' \
    "$download_dir/${env_name}_static-voting-config.json" >/dev/null \
    || fail "published ${env_name} static config points outside the controlled domain"
done

seed_is_absent() {
  local seed_status
  seed_status="$(bounded_curl --silent --show-error --location --output /dev/null --write-out '%{http_code}' \
    "${base_url}/test/valar-test.seed.b64?publication-check=$(date +%s)")" || return 1
  [[ "$seed_status" == "404" ]]
}

wait_for_expected "test seed to return HTTP 404" seed_is_absent

printf 'Verified publication at %s\n' "$base_url"
