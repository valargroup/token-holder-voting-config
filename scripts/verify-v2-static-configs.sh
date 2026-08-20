#!/usr/bin/env bash
set -euo pipefail

# Verifies every v2 static config's trusted_keys against its environment's
# dynamic config.
#
# The pinned voting-config verifier predates the v2 schema: it compares
# static_config_version for exact equality with 1 and requires a singular
# dynamic_config_url, so it rejects a v2 document outright. Until vote-sdk
# understands static_config_version 2, each v2 document is projected onto the v1
# shape it is equivalent to - same trusted_keys, the canonical mirror as the
# single URL - and that projection is verified instead. The signature check this
# performs is exactly the one that matters: every key a wallet would trust from
# the v2 file really does authenticate that environment's rounds.
#
# Delete this shim and verify the v2 files directly once the pinned verifier
# supports them. The v2-specific shape is enforced by build-cloudflare-pages.sh.

fail() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

command -v voting-config >/dev/null || fail "voting-config is required"
command -v jq >/dev/null || fail "jq is required"

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/.." && pwd)"
cd "$repo_root"

work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT

verified_count=0

verify_v2_static_config() {
  local file="$1"
  local environment_name="$2"
  local projection="${work_dir}/v1-projection.json"

  jq --exit-status '
    {
      static_config_version: 1,
      dynamic_config_url: .dynamic_config_urls[0],
      trusted_keys: .trusted_keys
    }
  ' "$file" > "$projection" \
    || fail "cannot project ${file} onto the v1 static config shape"

  voting-config verify \
    --config "${environment_name}/dynamic-voting-config.json" \
    --static-config "$projection" \
    || fail "v2 static config failed verification: ${file}"

  verified_count=$((verified_count + 1))
}

verify_v2_static_config prod/v2-static-voting-config.json prod
verify_v2_static_config stage/v2-static-voting-config.json stage

while IFS= read -r pin; do
  [[ "$pin" =~ ^pins/(test/)?(prod|stage)/[0-9a-f]{64}/v2-static-voting-config\.json$ ]] \
    || fail "unexpected immutable v2 pin path: ${pin}"
  verify_v2_static_config "$pin" "${BASH_REMATCH[2]}"
done < <(find pins -type f -name v2-static-voting-config.json -print | sort)

[[ "$verified_count" -gt 0 ]] || fail "at least one v2 static config is required"
printf 'Verified %d v2 static configs against their environment dynamic configs\n' "$verified_count"
