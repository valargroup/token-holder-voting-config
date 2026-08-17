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
test_root="$(make_test_temp_dir immutable-pins-test)"
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

source_pin="$(find pins/stage -type f -name static-voting-config.json -print -quit)"
fixture_json="${test_root}/historical-pin.json"
jq '. + {"_immutability_test": true}' "$source_pin" > "$fixture_json"

if command -v sha256sum >/dev/null; then
  fixture_hash="$(sha256sum "$fixture_json" | awk '{print $1}')"
else
  fixture_hash="$(shasum -a 256 "$fixture_json" | awk '{print $1}')"
fi

fixture_pin="pins/stage/${fixture_hash}/static-voting-config.json"
mkdir -p "$(dirname "$fixture_pin")"
cp "$fixture_json" "$fixture_pin"
git add "$fixture_pin"
git commit --quiet -m 'add historical pin fixture'

unlink "$fixture_pin"
rmdir "$(dirname "$fixture_pin")"

set +e
build_output="$(
  SOURCE_REVISION=local-test \
    scripts/build-cloudflare-pages.sh "${test_root}/site" 2>&1
)"
build_status=$?
set -e

[[ "$build_status" -ne 0 ]] || fail "builder accepted deletion of an immutable pin"
grep -F "immutable pin from repository history is missing: ${fixture_pin}" <<< "$build_output" >/dev/null \
  || fail "builder failed for an unexpected reason: ${build_output}"

printf 'Immutable pin deletion test passed\n'
