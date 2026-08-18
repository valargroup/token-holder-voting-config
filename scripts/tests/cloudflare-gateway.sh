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
test_root="$(make_test_temp_dir cloudflare-gateway-test)"
trap 'rm -rf "$test_root"' EXIT

command -v node >/dev/null || fail "node is required"
node "${script_dir}/cloudflare-gateway.mjs"

site_dir="${test_root}/site"
SOURCE_REVISION=local-test \
PUBLISHED_AT=2026-08-17T00:00:00Z \
  "${repo_root}/scripts/build-cloudflare-pages.sh" "$site_dir" >/dev/null

[[ -f "${site_dir}/_worker.js" ]] || fail "snapshot is missing the Pages gateway"
grep -F 'const BUILD_SOURCE_REVISION = "local-test";' "${site_dir}/_worker.js" >/dev/null \
  || fail "Pages gateway does not identify the snapshot revision"
if grep -F '__SOURCE_REVISION__' "${site_dir}/_worker.js" >/dev/null; then
  fail "Pages gateway retains its source revision placeholder"
fi
jq -e '.serving_model == "github-primary-cloudflare-pages-fallback"' \
  "${site_dir}/deployment-manifest.json" >/dev/null \
  || fail "deployment manifest does not identify the gateway serving model"

printf 'Cloudflare gateway build test passed\n'
