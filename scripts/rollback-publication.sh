#!/usr/bin/env bash
set -euo pipefail

fail() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

if [[ $# -ne 4 ]]; then
  fail "usage: $0 CLOUDFLARE_ACCOUNT_ID CLOUDFLARE_PAGES_PROJECT PREVIOUS_DEPLOYMENT_ID EXPECTED_REVISION"
fi

command -v curl >/dev/null || fail "curl is required"
command -v jq >/dev/null || fail "jq is required"

account_id="$1"
pages_project="$2"
previous_deployment_id="$3"
expected_revision="$4"
api_base_url="${CLOUDFLARE_API_BASE_URL:-https://api.cloudflare.com/client/v4}"
api_token="${CLOUDFLARE_API_TOKEN:-}"
detection_timeout_seconds="${ROLLBACK_DETECTION_TIMEOUT_SECONDS:-60}"
poll_interval_seconds="${ROLLBACK_POLL_INTERVAL_SECONDS:-2}"

[[ "$account_id" =~ ^[A-Za-z0-9_-]+$ ]] || fail "invalid Cloudflare account ID"
[[ "$pages_project" =~ ^[A-Za-z0-9_-]+$ ]] || fail "invalid Cloudflare Pages project"
[[ "$previous_deployment_id" =~ ^[A-Za-z0-9_-]+$ ]] \
  || fail "invalid previous Cloudflare deployment ID"
[[ "$expected_revision" =~ ^[0-9a-f]{40}$ ]] \
  || fail "EXPECTED_REVISION must be a full Git commit"
[[ -n "$api_token" ]] || fail "CLOUDFLARE_API_TOKEN is required"
[[ "$detection_timeout_seconds" =~ ^[1-9][0-9]*$ ]] \
  || fail "ROLLBACK_DETECTION_TIMEOUT_SECONDS must be a positive integer"
[[ "$poll_interval_seconds" =~ ^[0-9]+$ ]] \
  || fail "ROLLBACK_POLL_INTERVAL_SECONDS must be a non-negative integer"

case "$api_base_url" in
  https://*|http://127.0.0.1:*|http://localhost:*) ;;
  *) fail "CLOUDFLARE_API_BASE_URL must use HTTPS" ;;
esac

project_url="${api_base_url%/}/accounts/${account_id}/pages/projects/${pages_project}"
detection_deadline=$((SECONDS + detection_timeout_seconds))

fetch_project() {
  curl --fail --silent --show-error --location \
    --connect-timeout 10 --max-time 30 \
    --retry 3 --retry-delay 1 --retry-all-errors \
    --header "Authorization: Bearer ${api_token}" \
    "$project_url"
}

fetch_manifest() {
  local deployment_url="$1"
  curl --fail --silent --show-error --location \
    --connect-timeout 10 --max-time 30 \
    --retry 3 --retry-delay 1 --retry-all-errors \
    --header 'Cache-Control: no-cache' \
    "${deployment_url%/}/deployment-manifest.json?rollback-check=$(date +%s)"
}

while true; do
  project_response="$(fetch_project)" \
    || fail "could not resolve the current production deployment"
  jq -e '.success == true and (.result.canonical_deployment | type) == "object"' \
    <<< "$project_response" >/dev/null \
    || fail "Cloudflare returned no current production deployment"

  current_deployment_id="$(jq -er \
    '.result.canonical_deployment.id | select(type == "string" and length > 0)' \
    <<< "$project_response")" \
    || fail "current production deployment has an invalid ID"

  if [[ "$current_deployment_id" != "$previous_deployment_id" ]]; then
    current_deployment_url="$(jq -er \
      '.result.canonical_deployment.url | select(type == "string" and length > 0)' \
      <<< "$project_response")" \
      || fail "current production deployment has an invalid URL"
    case "$current_deployment_url" in
      https://*|http://127.0.0.1:*|http://localhost:*) ;;
      *) fail "current production deployment URL must use HTTPS" ;;
    esac

    if manifest="$(fetch_manifest "$current_deployment_url")"; then
      live_revision="$(jq -er '.source_revision | select(test("^[0-9a-f]{40}$"))' \
        <<< "$manifest")" \
        || fail "current deployment manifest has an invalid source revision"
      publication_mode="$(jq -er '.publication_mode | select(type == "string")' \
        <<< "$manifest")" \
        || fail "current deployment manifest has an invalid publication mode"

      if [[ "$live_revision" != "$expected_revision" || "$publication_mode" != automatic ]]; then
        fail "refusing to roll back unrelated ${publication_mode} publication ${live_revision}"
      fi

      confirmed_response="$(fetch_project)" \
        || fail "could not confirm the current production deployment"
      confirmed_deployment_id="$(jq -er \
        '.result.canonical_deployment.id | select(type == "string" and length > 0)' \
        <<< "$confirmed_response")" \
        || fail "confirmed production deployment has an invalid ID"
      [[ "$confirmed_deployment_id" == "$current_deployment_id" ]] \
        || fail "production deployment changed before rollback"

      rollback_response="$(curl --fail --silent --show-error --request POST \
        --connect-timeout 10 --max-time 30 \
        --header "Authorization: Bearer ${api_token}" \
        "${project_url}/deployments/${previous_deployment_id}/rollback")" \
        || fail "Cloudflare rollback request failed"
      jq -e '.success == true' <<< "$rollback_response" >/dev/null \
        || fail "Cloudflare rejected the rollback request"
      printf 'Rolled back unverified publication %s to deployment %s\n' \
        "$expected_revision" "$previous_deployment_id"
      exit 0
    fi
  fi

  if (( SECONDS >= detection_deadline )); then
    if [[ "$current_deployment_id" == "$previous_deployment_id" ]]; then
      printf 'Production deployment did not change; rollback was not required.\n'
      exit 0
    fi
    fail "could not verify the changed production deployment before the rollback deadline"
  fi
  sleep "$poll_interval_seconds"
done
