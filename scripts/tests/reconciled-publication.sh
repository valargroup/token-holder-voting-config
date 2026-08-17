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
test_root="$(make_test_temp_dir reconciled-publication-test)"
server_pid=""

cleanup() {
  if [[ -n "$server_pid" ]]; then
    kill "$server_pid" >/dev/null 2>&1 || true
    wait "$server_pid" 2>/dev/null || true
  fi
  rm -rf "$test_root"
}
trap cleanup EXIT

test_repo="${test_root}/repo"
serve_root="${test_root}/serve"
port_file="${test_root}/port"
api_marker="${test_root}/api-requested"
mkdir -p "$test_repo" "$serve_root"

cd "$test_repo"
git init --quiet --initial-branch=main
git config user.name codex-test
git config user.email codex-test@example.invalid
printf 'reviewed\n' > config
git add config
git commit --quiet -m reviewed
main_revision="$(git rev-parse HEAD)"

git switch --quiet -c emergency
printf 'emergency\n' > config
git commit --quiet -am emergency
emergency_revision="$(git rev-parse HEAD)"
git switch --quiet main

jq -n \
  --arg source_revision "$emergency_revision" \
  '{schema_version: 1, source_revision: $source_revision, publication_mode: "manual-emergency"}' \
  > "${serve_root}/deployment-manifest.json"

python3 - "$serve_root" "$port_file" "$api_marker" <<'PY' &
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import json
import sys
from urllib.parse import urlsplit


serve_root = Path(sys.argv[1])
api_marker = Path(sys.argv[3])


class Handler(BaseHTTPRequestHandler):
    def log_message(self, _format, *_args):
        pass

    def do_GET(self):
        request_path = urlsplit(self.path).path
        if request_path == "/client/v4/accounts/test-account/pages/projects/test-project":
            api_marker.touch()
            body = json.dumps({
                "success": True,
                "result": {
                    "canonical_deployment": {
                        "id": "current-deployment",
                        "url": f"http://127.0.0.1:{self.server.server_port}/deployment",
                    },
                    "latest_deployment": {
                        "id": "newer-failed-deployment",
                        "url": f"http://127.0.0.1:{self.server.server_port}/failed",
                    },
                },
            }).encode()
        elif request_path == "/deployment/deployment-manifest.json":
            body = (serve_root / "deployment-manifest.json").read_bytes()
        else:
            self.send_response(404)
            self.end_headers()
            return

        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
Path(sys.argv[2]).write_text(str(server.server_port), encoding="utf-8")
server.serve_forever()
PY
server_pid=$!

for _ in {1..100}; do
  [[ -s "$port_file" ]] && break
  sleep 0.05
done
[[ -s "$port_file" ]] || fail "test server did not start"
api_base_url="http://127.0.0.1:$(cat "$port_file")/client/v4"

set +e
guard_output="$(
  CLOUDFLARE_API_BASE_URL="$api_base_url" \
  CLOUDFLARE_API_TOKEN=test-token \
  "${repo_root}/scripts/require-reconciled-publication.sh" \
    test-account test-project "$main_revision" 2>&1
)"
guard_status=$?
set -e

[[ "$guard_status" -ne 0 ]] || fail "guard accepted an unreconciled emergency publication"
grep -F "refusing to supersede unreconciled manual-emergency publication ${emergency_revision}" \
  <<< "$guard_output" >/dev/null \
  || fail "guard failed for an unexpected reason: ${guard_output}"
[[ -f "$api_marker" ]] || fail "guard did not query the current Cloudflare deployment"

git merge --quiet --no-ff emergency -m reconcile
reconciled_revision="$(git rev-parse HEAD)"
CLOUDFLARE_API_BASE_URL="$api_base_url" \
CLOUDFLARE_API_TOKEN=test-token \
"${repo_root}/scripts/require-reconciled-publication.sh" \
  test-account test-project "$reconciled_revision" >/dev/null

printf 'Emergency publication reconciliation test passed\n'
