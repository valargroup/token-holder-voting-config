#!/usr/bin/env bash
set -euo pipefail

fail() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

if [[ $# -ne 1 ]]; then
  fail "usage: $0 EXPECTED_REVISION"
fi

expected_revision="$1"
remote_name="${VOTING_CONFIG_REMOTE:-origin}"

[[ "$expected_revision" =~ ^[0-9a-f]{40}$ ]] \
  || fail "EXPECTED_REVISION must be a full Git commit"

remote_line="$(git ls-remote --exit-code "$remote_name" refs/heads/main)" \
  || fail "could not resolve ${remote_name}/main"
latest_revision="$(awk '{print $1}' <<< "$remote_line")"

[[ "$latest_revision" =~ ^[0-9a-f]{40}$ ]] \
  || fail "${remote_name}/main did not resolve to a full Git commit"
[[ "$expected_revision" == "$latest_revision" ]] \
  || fail "refusing stale publication: expected ${expected_revision}, but ${remote_name}/main is ${latest_revision}"

printf 'Confirmed latest main revision: %s\n' "$expected_revision"
