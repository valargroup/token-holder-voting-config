#!/usr/bin/env bash
set -euo pipefail

fail() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

if [[ $# -ne 3 ]]; then
  fail "usage: $0 CLOUDFLARE_ACCOUNT_ID CLOUDFLARE_PAGES_PROJECT EXPECTED_REVISION"
fi

command -v curl >/dev/null || fail "curl is required"
command -v jq >/dev/null || fail "jq is required"

account_id="$1"
pages_project="$2"
expected_revision="$3"
api_base_url="${CLOUDFLARE_API_BASE_URL:-https://api.cloudflare.com/client/v4}"
api_token="${CLOUDFLARE_API_TOKEN:-}"

[[ "$account_id" =~ ^[A-Za-z0-9_-]+$ ]] || fail "invalid Cloudflare account ID"
[[ "$pages_project" =~ ^[A-Za-z0-9_-]+$ ]] || fail "invalid Cloudflare Pages project"
[[ -n "$api_token" ]] || fail "CLOUDFLARE_API_TOKEN is required"

case "$api_base_url" in
  https://*|http://127.0.0.1:*|http://localhost:*) ;;
  *) fail "CLOUDFLARE_API_BASE_URL must use HTTPS" ;;
esac

[[ "$expected_revision" =~ ^[0-9a-f]{40}$ ]] \
  || fail "EXPECTED_REVISION must be a full Git commit"
git rev-parse --verify "${expected_revision}^{commit}" >/dev/null 2>&1 \
  || fail "EXPECTED_REVISION is not available in local history"

fetch_current_deployment() {
  curl --fail --silent --show-error --location \
    --connect-timeout 10 --max-time 30 \
    --retry 3 --retry-delay 1 --retry-all-errors \
    --header "Authorization: Bearer ${api_token}" \
    "${api_base_url%/}/accounts/${account_id}/pages/projects/${pages_project}"
}

deployments_response="$(fetch_current_deployment)" \
  || fail "could not resolve the current production deployment"
jq -e '.success == true and (.result.canonical_deployment | type) == "object"' \
  <<< "$deployments_response" >/dev/null \
  || fail "Cloudflare returned no current production deployment"

deployment_id="$(jq -er '.result.canonical_deployment.id | select(type == "string" and length > 0)' \
  <<< "$deployments_response")" \
  || fail "current production deployment has an invalid ID"
deployment_url="$(jq -er '.result.canonical_deployment.url | select(type == "string" and length > 0)' \
  <<< "$deployments_response")" \
  || fail "current production deployment has an invalid URL"
case "$deployment_url" in
  https://*|http://127.0.0.1:*|http://localhost:*) ;;
  *) fail "current production deployment URL must use HTTPS" ;;
esac

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

confirmed_response="$(fetch_current_deployment)" \
  || fail "could not confirm the current production deployment"
confirmed_id="$(jq -er '.result.canonical_deployment.id | select(type == "string" and length > 0)' \
  <<< "$confirmed_response")" \
  || fail "confirmed production deployment has an invalid ID"
[[ "$confirmed_id" == "$deployment_id" ]] \
  || fail "production deployment changed during publication preflight"

printf 'Confirmed deployed predecessor: %s (%s)\n' "$live_revision" "$deployment_id"
