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
test_root="$(make_test_temp_dir latest-main-publication-test)"
trap 'rm -rf "$test_root"' EXIT
remote_repo="${test_root}/remote.git"
work_repo="${test_root}/work"

git init --quiet --bare "$remote_repo"
git init --quiet --initial-branch=main "$work_repo"

cd "$work_repo"
git config user.name codex-test
git config user.email codex-test@example.invalid
git remote add origin "$remote_repo"

printf 'first\n' > config
git add config
git commit --quiet -m first
git push --quiet --set-upstream origin main
stale_revision="$(git rev-parse HEAD)"

printf 'second\n' > config
git commit --quiet -am second
git push --quiet origin main
latest_revision="$(git rev-parse HEAD)"

set +e
guard_output="$("${repo_root}/scripts/require-latest-main.sh" "$stale_revision" 2>&1)"
guard_status=$?
set -e

[[ "$guard_status" -ne 0 ]] || fail "freshness guard accepted a stale revision"
grep -F "refusing stale publication: expected ${stale_revision}, but origin/main is ${latest_revision}" \
  <<< "$guard_output" >/dev/null \
  || fail "freshness guard failed for an unexpected reason: ${guard_output}"

"${repo_root}/scripts/require-latest-main.sh" "$latest_revision" >/dev/null

printf 'Latest main publication test passed\n'
