#!/usr/bin/env bash
set -euo pipefail

fail() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

if [[ $# -ne 2 ]]; then
  fail "usage: $0 DEPLOYMENT_URL EXPECTED_REVISION"
fi

command -v curl >/dev/null || fail "curl is required"
command -v jq >/dev/null || fail "jq is required"

deployment_url="${1%/}"
expected_revision="$2"

case "$deployment_url" in
  https://*|http://127.0.0.1:*|http://localhost:*) ;;
  *) fail "DEPLOYMENT_URL must use HTTPS" ;;
esac

[[ "$expected_revision" =~ ^[0-9a-f]{40}$ ]] \
  || fail "EXPECTED_REVISION must be a full Git commit"
git rev-parse --verify "${expected_revision}^{commit}" >/dev/null 2>&1 \
  || fail "EXPECTED_REVISION is not available in local history"

manifest="$(curl --fail --silent --show-error --location \
  --connect-timeout 10 --max-time 30 \
  --retry 3 --retry-delay 1 --retry-all-errors \
  --header 'Cache-Control: no-cache' \
  "${deployment_url}/deployment-manifest.json?reconciliation-check=$(date +%s)")" \
  || fail "could not fetch the current deployment manifest"

live_revision="$(jq -er '.source_revision | select(test("^[0-9a-f]{40}$"))' <<< "$manifest")" \
  || fail "current deployment manifest has an invalid source revision"
publication_mode="$(jq -er '.publication_mode | select(. == "automatic" or . == "manual-bootstrap" or . == "manual-emergency")' <<< "$manifest")" \
  || fail "current deployment manifest has an invalid publication mode"

git cat-file -e "${live_revision}^{commit}" 2>/dev/null \
  || fail "refusing to supersede unreconciled ${publication_mode} publication ${live_revision}"
git merge-base --is-ancestor "$live_revision" "$expected_revision" \
  || fail "refusing to supersede unreconciled ${publication_mode} publication ${live_revision}"

printf 'Confirmed deployed predecessor: %s\n' "$live_revision"
