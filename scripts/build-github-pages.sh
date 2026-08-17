#!/usr/bin/env bash
set -euo pipefail

fail() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

if [[ $# -ne 1 ]]; then
  fail "usage: $0 OUTPUT_DIRECTORY"
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/.." && pwd)"

if [[ "${PUBLICATION_MODE:-automatic}" != "local-test" ]]; then
  "${script_dir}/verify-github-pages-legacy.sh"
fi

"${script_dir}/build-cloudflare-pages.sh" "$1"
output_dir="$(cd "$1" && pwd)"

if command -v sha256sum >/dev/null; then
  sha256_file() { sha256sum "$1" | awk '{print $1}'; }
elif command -v shasum >/dev/null; then
  sha256_file() { shasum -a 256 "$1" | awk '{print $1}'; }
else
  fail "sha256sum or shasum is required"
fi

legacy_files=(
  "prod/static-voting-config.json c06f1dfa2f0a30b3614aefcf00ac7e31d61ebc3cf551b3031d1b194232d1056d"
  "stage/static-voting-config.json 80890a6de9acc7293c3e2fabf870bb3e5755dbe0e69de4a59feb8f696134d4dc"
  "test/prod-static-voting-config-duplicate.json 5a6bc0dce85a8ee8d6585d2a180e62f145abcfee7768c15b88de47c9a01a5738"
  "test/static-voting-config-duplicate.json 80890a6de9acc7293c3e2fabf870bb3e5755dbe0e69de4a59feb8f696134d4dc"
)

for legacy_entry in "${legacy_files[@]}"; do
  read -r relative_path expected_hash <<< "$legacy_entry"
  legacy_source="${repo_root}/legacy/github-pages/${relative_path}"
  [[ -f "$legacy_source" && ! -L "$legacy_source" ]] \
    || fail "missing or unsafe legacy file: ${legacy_source}"
  [[ "$(sha256_file "$legacy_source")" == "$expected_hash" ]] \
    || fail "legacy file bytes changed: ${relative_path}"

  cp "$legacy_source" "${output_dir}/${relative_path}"
  printf '%s  %s\n' "$expected_hash" "$(basename "$relative_path")" \
    > "${output_dir}/${relative_path}.sha256"
done

cp "${repo_root}/CNAME" "${output_dir}/CNAME"
unlink "${output_dir}/deployment-manifest.json"

printf 'Built GitHub Pages compatibility snapshot in %s\n' "$output_dir"
