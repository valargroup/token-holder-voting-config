#!/usr/bin/env bash
set -euo pipefail

fail() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/../.." && pwd)"
# shellcheck disable=SC1091
source "${script_dir}/lib/test-helpers.sh"
test_root="$(make_test_temp_dir v2-static-config-shape-test)"
trap 'rm -rf "$test_root"' EXIT
test_repo="${test_root}/repo"

mkdir -p "$test_repo"
rsync -a --exclude .git "$repo_root/" "$test_repo/"

if command -v sha256sum >/dev/null; then
  sha256_file() { sha256sum "$1" | awk '{print $1}'; }
else
  sha256_file() { shasum -a 256 "$1" | awk '{print $1}'; }
fi

canonical_url="https://voting.valargroup.dev/prod/dynamic-voting-config.json"
raw_url="https://raw.githubusercontent.com/valargroup/token-holder-voting-config/main/prod/dynamic-voting-config.json"

# Rewrites prod/v2-static-voting-config.json and re-pins it, so each case fails
# on the shape rule under test rather than on a stale pin.
# Every argument is forwarded to jq, so a case may pass --arg before its filter.
# The mutated alias is re-pinned so each case fails on the shape rule under test
# rather than on a missing pin, and the previous case's pin is dropped so it does
# not mask the next one.
case_pin_dir=""

apply_v2_case() {
  local target="${test_repo}/prod/v2-static-voting-config.json"

  [[ -z "$case_pin_dir" ]] || rm -rf "$case_pin_dir"

  jq "$@" "${repo_root}/prod/v2-static-voting-config.json" > "$target"

  local hash
  hash="$(sha256_file "$target")"
  case_pin_dir="${test_repo}/pins/prod/${hash}"
  mkdir -p "$case_pin_dir"
  cp "$target" "${case_pin_dir}/v2-static-voting-config.json"
}

expect_rejected() {
  local case_name="$1"
  local expected_message="$2"
  local output_dir="${test_root}/site-${case_name}"
  local build_output
  local build_status

  set +e
  build_output="$(
    cd "$test_repo"
    SOURCE_REVISION=local-test \
      scripts/build-cloudflare-pages.sh "$output_dir" 2>&1
  )"
  build_status=$?
  set -e

  [[ "$build_status" -ne 0 ]] || fail "builder accepted ${case_name} v2 static config"
  grep -F "$expected_message" <<< "$build_output" >/dev/null \
    || fail "${case_name} v2 static config failed for an unexpected reason: ${build_output}"
}

shape_message="invalid v2 static config: prod/v2-static-voting-config.json"

apply_v2_case '.static_config_version = 1'
expect_rejected v1-version "$shape_message"

apply_v2_case '.dynamic_config_urls = []'
expect_rejected empty-urls "$shape_message"

apply_v2_case '.dynamic_config_urls = [.dynamic_config_urls[0]]'
expect_rejected single-url "$shape_message"

apply_v2_case '.dynamic_config_urls = [.dynamic_config_urls[0], .dynamic_config_urls[0]]'
expect_rejected duplicate-url "$shape_message"

apply_v2_case --arg canonical "$canonical_url" --arg raw "$raw_url" \
  '.dynamic_config_urls = [$raw, $canonical]'
expect_rejected non-canonical-first "$shape_message"

apply_v2_case --arg canonical "$canonical_url" \
  '.dynamic_config_urls = [$canonical, "https://voting.example.invalid/prod/dynamic-voting-config.json"]'
expect_rejected off-allowlist-mirror "$shape_message"

apply_v2_case '.dynamic_config_url = .dynamic_config_urls[0]'
expect_rejected lingering-singular-url "$shape_message"

apply_v2_case '.trusted_keys = []'
expect_rejected empty-trusted-keys "$shape_message"

apply_v2_case '.trusted_keys = [.trusted_keys[0]]'
expect_rejected diverging-trusted-keys \
  "prod/static-voting-config.json and prod/v2-static-voting-config.json must trust the same keys"

# A v2 alias with no matching immutable pin must not publish.
rm -rf "$case_pin_dir"
cp "${repo_root}/prod/v2-static-voting-config.json" \
  "${test_repo}/prod/v2-static-voting-config.json"
prod_v2_hash="$(sha256_file "${test_repo}/prod/v2-static-voting-config.json")"
rm -rf "${test_repo}/pins/prod/${prod_v2_hash}"
expect_rejected missing-pin \
  "add the production v2 static config to pins/prod/${prod_v2_hash}/v2-static-voting-config.json"

printf 'v2 static config shape test passed\n'
