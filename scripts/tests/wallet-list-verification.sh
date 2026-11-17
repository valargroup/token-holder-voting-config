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
test_root="$(make_test_temp_dir wallet-list-verification-test)"
trap 'rm -rf "$test_root"' EXIT
test_repo="${test_root}/repo"
fake_bin="${test_root}/bin"
calls="${test_root}/calls"

mkdir -p "$test_repo" "$fake_bin"
rsync -a --exclude .git "$repo_root/" "$test_repo/"

# Stands in for voting-config. FAKE_WALLET_LIST=true makes it a release with
# the wallet-list command. Each verify call appends its arguments to
# FAKE_CALLS and copies its --previous file to FAKE_CALLS.previous.
cat > "${fake_bin}/voting-config" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$*" == "wallet-list --help" ]]; then
  [[ "${FAKE_WALLET_LIST:-false}" == true ]] || { echo 'unknown command "wallet-list"' >&2; exit 1; }
  exit 0
fi
printf '%s\n' "$*" >> "$FAKE_CALLS"
previous=""
for arg in "$@"; do
  if [[ "$previous" == --previous ]]; then cp "$arg" "${FAKE_CALLS}.previous"; fi
  previous="$arg"
done
exit "${FAKE_EXIT:-0}"
FAKE
chmod +x "${fake_bin}/voting-config"

cd "$test_repo"
git init --quiet
git config user.name test
git config user.email test@example.invalid
git add .
git commit --quiet -m baseline
baseline="$(git rev-parse HEAD)"

run_verify() {
  : > "$calls"
  rm -f "${calls}.previous"
  PATH="${fake_bin}:${PATH}" FAKE_CALLS="$calls" scripts/verify-wallet-lists.sh "$@" 2>&1
}

expect_rejected() {
  local case_name="$1"
  local expected_message="$2"
  shift 2
  local output
  local status

  set +e
  output="$(FAKE_WALLET_LIST=true run_verify "$@")"
  status=$?
  set -e

  [[ "$status" -ne 0 ]] || fail "${case_name} passed"
  grep -F "$expected_message" <<< "$output" >/dev/null \
    || fail "${case_name} failed for an unexpected reason: ${output}"
}

prod_call="wallet-list verify --list prod/wallets/vizor/list.json --wallet-id vizor --chain-id zvote-1 --allowed-key valargroup=8oQiUWq6QDGnAgRw6U3YhnXb6JLFSXauYnWHIFmJRcw="
stage_call="wallet-list verify --list stage/wallets/vizor/list.json --wallet-id vizor --chain-id svote-1 --allowed-key valar-test-keplr-derived=NDygCpG+Y4T4uu8M1Sb/YG+74lUVj9XgYypUoMQMXT8="

# Signer files without lists need no verifier.
run_verify prod "$baseline" >/dev/null
[[ ! -s "$calls" ]] || fail "a folder without a list ran the verifier"

printf '{"version":1}\n' > prod/wallets/vizor/list.json
printf '{"version":1}\n' > stage/wallets/vizor/list.json
set +e
output="$(run_verify prod)"
status=$?
set -e
[[ "$status" -ne 0 ]] && grep -F "needs a voting-config with the wallet-list command" <<< "$output" >/dev/null \
  || fail "an old verifier passed a list: ${output}"

FAKE_WALLET_LIST=true run_verify prod "$baseline" >/dev/null
[[ "$(cat "$calls")" == "$prod_call" ]] || fail "new list ran: $(cat "$calls")"
FAKE_WALLET_LIST=true run_verify stage >/dev/null
[[ "$(cat "$calls")" == "$stage_call" ]] || fail "stage list ran: $(cat "$calls")"

# A list on the base revision is the one the change must raise the version of.
git add prod/wallets/vizor/list.json
git commit --quiet -m 'add list'
with_list="$(git rev-parse HEAD)"
printf '{"version":2}\n' > prod/wallets/vizor/list.json
FAKE_WALLET_LIST=true run_verify prod "$with_list" >/dev/null
[[ "$(cat "$calls")" =~ ^"${prod_call}"\ --previous\ [^\ ]+$ ]] || fail "changed list ran: $(cat "$calls")"
[[ "$(cat "${calls}.previous")" == '{"version":1}' ]] || fail "the previous list is not the base revision's"

# A list on the base revision may not be removed, alone or with its folder.
mv prod/wallets/vizor/list.json "${test_root}/list.json"
expect_rejected removed-list "prod/wallets/vizor/list.json exists at ${with_list} and may not be removed" prod "$with_list"
mv prod/wallets/vizor "${test_root}/vizor"
expect_rejected removed-wallet "prod/wallets/vizor/list.json exists at ${with_list} and may not be removed" prod "$with_list"
mv "${test_root}/vizor" prod/wallets/vizor
mv "${test_root}/list.json" prod/wallets/vizor/list.json
# Without a base revision there is nothing to compare.
mv prod/wallets/vizor/list.json "${test_root}/list.json"
FAKE_WALLET_LIST=true run_verify prod >/dev/null
mv "${test_root}/list.json" prod/wallets/vizor/list.json

set +e
FAKE_WALLET_LIST=true FAKE_EXIT=1 run_verify prod >/dev/null
status=$?
set -e
[[ "$status" -ne 0 ]] || fail "a verifier failure passed"

mv prod/wallets/vizor/signers.json "${test_root}/signers.json"
expect_rejected no-signers "has no signers.json" prod
printf '[]\n' > prod/wallets/vizor/signers.json
expect_rejected empty-signers "must be a non-empty array" prod
jq '. + .' "${test_root}/signers.json" > prod/wallets/vizor/signers.json
expect_rejected repeated-signer "must be a non-empty array" prod
mv "${test_root}/signers.json" prod/wallets/vizor/signers.json

expect_rejected unknown-base "BASE_REVISION is not a commit in local history: main~99" prod main~99
expect_rejected unknown-environment "ENVIRONMENT must be prod or stage" test

printf 'Wallet list verification test passed\n'
