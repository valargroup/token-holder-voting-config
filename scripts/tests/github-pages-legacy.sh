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
test_root="$(make_test_temp_dir github-pages-legacy-test)"
trap 'rm -rf "$test_root"' EXIT
site_dir="${test_root}/site"

if command -v sha256sum >/dev/null; then
  sha256_file() { sha256sum "$1" | awk '{print $1}'; }
elif command -v shasum >/dev/null; then
  sha256_file() { shasum -a 256 "$1" | awk '{print $1}'; }
else
  fail "sha256sum or shasum is required"
fi

SOURCE_REVISION=local-test \
PUBLISHED_AT=2026-08-17T00:00:00Z \
  "${repo_root}/scripts/build-github-pages.sh" "$site_dir" >/dev/null

legacy_hashes=(
  "prod/static-voting-config.json c06f1dfa2f0a30b3614aefcf00ac7e31d61ebc3cf551b3031d1b194232d1056d"
  "stage/static-voting-config.json 80890a6de9acc7293c3e2fabf870bb3e5755dbe0e69de4a59feb8f696134d4dc"
  "test/prod-static-voting-config-duplicate.json 5a6bc0dce85a8ee8d6585d2a180e62f145abcfee7768c15b88de47c9a01a5738"
  "test/static-voting-config-duplicate.json 80890a6de9acc7293c3e2fabf870bb3e5755dbe0e69de4a59feb8f696134d4dc"
)

for legacy_entry in "${legacy_hashes[@]}"; do
  read -r relative_path expected_hash <<< "$legacy_entry"
  actual_hash="$(sha256_file "${site_dir}/${relative_path}")"
  [[ "$actual_hash" == "$expected_hash" ]] \
    || fail "legacy alias changed: ${relative_path}"
  grep -F "${expected_hash}  $(basename "$relative_path")" \
    "${site_dir}/${relative_path}.sha256" >/dev/null \
    || fail "legacy sidecar changed: ${relative_path}"
done

[[ ! -e "${site_dir}/deployment-manifest.json" ]] \
  || fail "legacy mirror must not publish the canonical deployment manifest"
cmp -s "${repo_root}/CNAME" "${site_dir}/CNAME" \
  || fail "legacy mirror is missing its CNAME"
cmp -s "${repo_root}/prod/dynamic-voting-config.json" \
  "${site_dir}/prod/dynamic-voting-config.json" \
  || fail "legacy mirror did not retain current dynamic config publication"

printf 'GitHub Pages legacy compatibility test passed\n'
