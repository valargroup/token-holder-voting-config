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
test_root="$(make_test_temp_dir headers-source-safety-test)"
trap 'rm -rf "$test_root"' EXIT
fixture_repo="${test_root}/repo"
output_dir="${test_root}/site"
gateway_output_dir="${test_root}/gateway-site"
github_output_dir="${test_root}/github-site"

mkdir -p "${fixture_repo}/scripts"
cp \
  "${repo_root}/scripts/build-cloudflare-pages.sh" \
  "${repo_root}/scripts/build-github-pages.sh" \
  "${repo_root}/scripts/cloudflare-gateway.mjs" \
  "${fixture_repo}/scripts/"
cp -R \
  "${repo_root}/prod" \
  "${repo_root}/stage" \
  "${repo_root}/test" \
  "${repo_root}/pins" \
  "${repo_root}/legacy" \
  "$fixture_repo/"
ln -s "${repo_root}/_headers" "${fixture_repo}/_headers"

set +e
build_output="$(
  cd "$fixture_repo"
  SOURCE_REVISION=local-test \
    scripts/build-cloudflare-pages.sh "$output_dir" 2>&1
)"
build_status=$?
set -e

[[ "$build_status" -ne 0 ]] || fail "builder accepted a symbolic link headers file"
grep -F 'missing or unsafe headers file: _headers' <<< "$build_output" >/dev/null \
  || fail "builder failed for an unexpected reason: ${build_output}"
[[ ! -e "${output_dir}/_headers" ]] \
  || fail "builder copied a symbolic link headers file"

unlink "${fixture_repo}/_headers"
cp "${repo_root}/_headers" "${fixture_repo}/_headers"
unlink "${fixture_repo}/scripts/cloudflare-gateway.mjs"
ln -s "${repo_root}/scripts/cloudflare-gateway.mjs" \
  "${fixture_repo}/scripts/cloudflare-gateway.mjs"

set +e
build_output="$(
  cd "$fixture_repo"
  SOURCE_REVISION=local-test \
    scripts/build-cloudflare-pages.sh "$gateway_output_dir" 2>&1
)"
build_status=$?
set -e

[[ "$build_status" -ne 0 ]] || fail "builder accepted a symbolic link gateway"
grep -F 'missing or unsafe Cloudflare gateway: scripts/cloudflare-gateway.mjs' \
  <<< "$build_output" >/dev/null \
  || fail "builder rejected the gateway for an unexpected reason: ${build_output}"
[[ ! -e "${gateway_output_dir}/_worker.js" ]] \
  || fail "builder copied a symbolic link gateway"

unlink "${fixture_repo}/scripts/cloudflare-gateway.mjs"
cp "${repo_root}/scripts/cloudflare-gateway.mjs" \
  "${fixture_repo}/scripts/cloudflare-gateway.mjs"
ln -s "${repo_root}/CNAME" "${fixture_repo}/CNAME"

set +e
build_output="$(
  cd "$fixture_repo"
  SOURCE_REVISION=local-test \
    scripts/build-github-pages.sh "$github_output_dir" 2>&1
)"
build_status=$?
set -e

[[ "$build_status" -ne 0 ]] || fail "builder accepted a symbolic link CNAME file"
grep -F "missing or unsafe CNAME file: ${fixture_repo}/CNAME" <<< "$build_output" >/dev/null \
  || fail "GitHub Pages builder failed for an unexpected reason: ${build_output}"
[[ ! -e "${github_output_dir}/CNAME" ]] \
  || fail "builder copied a symbolic link CNAME file"

printf 'Publication source symlink tests passed\n'
