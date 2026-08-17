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

printf 'Verified dynamic configs against frozen GitHub Pages keys\n'
