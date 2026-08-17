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
test_root="$(make_test_temp_dir manual-pin-base-test)"
trap 'rm -rf "$test_root"' EXIT
test_repo="${test_root}/repo"

mkdir -p "$test_repo"
rsync -a --exclude .git "$repo_root/" "$test_repo/"

cd "$test_repo"
git init --quiet
git config user.name codex-test
git config user.email codex-test@example.invalid
git add .
git commit --quiet -m baseline
head_revision="$(git rev-parse HEAD)"

set +e
build_output="$(
  SOURCE_REVISION="$head_revision" \
  PUBLICATION_MODE=manual-emergency \
  PUBLISHED_AT=2026-08-17T00:00:00Z \
    scripts/build-cloudflare-pages.sh "${test_root}/missing-base-site" 2>&1
)"
build_status=$?
set -e

[[ "$build_status" -ne 0 ]] || fail "manual publication accepted a missing pin base"
grep -F 'non-test publications require PIN_BASE_REVISION' <<< "$build_output" >/dev/null \
  || fail "builder failed for an unexpected reason: ${build_output}"

PIN_BASE_REVISION="$head_revision" \
SOURCE_REVISION="$head_revision" \
PUBLICATION_MODE=manual-emergency \
PUBLISHED_AT=2026-08-17T00:00:00Z \
  scripts/build-cloudflare-pages.sh "${test_root}/based-site" >/dev/null

printf 'Manual publication pin base test passed\n'
