#!/usr/bin/env bash
set -euo pipefail
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"
source "$script_dir/lib/test-helpers.sh"
test_root="$(make_test_temp_dir pir-update-publication)"
trap 'rm -rf "$test_root"' EXIT
mkdir -p "$test_root/repo"
rsync -a --exclude .git "$repo_root/" "$test_root/repo/"
# Use the public fixture key only in this disposable repository.
node --input-type=module - "$test_root/repo" <<'JS'
import {readFileSync,writeFileSync} from 'node:fs';
const root=process.argv[2];const v=JSON.parse(readFileSync(`${root}/scripts/tests/pir-update-vector.json`));
writeFileSync(`${root}/prod/pir.json`,v.config);
writeFileSync(`${root}/prod/pir_attestations.json`,JSON.stringify(v.attestations));
const keys=JSON.parse(readFileSync(`${root}/scripts/pir-update-keys.json`));keys.prod=[v.key];
writeFileSync(`${root}/scripts/pir-update-keys.json`,JSON.stringify(keys));
JS
(cd "$test_root/repo" && PATH="$script_dir/fixtures:$PATH" SOURCE_REVISION=local-test scripts/build-cloudflare-pages.sh "$test_root/site") >/dev/null
cmp "$test_root/repo/prod/pir_attestations.json" "$test_root/site/prod/pir_attestations.json"
printf '\n' >> "$test_root/repo/prod/pir.json"
if (cd "$test_root/repo" && node scripts/verify-pir-update.mjs) >/dev/null 2>&1; then
  echo 'tampered signed config passed publication verification' >&2; exit 1
fi
printf 'Signed PIR publication test passed\n'
