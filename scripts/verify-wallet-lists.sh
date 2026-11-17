#!/usr/bin/env bash
set -euo pipefail

# Verifies one environment's wallet lists (proxy delegation contracts-v1
# §12.3). Each <env>/wallets/<wallet_id>/ holds signers.json, the keys the
# wallet pins for its list in this environment, and optionally list.json, the
# signed list. Each list must verify as that wallet verifies it: its
# wallet_id is the folder name, its chain_id the environment's chain, and a
# signature by a key in signers.json covers it. CI also checks the picture
# size and, given BASE_REVISION, that a changed list raised its version. The
# folder layout itself is checked by build-cloudflare-pages.sh, which CI runs
# in the same job.

fail() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

if [[ $# -lt 1 || $# -gt 2 ]]; then
  fail "usage: $0 ENVIRONMENT [BASE_REVISION]"
fi

environment_name="$1"
base_revision="${2:-}"
case "$environment_name" in
  prod) chain_id=zvote-1 ;;
  stage) chain_id=svote-1 ;;
  *) fail "ENVIRONMENT must be prod or stage" ;;
esac

command -v jq >/dev/null || fail "jq is required"

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${script_dir}/.."

if [[ -n "$base_revision" ]]; then
  git rev-parse --verify --quiet "${base_revision}^{commit}" >/dev/null \
    || fail "BASE_REVISION is not a commit in local history: ${base_revision}"
fi

wallets_dir="${environment_name}/wallets"
[[ -d "$wallets_dir" ]] || exit 0

work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT

checked=0
while IFS= read -r wallet_dir; do
  wallet_id="$(basename "$wallet_dir")"
  signers="${wallet_dir}/signers.json"
  [[ -f "$signers" ]] || fail "${wallet_dir} has no signers.json naming the keys its list may be signed by"
  jq -e '
    type == "array" and length > 0 and
    all(type == "object" and (.key_id | type == "string" and length > 0) and .alg == "ed25519" and
        (.pubkey | type == "string" and test("^[A-Za-z0-9+/]{43}=$"))) and
    ([.[].key_id] | unique | length) == length
  ' "$signers" >/dev/null \
    || fail "${signers} must be a non-empty array of distinct ed25519 keys, each {key_id, alg, pubkey}"

  list="${wallet_dir}/list.json"
  [[ -f "$list" ]] || continue
  voting-config wallet-list --help >/dev/null 2>&1 \
    || fail "${list} needs a voting-config with the wallet-list command; pin a vote-sdk release that has it (VOTE_SDK_TAG in .github/workflows/verify-config.yml)"

  verify_args=(wallet-list verify --list "$list" --wallet-id "$wallet_id" --chain-id "$chain_id")
  while IFS= read -r allowed_key; do
    verify_args+=(--allowed-key "$allowed_key")
  done < <(jq -r '.[] | "\(.key_id)=\(.pubkey)"' "$signers")
  if [[ -n "$base_revision" ]] && git cat-file -e "${base_revision}:${list}" 2>/dev/null; then
    previous="${work_dir}/${wallet_id}-previous.json"
    git show "${base_revision}:${list}" > "$previous"
    verify_args+=(--previous "$previous")
  fi
  voting-config "${verify_args[@]}"
  checked=$((checked + 1))
done < <(find "$wallets_dir" -mindepth 1 -maxdepth 1 -print | sort)

printf 'Verified %d %s wallet list(s)\n' "$checked" "$environment_name"
