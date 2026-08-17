#!/usr/bin/env bash
set -euo pipefail

fail() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

if [[ $# -lt 2 || $# -gt 3 ]]; then
  fail "usage: $0 CLOUDFLARE_BASE_URL EXPECTED_DIRECTORY [EXPECTED_SOURCE_REVISION]"
fi

cloudflare_base_url="$1"
expected_dir="$2"
expected_revision="${3:-}"
raw_probe="https://raw.githubusercontent.com/valargroup/token-holder-voting-config/main/stage/dynamic-voting-config.json"

if curl --fail --silent --show-error --noproxy '*' \
  --connect-timeout 2 --max-time 3 \
  --resolve raw.githubusercontent.com:443:127.0.0.1 \
  "$raw_probe" --output /dev/null 2>/dev/null; then
  fail "the isolated GitHub outage probe unexpectedly succeeded"
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -n "$expected_revision" ]]; then
  "$script_dir/verify-publication.sh" "$cloudflare_base_url" "$expected_dir" "$expected_revision"
else
  "$script_dir/verify-publication.sh" "$cloudflare_base_url" "$expected_dir"
fi

printf 'GitHub raw was unavailable to the isolated probe; the Cloudflare snapshot remained complete.\n'
