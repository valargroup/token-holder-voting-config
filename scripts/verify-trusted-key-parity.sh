#!/usr/bin/env bash
set -euo pipefail

# Requires each environment's v1 and v2 static configs to trust exactly the same
# keys.
#
# The two files are separate wallet trust anchors for the same environment, so a
# key added, rotated, or retired in one and forgotten in the other splits the
# trust set: rounds signed by the new key verify for wallets pinned to one file
# and fail for wallets pinned to the other. Nothing else in the pipeline would
# notice - each file independently verifies fine against the dynamic config,
# because verification only needs *at least one* trusted key to match.
#
# Comparison is order-independent: trusted_keys order carries no meaning, so
# reordering is not an error, while any add, removal, or edit is.
#
# Immutable pins under pins/ are deliberately not compared. They are historical
# snapshots and legitimately record older key sets; only the current aliases
# must agree.

fail() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

command -v jq >/dev/null || fail "jq is required"

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/.." && pwd)"
cd "$repo_root"

# Sorts entries by key_id and object keys within each entry, so the comparison
# ignores ordering but not content.
normalized_trusted_keys() {
  jq -S '.trusted_keys | sort_by(.key_id)' "$1"
}

check_self_consistency() {
  local file="$1"

  jq -e '.trusted_keys | type == "array" and length > 0' "$file" >/dev/null \
    || fail "${file} must define a non-empty trusted_keys array"

  jq -e '[.trusted_keys[].key_id] | length == (unique | length)' "$file" >/dev/null \
    || fail "${file} lists a duplicate key_id, which makes signer attribution ambiguous"

  jq -e '[.trusted_keys[].pubkey] | length == (unique | length)' "$file" >/dev/null \
    || fail "${file} lists the same pubkey under more than one key_id"
}

report_difference() {
  local v1_file="$1"
  local v2_file="$2"

  printf 'error: %s and %s must trust the same keys\n' "$v1_file" "$v2_file" >&2

  jq -s -r '
    (.[0].trusted_keys | map({(.key_id): .}) | add) as $v1 |
    (.[1].trusted_keys | map({(.key_id): .}) | add) as $v2 |
    (($v1 | keys) - ($v2 | keys) | map("  only in v1: \(.)")) +
    (($v2 | keys) - ($v1 | keys) | map("  only in v2: \(.)")) +
    (($v1 | keys) | map(select(. as $k | $v2 | has($k)))
      | map(select(. as $k | $v1[$k] != $v2[$k]))
      | map("  differs between v1 and v2: \(.)"))
    | .[]
  ' "$v1_file" "$v2_file" >&2

  printf '  add, rotate, or retire a key in both files in the same change\n' >&2
  exit 1
}

checked_count=0

for v2_file in */v2-static-voting-config.json; do
  [[ -e "$v2_file" ]] || fail "no v2 static config found"

  environment_name="${v2_file%%/*}"
  v1_file="${environment_name}/static-voting-config.json"

  [[ -f "$v1_file" ]] \
    || fail "${v2_file} has no matching v1 static config at ${v1_file}"

  check_self_consistency "$v1_file"
  check_self_consistency "$v2_file"

  if ! diff -q \
    <(normalized_trusted_keys "$v1_file") \
    <(normalized_trusted_keys "$v2_file") >/dev/null; then
    report_difference "$v1_file" "$v2_file"
  fi

  checked_count=$((checked_count + 1))
done

[[ "$checked_count" -gt 0 ]] || fail "at least one environment must be checked"
printf 'Verified v1/v2 trusted key parity for %d environments\n' "$checked_count"
