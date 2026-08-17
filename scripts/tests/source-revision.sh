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
test_root="$(make_test_temp_dir source-revision-test)"
trap 'rm -rf "$test_root"' EXIT
test_repo="${test_root}/repo"
fixture_bin="${script_dir}/fixtures"

mkdir -p "$test_repo"
rsync -a --exclude .git "$repo_root/" "$test_repo/"

cd "$test_repo"
git init --quiet
git config user.name codex-test
git config user.email codex-test@example.invalid
git add .
git commit --quiet -m baseline
previous_revision="$(git rev-parse HEAD)"
git commit --quiet --allow-empty -m current
head_revision="$(git rev-parse HEAD)"

set +e
build_output="$(
  SOURCE_REVISION="$previous_revision" \
  PUBLISHED_AT=2026-08-17T00:00:00Z \
  PATH="${fixture_bin}:${PATH}" \
    scripts/build-cloudflare-pages.sh "${test_root}/mismatched-site" 2>&1
)"
build_status=$?
set -e

[[ "$build_status" -ne 0 ]] || fail "builder accepted a mismatched source revision"
grep -F "SOURCE_REVISION must match HEAD (${head_revision})" <<< "$build_output" >/dev/null \
  || fail "builder failed for an unexpected reason: ${build_output}"

SOURCE_REVISION="$head_revision" \
PUBLISHED_AT=2026-08-17T00:00:00Z \
PATH="${fixture_bin}:${PATH}" \
  scripts/build-cloudflare-pages.sh "${test_root}/matching-site" >/dev/null

printf 'Source revision test passed\n'
