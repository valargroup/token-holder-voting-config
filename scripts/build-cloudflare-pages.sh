#!/usr/bin/env bash
set -euo pipefail

fail() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

if [[ $# -ne 1 ]]; then
  fail "usage: $0 OUTPUT_DIRECTORY"
fi

command -v jq >/dev/null || fail "jq is required"

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/.." && pwd)"
output_arg="$1"

case "$output_arg" in
  ""|"."|"/"|"${HOME}") fail "refusing unsafe output directory: ${output_arg:-<empty>}" ;;
esac

output_parent="$(dirname "$output_arg")"
output_name="$(basename "$output_arg")"
mkdir -p "$output_parent"
output_dir="$(cd "$output_parent" && pwd)/$output_name"

if [[ "$output_dir" == "$repo_root" || "$output_dir" == "$HOME" ]]; then
  fail "refusing to write into ${output_dir}"
fi

mkdir -p "$output_dir"
if [[ -n "$(find "$output_dir" -mindepth 1 -maxdepth 1 -print -quit)" ]]; then
  fail "output directory must be empty: ${output_dir}"
fi

if command -v sha256sum >/dev/null; then
  sha256_file() { sha256sum "$1" | awk '{print $1}'; }
elif command -v shasum >/dev/null; then
  sha256_file() { shasum -a 256 "$1" | awk '{print $1}'; }
else
  fail "sha256sum or shasum is required"
fi

cd "$repo_root"

public_files=(
  prod/dynamic-voting-config.json
  prod/pir.json
  prod/static-voting-config.json
  stage/dynamic-voting-config.json
  stage/pir.json
  stage/static-voting-config.json
  test/prod-static-voting-config-duplicate.json
  test/static-voting-config-duplicate.json
)

for file in "${public_files[@]}"; do
  [[ -f "$file" && ! -L "$file" ]] || fail "missing or unsafe public file: ${file}"
  jq -e . "$file" >/dev/null || fail "invalid JSON: ${file}"
done

if [[ -n "$(find pins -type l -print -quit)" ]]; then
  fail "immutable pins must not contain symbolic links"
fi

prod_dynamic_url="https://voting.valargroup.dev/prod/dynamic-voting-config.json"
stage_dynamic_url="https://voting.valargroup.dev/stage/dynamic-voting-config.json"

for file in prod/static-voting-config.json test/prod-static-voting-config-duplicate.json; do
  jq -e --arg expected "$prod_dynamic_url" '.dynamic_config_url == $expected' "$file" >/dev/null \
    || fail "${file} must use the controlled production dynamic config URL"
done

for file in stage/static-voting-config.json test/static-voting-config-duplicate.json; do
  jq -e --arg expected "$stage_dynamic_url" '.dynamic_config_url == $expected' "$file" >/dev/null \
    || fail "${file} must use the controlled staging dynamic config URL"
done

prod_static_sha256="$(sha256_file prod/static-voting-config.json)"
stage_static_sha256="$(sha256_file stage/static-voting-config.json)"
prod_pin="pins/prod/${prod_static_sha256}/static-voting-config.json"
stage_pin="pins/stage/${stage_static_sha256}/static-voting-config.json"

pin_count=0
while IFS= read -r pin; do
  if ! [[ "$pin" =~ ^pins/(prod|stage)/([0-9a-f]{64})/static-voting-config\.json$ ]]; then
    fail "unexpected immutable pin path: ${pin}"
  fi
  pin_environment="${BASH_REMATCH[1]}"
  expected_pin_sha256="${BASH_REMATCH[2]}"
  [[ "$(sha256_file "$pin")" == "$expected_pin_sha256" ]] \
    || fail "immutable pin bytes do not match its path: ${pin}"
  [[ ! -L "$pin" ]] || fail "immutable pin must be a regular file: ${pin}"
  jq -e . "$pin" >/dev/null || fail "invalid JSON: ${pin}"
  expected_pin_url="https://voting.valargroup.dev/${pin_environment}/dynamic-voting-config.json"
  jq -e --arg expected "$expected_pin_url" '.dynamic_config_url == $expected' "$pin" >/dev/null \
    || fail "${pin} points outside its controlled environment URL"
  pin_count=$((pin_count + 1))
done < <(find pins -type f -print | sort)

[[ "$pin_count" -gt 0 ]] || fail "at least one immutable static-config pin is required"

[[ -f "$prod_pin" ]] || fail "add the production static config to ${prod_pin}"
[[ -f "$stage_pin" ]] || fail "add the staging static config to ${stage_pin}"
cmp -s prod/static-voting-config.json "$prod_pin" \
  || fail "${prod_pin} must be byte-for-byte identical to prod/static-voting-config.json"
cmp -s stage/static-voting-config.json "$stage_pin" \
  || fail "${stage_pin} must be byte-for-byte identical to stage/static-voting-config.json"

for file in "${public_files[@]}"; do
  install -d "$output_dir/$(dirname "$file")"
  cp "$file" "$output_dir/$file"
done

install -d "$output_dir/pins"
cp -R pins/. "$output_dir/pins/"
cp _headers "$output_dir/_headers"

write_sidecar() {
  local relative_path="$1"
  local hash
  hash="$(sha256_file "$output_dir/$relative_path")"
  printf '%s  %s\n' "$hash" "$(basename "$relative_path")" > "$output_dir/${relative_path}.sha256"
}

write_sidecar prod/static-voting-config.json
write_sidecar stage/static-voting-config.json
write_sidecar test/prod-static-voting-config-duplicate.json
write_sidecar test/static-voting-config-duplicate.json

while IFS= read -r published_pin; do
  write_sidecar "${published_pin#"$output_dir/"}"
done < <(find "$output_dir/pins" -type f -name 'static-voting-config.json' -print | sort)

publication_mode="${PUBLICATION_MODE:-automatic}"
case "$publication_mode" in
  automatic|manual-bootstrap|manual-emergency|local-test) ;;
  *) fail "PUBLICATION_MODE must be automatic, manual-bootstrap, manual-emergency, or local-test" ;;
esac

source_revision="${SOURCE_REVISION:-}"
if [[ -z "$source_revision" ]]; then
  if [[ -n "$(git status --porcelain --untracked-files=normal)" ]]; then
    fail "commit the publication snapshot or set SOURCE_REVISION for a local test"
  fi
  source_revision="$(git rev-parse HEAD)"
fi

if ! [[ "$source_revision" =~ ^[0-9a-f]{40}$|^local-test$ ]]; then
  fail "SOURCE_REVISION must be a full Git commit or local-test"
fi

if [[ "$publication_mode" != "local-test" ]]; then
  [[ "$source_revision" != "local-test" ]] \
    || fail "non-test publications require a full Git commit"
  [[ -z "$(git status --porcelain --untracked-files=normal)" ]] \
    || fail "non-test publications require a clean working tree"
fi

published_at="${PUBLISHED_AT:-$(date -u +'%Y-%m-%dT%H:%M:%SZ')}"

jq -n \
  --arg source_revision "$source_revision" \
  --arg published_at "$published_at" \
  --arg publication_mode "$publication_mode" \
  --arg prod_dynamic_sha256 "$(sha256_file prod/dynamic-voting-config.json)" \
  --arg prod_pir_sha256 "$(sha256_file prod/pir.json)" \
  --arg prod_static_sha256 "$prod_static_sha256" \
  --arg stage_dynamic_sha256 "$(sha256_file stage/dynamic-voting-config.json)" \
  --arg stage_pir_sha256 "$(sha256_file stage/pir.json)" \
  --arg stage_static_sha256 "$stage_static_sha256" \
  '{
    schema_version: 1,
    serving_model: "cloudflare-pages-direct-upload",
    source_repository: "valargroup/token-holder-voting-config",
    source_revision: $source_revision,
    published_at: $published_at,
    publication_mode: $publication_mode,
    configs: {
      prod: {
        dynamic_sha256: $prod_dynamic_sha256,
        pir_sha256: $prod_pir_sha256,
        static_sha256: $prod_static_sha256
      },
      stage: {
        dynamic_sha256: $stage_dynamic_sha256,
        pir_sha256: $stage_pir_sha256,
        static_sha256: $stage_static_sha256
      }
    }
  }' > "$output_dir/deployment-manifest.json"

printf 'Built Cloudflare Pages snapshot in %s\n' "$output_dir"
printf 'Production static pin: https://voting.valargroup.dev/%s?checksum=sha256:%s\n' "$prod_pin" "$prod_static_sha256"
printf 'Staging static pin: https://voting.valargroup.dev/%s?checksum=sha256:%s\n' "$stage_pin" "$stage_static_sha256"
