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
test_root="$(make_test_temp_dir pir-config-shape-test)"
trap 'rm -rf "$test_root"' EXIT
test_repo="${test_root}/repo"

mkdir -p "$test_repo"
rsync -a --exclude .git "$repo_root/" "$test_repo/"

expect_rejected() {
  local case_name="$1"
  local pir_file="$2"
  local output_dir="${test_root}/site-${case_name}"
  local build_output
  local build_status

  set +e
  build_output="$(
    cd "$test_repo"
    SOURCE_REVISION=local-test \
    PUBLICATION_MODE=local-test \
      scripts/build-cloudflare-pages.sh "$output_dir" 2>&1
  )"
  build_status=$?
  set -e

  [[ "$build_status" -ne 0 ]] || fail "builder accepted ${case_name} PIR config"
  grep -F "invalid PIR config: ${pir_file}" <<< "$build_output" >/dev/null \
    || fail "${case_name} PIR config failed for an unexpected reason: ${build_output}"
}

printf 'true\n' > "${test_repo}/prod/pir.json"
expect_rejected scalar prod/pir.json

printf '{"schema_version":1,"snapshot_height":100}\n{"schema_version":1,"snapshot_height":110}\n' \
  > "${test_repo}/prod/pir.json"
expect_rejected stream prod/pir.json

printf '{"schema_version":1}\n' > "${test_repo}/prod/pir.json"
expect_rejected missing-height prod/pir.json

printf '{"schema_version":1,"snapshot_height":101}\n' > "${test_repo}/prod/pir.json"
expect_rejected unusable-height prod/pir.json

cp "${repo_root}/prod/pir.json" "${test_repo}/prod/pir.json"
printf '{"schema_version":2,"snapshot_height":100}\n' > "${test_repo}/stage/pir.json"
expect_rejected unsupported-schema stage/pir.json

printf 'PIR config shape test passed\n'
