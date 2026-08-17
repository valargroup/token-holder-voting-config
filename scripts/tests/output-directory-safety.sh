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
test_root="$(make_test_temp_dir output-directory-safety-test)"
trap 'rm -rf "$test_root"' EXIT
target_dir="${test_root}/target"
output_link="${test_root}/site"

mkdir "$target_dir"
ln -s "$target_dir" "$output_link"

set +e
build_output="$(
  SOURCE_REVISION=local-test \
    "${repo_root}/scripts/build-cloudflare-pages.sh" "$output_link" 2>&1
)"
build_status=$?
set -e

[[ "$build_status" -ne 0 ]] || fail "builder accepted a symbolic link output directory"
grep -F "refusing symbolic link output directory: ${output_link}" <<< "$build_output" >/dev/null \
  || fail "builder failed for an unexpected reason: ${build_output}"
[[ -z "$(find "$target_dir" -mindepth 1 -print -quit)" ]] \
  || fail "builder wrote through a symbolic link output directory"

printf 'Output directory symlink test passed\n'
