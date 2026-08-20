#!/usr/bin/env bash
set -euo pipefail

fail() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

command -v voting-config >/dev/null || fail "voting-config is required"

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/.." && pwd)"
cd "$repo_root"

voting-config verify \
  --config prod/dynamic-voting-config.json \
  --static-config legacy/github-pages/prod/static-voting-config.json
voting-config verify \
  --config stage/dynamic-voting-config.json \
  --static-config legacy/github-pages/stage/static-voting-config.json
voting-config verify \
  --config prod/dynamic-voting-config.json \
  --static-config legacy/github-pages/test/prod-static-voting-config-duplicate.json
voting-config verify \
  --config stage/dynamic-voting-config.json \
  --static-config legacy/github-pages/test/static-voting-config-duplicate.json

pin_count=0
while IFS= read -r pin; do
  if ! [[ "$pin" =~ ^pins/(test/)?(prod|stage)/[0-9a-f]{64}/(v2-)?static-voting-config\.json$ ]]; then
    fail "unexpected immutable pin path: ${pin}"
  fi
  environment_name="${BASH_REMATCH[2]}"
  voting-config verify \
    --config "${environment_name}/dynamic-voting-config.json" \
    --static-config "$pin"
  pin_count=$((pin_count + 1))
done < <(find pins -type f -name static-voting-config.json -print | sort)

[[ "$pin_count" -gt 0 ]] || fail "at least one immutable static-config pin is required"
printf 'Verified dynamic configs against frozen aliases and %d immutable pins\n' "$pin_count"

# v2 pins are skipped by the loop above (it selects v1 pins by name) and are
# verified through the projection shim instead.
"${script_dir}/verify-v2-static-configs.sh"
