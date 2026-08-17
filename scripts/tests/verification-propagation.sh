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
test_root="$(make_test_temp_dir verification-propagation-test)"
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
stale_marker="${test_root}/served-stale"
SOURCE_REVISION=local-test \
PUBLICATION_MODE=local-test \
PUBLISHED_AT=2026-08-17T00:00:00Z \
  "${repo_root}/scripts/build-cloudflare-pages.sh" "$expected_dir" >/dev/null

python3 - "$expected_dir" "$port_file" "$stale_marker" <<'PY' &
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import sys
from urllib.parse import urlsplit

root = Path(sys.argv[1]).resolve()
port_path = Path(sys.argv[2])
stale_marker = Path(sys.argv[3])


class Handler(BaseHTTPRequestHandler):
    stale_sent = False

    def log_message(self, _format, *_args):
        pass

    def cache_control(self, request_path):
        if request_path.startswith("pins/"):
            return "public, max-age=31536000, immutable"
        if request_path.endswith("static-voting-config.json"):
            return "public, max-age=300, must-revalidate, stale-if-error=86400"
        return "public, max-age=60, must-revalidate, stale-if-error=86400"

    def respond(self, include_body):
        request_path = urlsplit(self.path).path.lstrip("/")
        if request_path == "test/valar-test.seed.b64":
            self.send_response(404)
            self.end_headers()
            return

        candidate = (root / request_path).resolve()
        if root not in candidate.parents or not candidate.is_file():
            self.send_response(404)
            self.end_headers()
            return

        body = candidate.read_bytes()
        if request_path == "prod/dynamic-voting-config.json" and not Handler.stale_sent:
            body = b"{}\n"
            Handler.stale_sent = True
            stale_marker.touch()

        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", self.cache_control(request_path))
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()
        if include_body:
            self.wfile.write(body)

    def do_GET(self):
        self.respond(True)

    def do_HEAD(self):
        self.respond(False)


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

port="$(cat "$port_file")"
set +e
verify_output="$(
  VERIFY_CONNECT_TIMEOUT_SECONDS=1 \
  VERIFY_MAX_TIME_SECONDS=2 \
  VERIFY_RETRY_COUNT=0 \
  VERIFY_RETRY_DELAY_SECONDS=0 \
  VERIFY_RETRY_MAX_TIME_SECONDS=2 \
  VERIFY_DEADLINE_SECONDS=10 \
  VERIFY_POLL_INTERVAL_SECONDS=0 \
    "${repo_root}/scripts/verify-publication.sh" \
      "http://127.0.0.1:${port}" "$expected_dir" local-test 2>&1
)"
verify_status=$?
set -e

[[ "$verify_status" -eq 0 ]] \
  || fail "verification did not tolerate stale propagation: ${verify_output}"
[[ -f "$stale_marker" ]] || fail "test server did not return a stale HTTP 200 response"
grep -F 'Waiting for published bytes for prod/dynamic-voting-config.json' \
  <<< "$verify_output" >/dev/null \
  || fail "verification did not poll the stale response"

printf 'Publication propagation test passed\n'
