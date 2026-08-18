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
prod_pir_header_marker="${test_root}/served-stale-prod-pir-header"
stage_pir_header_marker="${test_root}/served-stale-stage-pir-header"
stage_static_header_marker="${test_root}/served-stale-stage-static-header"
manifest_header_marker="${test_root}/served-stale-manifest-header"
test_alias_header_marker="${test_root}/checked-test-alias-headers"
github_redirect_marker="${test_root}/redirect-through-github"
redirect_final_header_marker="${test_root}/served-stale-redirect-final-header"
fallback_header_marker="${test_root}/received-fallback-rehearsal-header"
normal_fallback_marker="${test_root}/served-normal-cloudflare-origin"
corrupt_primary_marker="${test_root}/served-corrupt-primary-response"
SOURCE_REVISION=local-test \
PUBLISHED_AT=2026-08-17T00:00:00Z \
  "${repo_root}/scripts/build-cloudflare-pages.sh" "$expected_dir" >/dev/null

python3 - \
  "$expected_dir" "$port_file" "$stale_marker" \
  "$prod_pir_header_marker" "$stage_pir_header_marker" \
  "$stage_static_header_marker" "$manifest_header_marker" \
  "$test_alias_header_marker" "$github_redirect_marker" \
  "$redirect_final_header_marker" "$fallback_header_marker" \
  "$normal_fallback_marker" "$corrupt_primary_marker" <<'PY' &
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import sys
from urllib.parse import urlsplit

root = Path(sys.argv[1]).resolve()
port_path = Path(sys.argv[2])
stale_marker = Path(sys.argv[3])
prod_pir_header_marker = Path(sys.argv[4])
stage_pir_header_marker = Path(sys.argv[5])
stage_static_header_marker = Path(sys.argv[6])
manifest_header_marker = Path(sys.argv[7])
test_alias_header_marker = Path(sys.argv[8])
github_redirect_marker = Path(sys.argv[9])
redirect_final_header_marker = Path(sys.argv[10])
fallback_header_marker = Path(sys.argv[11])
normal_fallback_marker = Path(sys.argv[12])
corrupt_primary_marker = Path(sys.argv[13])


class Handler(BaseHTTPRequestHandler):
    stale_sent = False
    stale_prod_pir_header_sent = False
    stale_stage_pir_header_sent = False
    stale_stage_static_header_sent = False
    stale_manifest_header_sent = False
    stale_redirect_final_header_sent = False

    def log_message(self, _format, *_args):
        pass

    def cache_control(self, request_path):
        if request_path.startswith("pins/"):
            return "public, max-age=31536000, immutable"
        if request_path.startswith("test/") or request_path.endswith("static-voting-config.json"):
            return "public, max-age=300, must-revalidate, stale-if-error=86400"
        return "public, max-age=60, must-revalidate, stale-if-error=86400"

    def respond(self, include_body):
        request_url = urlsplit(self.path)
        request_path = request_url.path.lstrip("/")
        request_host = self.headers.get("Host", "").split(":", 1)[0]
        forced_fallback = (
            self.headers.get("X-Voting-Config-Rehearsal") == "github-outage"
        )
        if forced_fallback:
            fallback_header_marker.touch()
        if request_path == "test/valar-test.seed.b64":
            self.send_response(404)
            self.end_headers()
            return

        if (
            github_redirect_marker.exists()
            and request_path == "prod/dynamic-voting-config.json"
            and request_host in {"127.0.0.1", "localhost"}
        ):
            self.send_response(302)
            if not include_body:
                self.send_header(
                    "Cache-Control",
                    "public, max-age=60, must-revalidate, stale-if-error=86400",
                )
            self.send_header(
                "Location",
                f"http://raw.githubusercontent.com:{self.server.server_port}/{request_path}",
            )
            self.end_headers()
            return

        candidate = (root / request_path).resolve()
        if root not in candidate.parents or not candidate.is_file():
            self.send_response(404)
            self.end_headers()
            return

        body = candidate.read_bytes()
        if (
            corrupt_primary_marker.exists()
            and request_path == "prod/pir.json"
            and request_url.query.startswith("source-check=")
        ):
            body = b"{}\n"
        if request_path == "prod/dynamic-voting-config.json" and not Handler.stale_sent:
            body = b"{}\n"
            Handler.stale_sent = True
            stale_marker.touch()

        cache_control = self.cache_control(request_path)
        if not include_body and request_path in {
            "test/prod-static-voting-config-duplicate.json",
            "test/static-voting-config-duplicate.json",
        }:
            with test_alias_header_marker.open("a", encoding="utf-8") as marker:
                marker.write(f"{request_path}\n")
        if not include_body and request_path == "prod/pir.json" and not Handler.stale_prod_pir_header_sent:
            cache_control = "public, max-age=600, must-revalidate, stale-if-error=86400"
            Handler.stale_prod_pir_header_sent = True
            prod_pir_header_marker.touch()
        if not include_body and request_path == "stage/pir.json" and not Handler.stale_stage_pir_header_sent:
            cache_control = "public, max-age=60, must-revalidate"
            Handler.stale_stage_pir_header_sent = True
            stage_pir_header_marker.touch()
        if (
            not include_body
            and request_path == "stage/static-voting-config.json"
            and not Handler.stale_stage_static_header_sent
        ):
            cache_control = "public, max-age=86400"
            Handler.stale_stage_static_header_sent = True
            stage_static_header_marker.touch()
        if (
            not include_body
            and request_path == "deployment-manifest.json"
            and not Handler.stale_manifest_header_sent
        ):
            cache_control = "public, max-age=86400"
            Handler.stale_manifest_header_sent = True
            manifest_header_marker.touch()
        if (
            not include_body
            and github_redirect_marker.exists()
            and request_host == "raw.githubusercontent.com"
            and request_path == "prod/dynamic-voting-config.json"
            and not Handler.stale_redirect_final_header_sent
        ):
            cache_control = "public, max-age=600, must-revalidate, stale-if-error=86400"
            Handler.stale_redirect_final_header_sent = True
            redirect_final_header_marker.touch()

        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", cache_control)
        self.send_header("Access-Control-Allow-Origin", "*")
        response_origin = "cloudflare" if (
            forced_fallback
            or request_path == "deployment-manifest.json"
            or request_path.endswith(".sha256")
            or (
                normal_fallback_marker.exists()
                and request_path == "prod/pir.json"
            )
        ) else "github"
        self.send_header("X-Voting-Config-Origin", response_origin)
        self.send_header("X-Voting-Config-Revision", "local-test")
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
[[ -f "$prod_pir_header_marker" ]] || fail "verification did not inspect the production PIR cache header"
[[ -f "$stage_pir_header_marker" ]] || fail "verification did not inspect the staging PIR cache header"
[[ -f "$stage_static_header_marker" ]] || fail "verification did not inspect the staging static cache header"
[[ -f "$manifest_header_marker" ]] || fail "verification did not inspect the manifest cache header"
grep -Fx 'test/prod-static-voting-config-duplicate.json' "$test_alias_header_marker" >/dev/null \
  || fail "verification did not inspect the production test alias cache header"
grep -Fx 'test/static-voting-config-duplicate.json' "$test_alias_header_marker" >/dev/null \
  || fail "verification did not inspect the staging test alias cache header"
grep -F 'Waiting for published bytes for prod/dynamic-voting-config.json' \
  <<< "$verify_output" >/dev/null \
  || fail "verification did not poll the stale response"
grep -F 'Waiting for header for prod/pir.json:' \
  <<< "$verify_output" >/dev/null \
  || fail "verification did not poll the stale production PIR cache header"
grep -F 'Waiting for header for stage/pir.json:' \
  <<< "$verify_output" >/dev/null \
  || fail "verification did not poll the stale staging PIR cache header"
grep -F 'Waiting for header for stage/static-voting-config.json:' \
  <<< "$verify_output" >/dev/null \
  || fail "verification did not poll the stale staging static cache header"
grep -F 'Waiting for header for deployment-manifest.json:' \
  <<< "$verify_output" >/dev/null \
  || fail "verification did not poll the stale manifest cache header"

outage_output="$(
  VERIFY_CONNECT_TIMEOUT_SECONDS=1 \
  VERIFY_MAX_TIME_SECONDS=2 \
  VERIFY_RETRY_COUNT=0 \
  VERIFY_RETRY_DELAY_SECONDS=0 \
  VERIFY_RETRY_MAX_TIME_SECONDS=2 \
  VERIFY_DEADLINE_SECONDS=10 \
  VERIFY_POLL_INTERVAL_SECONDS=0 \
  http_proxy=http://127.0.0.1:1 \
  https_proxy=http://127.0.0.1:1 \
  NO_PROXY=127.0.0.1,localhost \
    "${repo_root}/scripts/rehearse-github-outage.sh" \
      "http://127.0.0.1:${port}" "$expected_dir" local-test 2>&1
)"
grep -F 'GitHub remained isolated while the Cloudflare snapshot was verified.' \
  <<< "$outage_output" >/dev/null \
  || fail "outage rehearsal did not verify the isolated snapshot: ${outage_output}"
[[ -f "$fallback_header_marker" ]] \
  || fail "outage rehearsal did not force the gateway fallback"

curl_home="${test_root}/curl-home"
mkdir "$curl_home"
printf 'resolve = "raw.githubusercontent.com:%s:127.0.0.1"\n' "$port" > "${curl_home}/.curlrc"
touch "$github_redirect_marker"

redirect_verify_output="$(
  VERIFY_CONNECT_TIMEOUT_SECONDS=1 \
  VERIFY_MAX_TIME_SECONDS=2 \
  VERIFY_RETRY_COUNT=0 \
  VERIFY_RETRY_DELAY_SECONDS=0 \
  VERIFY_RETRY_MAX_TIME_SECONDS=2 \
  VERIFY_DEADLINE_SECONDS=10 \
  VERIFY_POLL_INTERVAL_SECONDS=0 \
  CURL_HOME="$curl_home" \
    "${repo_root}/scripts/verify-publication.sh" \
      "http://127.0.0.1:${port}" "$expected_dir" local-test 2>&1
)"
[[ -f "$redirect_final_header_marker" ]] \
  || fail "redirect test server did not return a stale final cache header"
grep -F 'Waiting for header for prod/dynamic-voting-config.json:' \
  <<< "$redirect_verify_output" >/dev/null \
  || fail "verification accepted an intermediate response cache header"

set +e
outage_output="$(
  VERIFY_CONNECT_TIMEOUT_SECONDS=1 \
  VERIFY_MAX_TIME_SECONDS=1 \
  VERIFY_RETRY_COUNT=0 \
  VERIFY_RETRY_DELAY_SECONDS=0 \
  VERIFY_RETRY_MAX_TIME_SECONDS=1 \
  VERIFY_DEADLINE_SECONDS=2 \
  VERIFY_POLL_INTERVAL_SECONDS=0 \
  CURL_HOME="$curl_home" \
    "${repo_root}/scripts/rehearse-github-outage.sh" \
      "http://127.0.0.1:${port}" "$expected_dir" local-test 2>&1
)"
outage_status=$?
set -e

[[ "$outage_status" -ne 0 ]] \
  || fail "outage rehearsal followed a redirect through GitHub"
grep -F 'verification deadline expired while waiting for published bytes for prod/dynamic-voting-config.json' \
  <<< "$outage_output" >/dev/null \
  || fail "GitHub-dependent endpoint failed for an unexpected reason: ${outage_output}"

unlink "$github_redirect_marker"
touch "$normal_fallback_marker"
set +e
primary_output="$(
  VERIFY_GATEWAY_PRIMARY=true \
  VERIFY_CONNECT_TIMEOUT_SECONDS=1 \
  VERIFY_MAX_TIME_SECONDS=1 \
  VERIFY_RETRY_COUNT=0 \
  VERIFY_RETRY_DELAY_SECONDS=0 \
  VERIFY_RETRY_MAX_TIME_SECONDS=1 \
  VERIFY_DEADLINE_SECONDS=5 \
  VERIFY_POLL_INTERVAL_SECONDS=0 \
    "${repo_root}/scripts/verify-publication.sh" \
      "http://127.0.0.1:${port}" "$expected_dir" local-test 2>&1
)"
primary_status=$?
set -e

[[ "$primary_status" -ne 0 ]] \
  || fail "primary verification accepted the Cloudflare fallback origin"
grep -F 'verification deadline expired while waiting for github response bytes for prod/pir.json' \
  <<< "$primary_output" >/dev/null \
  || fail "primary verification failed for an unexpected reason: ${primary_output}"

unlink "$normal_fallback_marker"
touch "$corrupt_primary_marker"
set +e
primary_output="$(
  VERIFY_GATEWAY_PRIMARY=true \
  VERIFY_CONNECT_TIMEOUT_SECONDS=1 \
  VERIFY_MAX_TIME_SECONDS=1 \
  VERIFY_RETRY_COUNT=0 \
  VERIFY_RETRY_DELAY_SECONDS=0 \
  VERIFY_RETRY_MAX_TIME_SECONDS=1 \
  VERIFY_DEADLINE_SECONDS=5 \
  VERIFY_POLL_INTERVAL_SECONDS=0 \
    "${repo_root}/scripts/verify-publication.sh" \
      "http://127.0.0.1:${port}" "$expected_dir" local-test 2>&1
)"
primary_status=$?
set -e

[[ "$primary_status" -ne 0 ]] \
  || fail "primary verification accepted bytes from a different response"
grep -F 'verification deadline expired while waiting for github response bytes for prod/pir.json' \
  <<< "$primary_output" >/dev/null \
  || fail "primary byte verification failed for an unexpected reason: ${primary_output}"

# shellcheck disable=SC2016
grep -Fqx \
  '        run: scripts/verify-publication.sh https://voting.valargroup.dev _site "${GITHUB_SHA}"' \
  "${repo_root}/.github/workflows/deploy-cloudflare-pages.yml" \
  || fail "Cloudflare workflow must always verify the canonical custom domain"
# shellcheck disable=SC2016
grep -Fqx \
  '        run: scripts/rehearse-github-outage.sh https://voting.valargroup.dev _site "${GITHUB_SHA}"' \
  "${repo_root}/.github/workflows/deploy-cloudflare-pages.yml" \
  || fail "Cloudflare workflow must always rehearse the canonical fallback"
grep -Fqx \
  "    if: github.ref == 'refs/heads/main'" \
  "${repo_root}/.github/workflows/monitor-cloudflare-publication.yml" \
  || fail "manual publication monitoring must be restricted to main"
grep -Fqx \
  '  retire_stale_freshness:' \
  "${repo_root}/.github/workflows/monitor-cloudflare-publication.yml" \
  || fail "push monitoring must retire stale freshness work"
grep -Fqx \
  '      group: cloudflare-pages-monitor-freshness' \
  "${repo_root}/.github/workflows/monitor-cloudflare-publication.yml" \
  || fail "stale freshness work must use its own concurrency group"
grep -Fqx \
  "      group: cloudflare-pages-monitor-\${{ github.event_name == 'push' && 'push' || 'freshness' }}" \
  "${repo_root}/.github/workflows/monitor-cloudflare-publication.yml" \
  || fail "push deadline monitors must be isolated from freshness monitors"
[[ "$(grep -Fxc '      cancel-in-progress: true' \
  "${repo_root}/.github/workflows/monitor-cloudflare-publication.yml")" -eq 1 ]] \
  || fail "only the stale freshness retirement job may cancel freshness work"
grep -Fqx \
  "      cancel-in-progress: \${{ github.event_name == 'push' }}" \
  "${repo_root}/.github/workflows/monitor-cloudflare-publication.yml" \
  || fail "scheduled freshness checks must be allowed to reach their deadline"
grep -Fqx \
  "          ref: \${{ github.event_name == 'push' && github.sha || 'main' }}" \
  "${repo_root}/.github/workflows/monitor-cloudflare-publication.yml" \
  || fail "non-push monitors must check out the latest main revision"
if grep -Fq 'GITHUB_SHA' \
  "${repo_root}/.github/workflows/monitor-cloudflare-publication.yml"; then
  fail "monitor verification must use the selected checkout revision"
fi
grep -Fq 'steps.monitor_start.outputs.epoch' \
  "${repo_root}/.github/workflows/monitor-cloudflare-publication.yml" \
  || fail "push publication deadlines must use the monitor start time"
if grep -Fq -- '--format=%ct' \
  "${repo_root}/.github/workflows/monitor-cloudflare-publication.yml"; then
  fail "push publication deadlines must not use the Git commit timestamp"
fi

printf 'Publication propagation test passed\n'
