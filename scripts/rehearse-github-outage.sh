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
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
github_outage_curl_args=()
# shellcheck disable=SC1091
source "${script_dir}/lib/github-outage-curl.sh"

if curl --fail --silent --show-error \
  --connect-timeout 2 --max-time 3 \
  "${github_outage_curl_args[@]}" \
  "$raw_probe" --output /dev/null 2>/dev/null; then
  fail "the isolated GitHub outage probe unexpectedly succeeded"
fi

if [[ -n "$expected_revision" ]]; then
  VERIFY_GITHUB_OUTAGE_ISOLATION=true \
    "$script_dir/verify-publication.sh" "$cloudflare_base_url" "$expected_dir" "$expected_revision"
else
  VERIFY_GITHUB_OUTAGE_ISOLATION=true \
    "$script_dir/verify-publication.sh" "$cloudflare_base_url" "$expected_dir"
fi

printf 'GitHub remained isolated while the Cloudflare snapshot was verified.\n'
