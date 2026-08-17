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
test_root="$(make_test_temp_dir rollback-publication-test)"
server_pid=""

cleanup() {
  if [[ -n "$server_pid" ]]; then
    kill "$server_pid" >/dev/null 2>&1 || true
    wait "$server_pid" 2>/dev/null || true
  fi
  rm -rf "$test_root"
}
trap cleanup EXIT

port_file="${test_root}/port"
mode_file="${test_root}/mode"
rollback_log="${test_root}/rollbacks"
expected_revision=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
unrelated_revision=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
previous_deployment_id=previous-deployment

printf 'delayed\n' > "$mode_file"

python3 - \
  "$port_file" "$mode_file" "$rollback_log" \
  "$expected_revision" "$unrelated_revision" "$previous_deployment_id" <<'PY' &
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import json
import sys
from urllib.parse import urlsplit


mode_file = Path(sys.argv[2])
rollback_log = Path(sys.argv[3])
expected_revision = sys.argv[4]
unrelated_revision = sys.argv[5]
previous_deployment_id = sys.argv[6]


class Handler(BaseHTTPRequestHandler):
    delayed_project_requests = 0

    def log_message(self, _format, *_args):
        pass

    def send_json(self, value):
        body = json.dumps(value).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        request_path = urlsplit(self.path).path
        mode = mode_file.read_text(encoding="utf-8").strip()

        if request_path == "/client/v4/accounts/test-account/pages/projects/test-project":
            if mode == "delayed":
                Handler.delayed_project_requests += 1
                deployment = "previous" if Handler.delayed_project_requests == 1 else "automatic"
            elif mode == "unrelated":
                deployment = "unrelated"
            else:
                deployment = "previous"

            deployment_id = {
                "previous": previous_deployment_id,
                "automatic": "automatic-deployment",
                "unrelated": "manual-deployment",
            }[deployment]
            self.send_json({
                "success": True,
                "result": {
                    "canonical_deployment": {
                        "id": deployment_id,
                        "url": f"http://127.0.0.1:{self.server.server_port}/deployment/{deployment}",
                    },
                },
            })
        elif request_path == "/deployment/automatic/deployment-manifest.json":
            self.send_json({
                "source_revision": expected_revision,
                "publication_mode": "automatic",
            })
        elif request_path == "/deployment/unrelated/deployment-manifest.json":
            self.send_json({
                "source_revision": unrelated_revision,
                "publication_mode": "manual-emergency",
            })
        else:
            self.send_response(404)
            self.end_headers()

    def do_POST(self):
        request_path = urlsplit(self.path).path
        expected_path = (
            "/client/v4/accounts/test-account/pages/projects/test-project/"
            f"deployments/{previous_deployment_id}/rollback"
        )
        if request_path != expected_path:
            self.send_response(404)
            self.end_headers()
            return

        with rollback_log.open("a", encoding="utf-8") as output:
            output.write(f"{previous_deployment_id}\n")
        self.send_json({"success": True})


server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
Path(sys.argv[1]).write_text(str(server.server_port), encoding="utf-8")
server.serve_forever()
PY
server_pid=$!

for _ in {1..100}; do
  [[ -s "$port_file" ]] && break
  sleep 0.05
done
[[ -s "$port_file" ]] || fail "test server did not start"
api_base_url="http://127.0.0.1:$(cat "$port_file")/client/v4"

rollback_output="$(
  CLOUDFLARE_API_BASE_URL="$api_base_url" \
  CLOUDFLARE_API_TOKEN=test-token \
  ROLLBACK_DETECTION_TIMEOUT_SECONDS=5 \
  ROLLBACK_POLL_INTERVAL_SECONDS=0 \
    "${repo_root}/scripts/rollback-publication.sh" \
      test-account test-project "$previous_deployment_id" "$expected_revision"
)"
grep -F "Rolled back unverified publication ${expected_revision}" \
  <<< "$rollback_output" >/dev/null \
  || fail "delayed publication was not rolled back: ${rollback_output}"
[[ "$(wc -l < "$rollback_log" | tr -d ' ')" == 1 ]] \
  || fail "delayed publication did not issue exactly one rollback"

printf 'unrelated\n' > "$mode_file"
set +e
rollback_output="$(
  CLOUDFLARE_API_BASE_URL="$api_base_url" \
  CLOUDFLARE_API_TOKEN=test-token \
  ROLLBACK_DETECTION_TIMEOUT_SECONDS=1 \
  ROLLBACK_POLL_INTERVAL_SECONDS=0 \
    "${repo_root}/scripts/rollback-publication.sh" \
      test-account test-project "$previous_deployment_id" "$expected_revision" 2>&1
)"
rollback_status=$?
set -e
[[ "$rollback_status" -ne 0 ]] || fail "rollback replaced an unrelated publication"
grep -F "refusing to roll back unrelated manual-emergency publication ${unrelated_revision}" \
  <<< "$rollback_output" >/dev/null \
  || fail "unrelated publication failed for an unexpected reason: ${rollback_output}"
[[ "$(wc -l < "$rollback_log" | tr -d ' ')" == 1 ]] \
  || fail "rollback request was sent for an unrelated publication"

printf 'unchanged\n' > "$mode_file"
rollback_output="$(
  CLOUDFLARE_API_BASE_URL="$api_base_url" \
  CLOUDFLARE_API_TOKEN=test-token \
  ROLLBACK_DETECTION_TIMEOUT_SECONDS=1 \
  ROLLBACK_POLL_INTERVAL_SECONDS=1 \
    "${repo_root}/scripts/rollback-publication.sh" \
      test-account test-project "$previous_deployment_id" "$expected_revision"
)"
grep -F 'Production deployment did not change; rollback was not required.' \
  <<< "$rollback_output" >/dev/null \
  || fail "unchanged deployment did not produce a safe no-op: ${rollback_output}"
[[ "$(wc -l < "$rollback_log" | tr -d ' ')" == 1 ]] \
  || fail "rollback request was sent without a deployment change"

printf 'Publication rollback test passed\n'
