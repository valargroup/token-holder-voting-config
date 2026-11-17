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
test_root="$(make_test_temp_dir wallet-list-publication-test)"
trap 'rm -rf "$test_root"' EXIT
test_repo="${test_root}/repo"

fake_bin="${test_root}/bin"
calls="${test_root}/calls"

mkdir -p "$test_repo" "$fake_bin"
rsync -a --exclude .git "$repo_root/" "$test_repo/"

# Stands in for a voting-config with the wallet-list command. Each wallet
# list verification appends its arguments to FAKE_CALLS, copies its
# --previous file to FAKE_CALLS.<env>.previous, and exits FAKE_EXIT. Config
# verification passes.
cat > "${fake_bin}/voting-config" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
[[ "$1" == wallet-list ]] || exit 0
[[ "$2" == verify ]] || exit 0
printf '%s\n' "$*" >> "$FAKE_CALLS"
previous=""
for arg in "$@"; do
  if [[ "$previous" == --list ]]; then environment_name="${arg%%/*}"; fi
  if [[ "$previous" == --previous ]]; then cp "$arg" "${FAKE_CALLS}.${environment_name}.previous"; fi
  previous="$arg"
done
exit "${FAKE_EXIT:-0}"
FAKE
chmod +x "${fake_bin}/voting-config"

build() {
  local builder="$1"
  local output_dir="$2"
  : > "$calls"
  (
    cd "$test_repo"
    SOURCE_REVISION="${SOURCE_REVISION:-local-test}" \
    PUBLISHED_AT=2026-08-17T00:00:00Z \
    PATH="${fake_bin}:${PATH}" \
    FAKE_CALLS="$calls" \
      "scripts/${builder}" "$output_dir" 2>&1
  )
}

expect_rejected() {
  local case_name="$1"
  local expected_message="$2"
  local build_output
  local build_status

  set +e
  build_output="$(build build-cloudflare-pages.sh "${test_root}/site-${case_name}")"
  build_status=$?
  set -e

  [[ "$build_status" -ne 0 ]] || fail "builder accepted ${case_name}"
  grep -F "$expected_message" <<< "$build_output" >/dev/null \
    || fail "${case_name} failed for an unexpected reason: ${build_output}"
}

printf '{"format":"zcash-vote-wallet-list/v1"}\n' > "${test_repo}/prod/wallets/vizor/list.json"
printf '{"format":"zcash-vote-wallet-list/v1"}\n' > "${test_repo}/stage/wallets/vizor/list.json"
# Only prod/ and stage/ lists are published.
mkdir -p "${test_repo}/test/wallets/vizor"
cp "${test_repo}/prod/wallets/vizor/list.json" "${test_repo}/test/wallets/vizor/list.json"

build build-cloudflare-pages.sh "${test_root}/cloudflare-site" >/dev/null
build build-github-pages.sh "${test_root}/github-site" >/dev/null
for site in cloudflare-site github-site; do
  for list in prod/wallets/vizor/list.json stage/wallets/vizor/list.json; do
    cmp -s "${test_repo}/${list}" "${test_root}/${site}/${list}" \
      || fail "${site} did not publish ${list}"
  done
  [[ ! -e "${test_root}/${site}/prod/wallets/vizor/signers.json" ]] \
    || fail "${site} published a signer file"
  [[ ! -e "${test_root}/${site}/test/wallets" ]] \
    || fail "${site} published wallet lists outside prod/ and stage/"
done
rm -r "${test_repo}/test/wallets"

printf '{}\n' > "${test_repo}/prod/wallets/vizor/notes.json"
expect_rejected extra-file "unexpected wallet list path: prod/wallets/vizor/notes.json"
rm "${test_repo}/prod/wallets/vizor/notes.json"

mkdir "${test_repo}/prod/wallets/vizor_x"
expect_rejected bad-wallet-id "unexpected wallet list path: prod/wallets/vizor_x"
rmdir "${test_repo}/prod/wallets/vizor_x"

mkdir "${test_repo}/prod/wallets/vizor/nested"
expect_rejected nested-directory "unexpected wallet list path: prod/wallets/vizor/nested"
rmdir "${test_repo}/prod/wallets/vizor/nested"

printf '{}\n' > "${test_repo}/prod/wallets/stray.json"
expect_rejected stray-file "unexpected wallet list path: prod/wallets/stray.json"
rm "${test_repo}/prod/wallets/stray.json"

printf 'not json\n' > "${test_repo}/stage/wallets/vizor/list.json"
expect_rejected invalid-json "invalid JSON: stage/wallets/vizor/list.json"
printf '{}\n' > "${test_repo}/stage/wallets/vizor/list.json"

mv "${test_repo}/stage/wallets/vizor/list.json" "${test_root}/stage-list.json"
ln -s "${test_root}/stage-list.json" "${test_repo}/stage/wallets/vizor/list.json"
expect_rejected symbolic-link-list "wallet files must be regular files: stage/wallets/vizor/list.json"
unlink "${test_repo}/stage/wallets/vizor/list.json"
mv "${test_root}/stage-list.json" "${test_repo}/stage/wallets/vizor/list.json"

mv "${test_repo}/stage/wallets" "${test_root}/stage-wallets"
ln -s "${test_root}/stage-wallets" "${test_repo}/stage/wallets"
expect_rejected symbolic-link-directory "wallet lists must be in a regular directory: stage/wallets"
unlink "${test_repo}/stage/wallets"
mv "${test_root}/stage-wallets" "${test_repo}/stage/wallets"

build build-cloudflare-pages.sh "${test_root}/restored-site" >/dev/null

# Each published list goes through the wallet list verification CI runs, and
# one that fails it stops the build.
[[ "$(grep -c '^wallet-list verify --list ' "$calls")" -eq 2 ]] \
  || fail "the build did not verify both lists: $(cat "$calls")"
grep -F -- "--list stage/wallets/vizor/list.json --wallet-id vizor --chain-id svote-1" "$calls" >/dev/null \
  || fail "the stage list was not verified for its chain: $(cat "$calls")"
set +e
FAKE_EXIT=1 build build-cloudflare-pages.sh "${test_root}/unverified-site" >/dev/null
status=$?
set -e
[[ "$status" -ne 0 ]] || fail "builder published a list that fails verification"
[[ ! -e "${test_root}/unverified-site/prod" ]] || fail "builder wrote a site with an unverified list"

# A real revision's lists are checked against its first parent's, which
# must have a lower version.
(
  cd "$test_repo"
  git init --quiet
  git config user.name test
  git config user.email test@example.invalid
  printf '{"version":1}\n' > prod/wallets/vizor/list.json
  git add .
  git commit --quiet -m 'list v1'
  printf '{"version":2}\n' > prod/wallets/vizor/list.json
  git commit --quiet -am 'list v2'
)
SOURCE_REVISION="$(git -C "$test_repo" rev-parse HEAD)" \
  build build-cloudflare-pages.sh "${test_root}/revision-site" >/dev/null
grep -E -- "^wallet-list verify --list prod/wallets/vizor/list.json .* --previous [^ ]+$" "$calls" >/dev/null \
  || fail "the prod list was not checked against the previous revision: $(cat "$calls")"
[[ "$(cat "${calls}.prod.previous")" == '{"version":1}' ]] \
  || fail "the previous list is not the first parent's"

printf 'Wallet list publication test passed\n'
