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

python3 - "$serve_root" "$port_file" <<'PY' &
from functools import partial
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import sys


class QuietHandler(SimpleHTTPRequestHandler):
    def log_message(self, _format, *_args):
        pass


serve_root = Path(sys.argv[1])
handler = partial(QuietHandler, directory=str(serve_root))
server = ThreadingHTTPServer(("127.0.0.1", 0), handler)
Path(sys.argv[2]).write_text(str(server.server_port), encoding="utf-8")
server.serve_forever()
PY
server_pid=$!

for _ in {1..100}; do
  [[ -s "$port_file" ]] && break
  sleep 0.05
done
[[ -s "$port_file" ]] || fail "test server did not start"
deployment_url="http://127.0.0.1:$(cat "$port_file")"

set +e
guard_output="$(
  "${repo_root}/scripts/require-reconciled-publication.sh" \
    "$deployment_url" "$main_revision" 2>&1
)"
guard_status=$?
set -e

[[ "$guard_status" -ne 0 ]] || fail "guard accepted an unreconciled emergency publication"
grep -F "refusing to supersede unreconciled manual-emergency publication ${emergency_revision}" \
  <<< "$guard_output" >/dev/null \
  || fail "guard failed for an unexpected reason: ${guard_output}"

git merge --quiet --no-ff emergency -m reconcile
reconciled_revision="$(git rev-parse HEAD)"
"${repo_root}/scripts/require-reconciled-publication.sh" \
  "$deployment_url" "$reconciled_revision" >/dev/null

printf 'Emergency publication reconciliation test passed\n'
