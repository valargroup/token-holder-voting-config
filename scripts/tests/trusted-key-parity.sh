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
test_root="$(make_test_temp_dir trusted-key-parity-test)"
trap 'rm -rf "$test_root"' EXIT
test_repo="${test_root}/repo"

mkdir -p "$test_repo"
rsync -a --exclude .git "$repo_root/" "$test_repo/"

# Rewrites one file from its pristine copy, leaving the other untouched.
mutate() {
  local relative_path="$1"
  shift
  jq "$@" "${repo_root}/${relative_path}" > "${test_repo}/${relative_path}"
}

restore() {
  cp "${repo_root}/$1" "${test_repo}/$1"
}

restore_all() {
  restore prod/static-voting-config.json
  restore prod/v2-static-voting-config.json
  restore stage/static-voting-config.json
  restore stage/v2-static-voting-config.json
}

run_parity() {
  local output
  local status

  set +e
  output="$(cd "$test_repo" && scripts/verify-trusted-key-parity.sh 2>&1)"
  status=$?
  set -e

  printf '%s\n' "$output"
  return $status
}

expect_rejected() {
  local case_name="$1"
  local expected_message="$2"
  local output
  local status

  set +e
  output="$(run_parity)"
  status=$?
  set -e

  [[ "$status" -ne 0 ]] || fail "parity check accepted ${case_name}"
  grep -F "$expected_message" <<< "$output" >/dev/null \
    || fail "${case_name} failed for an unexpected reason: ${output}"
  restore_all
}

expect_accepted() {
  local case_name="$1"
  local output
  local status

  set +e
  output="$(run_parity)"
  status=$?
  set -e

  [[ "$status" -eq 0 ]] || fail "parity check rejected ${case_name}: ${output}"
  restore_all
}

parity_message="prod/static-voting-config.json and prod/v2-static-voting-config.json must trust the same keys"

# A key added to v1 alone - the rotation footgun this check exists for.
mutate prod/static-voting-config.json \
  '.trusted_keys += [{key_id: "new-manager", alg: "ed25519", pubkey: "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8="}]'
expect_rejected key-added-to-v1-only "  only in v1: new-manager"

# A key added to v2 alone.
mutate prod/v2-static-voting-config.json \
  '.trusted_keys += [{key_id: "new-manager", alg: "ed25519", pubkey: "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8="}]'
expect_rejected key-added-to-v2-only "  only in v2: new-manager"

# A key retired from v2 alone.
mutate prod/v2-static-voting-config.json '.trusted_keys |= map(select(.key_id != "tachyon"))'
expect_rejected key-retired-from-v2-only "  only in v1: tachyon"

# Same key_id, different pubkey - the quietest and most dangerous drift.
mutate prod/v2-static-voting-config.json \
  '.trusted_keys |= map(if .key_id == "valargroup" then .pubkey = "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8=" else . end)'
expect_rejected pubkey-changed-in-v2 "  differs between v1 and v2: valargroup"

# Staging is checked too, not just production.
mutate stage/v2-static-voting-config.json '.trusted_keys |= map(select(.key_id != "valar-test"))'
expect_rejected stage-divergence \
  "stage/static-voting-config.json and stage/v2-static-voting-config.json must trust the same keys"

# Duplicate key_id within one file makes signer attribution ambiguous.
mutate prod/v2-static-voting-config.json '.trusted_keys += [.trusted_keys[0]]'
expect_rejected duplicate-key-id "lists a duplicate key_id"

# The same pubkey under two names is equally ambiguous.
mutate prod/v2-static-voting-config.json \
  '.trusted_keys += [.trusted_keys[0] | .key_id = "alias"]'
expect_rejected duplicate-pubkey "lists the same pubkey under more than one key_id"

# An empty trust set would verify nothing.
mutate prod/v2-static-voting-config.json '.trusted_keys = []'
expect_rejected empty-trusted-keys "must define a non-empty trusted_keys array"

# trusted_keys order carries no meaning, so reordering must not fail.
mutate prod/v2-static-voting-config.json '.trusted_keys |= reverse'
expect_accepted reordered-trusted-keys

# Neither does key order within an entry.
mutate prod/v2-static-voting-config.json \
  '.trusted_keys |= map({notes, pubkey, alg, key_id})'
expect_accepted reordered-entry-fields

printf 'Trusted key parity test passed\n'
