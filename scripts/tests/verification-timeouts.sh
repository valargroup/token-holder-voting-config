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
test_root="$(make_test_temp_dir verification-timeouts-test)"
server_pid=""

cleanup() {
  if [[ -n "$server_pid" ]]; then
    kill "$server_pid" >/dev/null 2>&1 || true
    wait "$server_pid" 2>/dev/null || true
  fi
  rm -rf "$test_root"
}
trap cleanup EXIT

expected_dir="${test_root}/expected"
port_file="${test_root}/port"
SOURCE_REVISION=local-test \
  "${repo_root}/scripts/build-cloudflare-pages.sh" "$expected_dir" >/dev/null

python3 - "$port_file" <<'PY' &
import socket
import sys
import time

server = socket.socket()
server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
server.bind(("127.0.0.1", 0))
server.listen()

with open(sys.argv[1], "w", encoding="utf-8") as port_file:
    port_file.write(str(server.getsockname()[1]))

while True:
    connection, _ = server.accept()
    with connection:
        time.sleep(60)
PY
server_pid=$!

for _ in {1..100}; do
  [[ -s "$port_file" ]] && break
  sleep 0.05
done
[[ -s "$port_file" ]] || fail "test server did not start"

port="$(cat "$port_file")"
started_at="$(date +%s)"
set +e
verify_output="$(
  VERIFY_CONNECT_TIMEOUT_SECONDS=1 \
  VERIFY_MAX_TIME_SECONDS=1 \
  VERIFY_RETRY_COUNT=0 \
  VERIFY_RETRY_DELAY_SECONDS=0 \
  VERIFY_RETRY_MAX_TIME_SECONDS=1 \
  VERIFY_DEADLINE_SECONDS=2 \
  VERIFY_POLL_INTERVAL_SECONDS=0 \
    "${repo_root}/scripts/verify-publication.sh" \
      "http://127.0.0.1:${port}" "$expected_dir" 2>&1
)"
verify_status=$?
set -e
elapsed_seconds=$(( $(date +%s) - started_at ))

[[ "$verify_status" -ne 0 ]] || fail "verification accepted a stalled response"
[[ "$elapsed_seconds" -lt 5 ]] \
  || fail "verification did not enforce its request timeout after ${elapsed_seconds} seconds"
grep -F 'curl: (28)' <<< "$verify_output" >/dev/null \
  || fail "verification failed for an unexpected reason: ${verify_output}"

printf 'Publication verification timeout test passed\n'
