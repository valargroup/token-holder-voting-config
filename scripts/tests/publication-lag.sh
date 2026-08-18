#!/usr/bin/env bash
set -euo pipefail

fail() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/../.." && pwd)"
# shellcheck disable=SC1091
source "${script_dir}/lib/test-helpers.sh"
test_root="$(make_test_temp_dir publication-lag-test)"
server_pid=""

cleanup() {
  if [[ -n "$server_pid" ]]; then
    kill "$server_pid" >/dev/null 2>&1 || true
    wait "$server_pid" 2>/dev/null || true
  fi
  rm -rf "$test_root"
}
trap cleanup EXIT

manifest_file="${test_root}/deployment-manifest.json"
port_file="${test_root}/port"
expected_revision="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
stale_revision="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
expected_published_at="2026-08-18T00:00:00Z"

write_manifest() {
  local revision="$1"
  local published_at="${2:-$expected_published_at}"
  jq -n \
    --arg revision "$revision" \
    --arg published_at "$published_at" \
    '{source_revision: $revision, published_at: $published_at}' \
    > "$manifest_file"
}

write_manifest "$expected_revision"

python3 - "$manifest_file" "$port_file" <<'PY' &
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import sys
from urllib.parse import urlsplit

manifest_path = Path(sys.argv[1])
port_path = Path(sys.argv[2])


class Handler(BaseHTTPRequestHandler):
    def log_message(self, _format, *_args):
        pass

    def do_GET(self):
        if urlsplit(self.path).path != "/deployment-manifest.json":
            self.send_response(404)
            self.end_headers()
            return
        body = manifest_path.read_bytes()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
port_path.write_text(str(server.server_port), encoding="utf-8")
server.serve_forever()
PY
server_pid=$!

for _ in {1..100}; do
  [[ -s "$port_file" ]] && break
  sleep 0.05
done
[[ -s "$port_file" ]] || fail "test server did not start"

base_url="http://127.0.0.1:$(cat "$port_file")"
old_commit_epoch=$(( $(date +%s) - 10 ))
published_at="$(PUBLICATION_POLL_SECONDS=1 \
  "${repo_root}/scripts/wait-for-live-revision.sh" \
  "$base_url" "$expected_revision" "$old_commit_epoch" 1)"
[[ "$published_at" == "$expected_published_at" ]] \
  || fail "matching manifest returned the wrong publication time"

write_manifest "$stale_revision"
(
  sleep 1
  write_manifest "$expected_revision"
) &
update_pid=$!
current_epoch="$(date +%s)"
published_at="$(PUBLICATION_POLL_SECONDS=1 \
  "${repo_root}/scripts/wait-for-live-revision.sh" \
  "$base_url" "$expected_revision" "$current_epoch" 4)"
wait "$update_pid"
[[ "$published_at" == "$expected_published_at" ]] \
  || fail "propagated manifest returned the wrong publication time"

printf '%s\n' '{malformed' > "$manifest_file"
(
  sleep 1
  write_manifest "$expected_revision"
) &
update_pid=$!
current_epoch="$(date +%s)"
set +e
published_at="$(PUBLICATION_POLL_SECONDS=1 \
  "${repo_root}/scripts/wait-for-live-revision.sh" \
  "$base_url" "$expected_revision" "$current_epoch" 4 2>&1)"
publication_status=$?
set -e
wait "$update_pid"
[[ "$publication_status" -eq 0 ]] \
  || fail "malformed manifest response was not retried: ${published_at}"
[[ "$published_at" == "$expected_published_at" ]] \
  || fail "manifest recovered from a malformed response with the wrong publication time"

write_manifest "$expected_revision" "not-a-timestamp"
(
  sleep 1
  write_manifest "$expected_revision"
) &
update_pid=$!
current_epoch="$(date +%s)"
set +e
published_at="$(PUBLICATION_POLL_SECONDS=1 \
  "${repo_root}/scripts/wait-for-live-revision.sh" \
  "$base_url" "$expected_revision" "$current_epoch" 4 2>&1)"
publication_status=$?
set -e
wait "$update_pid"
[[ "$publication_status" -eq 0 ]] \
  || fail "manifest with an invalid publication time was not retried: ${published_at}"
[[ "$published_at" == "$expected_published_at" ]] \
  || fail "manifest recovered from an invalid publication time with the wrong value"

write_manifest "$expected_revision"
set +e
failure_output="$(PUBLICATION_REQUIRE_ON_TIME=true PUBLICATION_POLL_SECONDS=1 \
  "${repo_root}/scripts/wait-for-live-revision.sh" \
  "$base_url" "$expected_revision" "$old_commit_epoch" 1 2>&1)"
failure_status=$?
set -e
[[ "$failure_status" -ne 0 ]] || fail "late publication observation unexpectedly passed"
grep -F "first observed ${expected_revision} after the 1s deadline" \
  <<< "$failure_output" >/dev/null \
  || fail "late publication observation failed for an unexpected reason: ${failure_output}"

write_manifest "$stale_revision"
set +e
failure_output="$(PUBLICATION_POLL_SECONDS=1 \
  "${repo_root}/scripts/wait-for-live-revision.sh" \
  "$base_url" "$expected_revision" "$old_commit_epoch" 1 2>&1)"
failure_status=$?
set -e
[[ "$failure_status" -ne 0 ]] || fail "stale publication unexpectedly passed"
grep -F "did not reach ${expected_revision} within 1s" <<< "$failure_output" >/dev/null \
  || fail "stale publication failed for an unexpected reason: ${failure_output}"

printf 'Publication lag test passed\n'
