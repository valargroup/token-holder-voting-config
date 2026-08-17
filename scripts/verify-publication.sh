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

base_url="${1%/}"
expected_dir="$(cd "$2" && pwd)"
expected_revision="${3:-}"
download_dir="$(mktemp -d -t voting-config-publication)"
trap 'rm -rf "$download_dir"' EXIT

if command -v sha256sum >/dev/null; then
  sha256_file() { sha256sum "$1" | awk '{print $1}'; }
elif command -v shasum >/dev/null; then
  sha256_file() { shasum -a 256 "$1" | awk '{print $1}'; }
else
  fail "sha256sum or shasum is required"
fi

fetch() {
  local path="$1"
  local destination="$2"
  curl --fail --silent --show-error --location \
    --retry 8 --retry-delay 2 --retry-all-errors \
    "${base_url}/${path}?publication-check=$(date +%s)" \
    --output "$destination"
}

compare_path() {
  local path="$1"
  local downloaded
  downloaded="$download_dir/$(printf '%s' "$path" | tr '/' '_')"
  [[ -f "$expected_dir/$path" ]] || fail "missing expected file: ${path}"
  fetch "$path" "$downloaded"
  if [[ "$(sha256_file "$expected_dir/$path")" != "$(sha256_file "$downloaded")" ]]; then
    fail "published bytes differ for ${path}"
  fi
}

header_contains() {
  local path="$1"
  local pattern="$2"
  local headers
  headers="$(curl --fail --silent --show-error --location --head \
    --retry 8 --retry-delay 2 --retry-all-errors \
    "${base_url}/${path}?header-check=$(date +%s)" | tr -d '\r')"
  grep -Eiq "$pattern" <<< "$headers" || fail "missing expected header for ${path}: ${pattern}"
}

paths=(
  prod/dynamic-voting-config.json
  prod/pir.json
  prod/static-voting-config.json
  stage/dynamic-voting-config.json
  stage/pir.json
  stage/static-voting-config.json
  test/prod-static-voting-config-duplicate.json
  test/static-voting-config-duplicate.json
  prod/static-voting-config.json.sha256
  stage/static-voting-config.json.sha256
  test/prod-static-voting-config-duplicate.json.sha256
  test/static-voting-config-duplicate.json.sha256
  deployment-manifest.json
)

prod_static_sha256="$(sha256_file "$expected_dir/prod/static-voting-config.json")"
stage_static_sha256="$(sha256_file "$expected_dir/stage/static-voting-config.json")"
[[ -f "$expected_dir/pins/prod/${prod_static_sha256}/static-voting-config.json" ]] \
  || fail "expected snapshot is missing its current production immutable pin"
[[ -f "$expected_dir/pins/stage/${stage_static_sha256}/static-voting-config.json" ]] \
  || fail "expected snapshot is missing its current staging immutable pin"

while IFS= read -r expected_pin; do
  paths+=("${expected_pin#"$expected_dir/"}")
done < <(find "$expected_dir/pins" -type f -print | sort)

for path in "${paths[@]}"; do
  compare_path "$path"
done

header_contains prod/dynamic-voting-config.json '^cache-control:.*max-age=60.*must-revalidate'
header_contains stage/dynamic-voting-config.json '^cache-control:.*max-age=60.*must-revalidate'
header_contains prod/static-voting-config.json '^cache-control:.*max-age=300.*must-revalidate'
header_contains "pins/prod/${prod_static_sha256}/static-voting-config.json" '^cache-control:.*max-age=31536000.*immutable'
header_contains prod/dynamic-voting-config.json '^access-control-allow-origin:[[:space:]]*\*'

fetch deployment-manifest.json "$download_dir/deployment-manifest.json"
if [[ -n "$expected_revision" ]]; then
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

seed_status="$(curl --silent --show-error --location --output /dev/null --write-out '%{http_code}' \
  "${base_url}/test/valar-test.seed.b64?publication-check=$(date +%s)")"
[[ "$seed_status" == "404" ]] || fail "test seed must not be published; got HTTP ${seed_status}"

printf 'Verified publication at %s\n' "$base_url"
