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

[[ ! -L "$output_dir" ]] || fail "refusing symbolic link output directory: ${output_dir}"

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

source_revision="${SOURCE_REVISION:-}"
[[ -n "$source_revision" ]] || fail "SOURCE_REVISION is required"

if [[ "$source_revision" != "local-test" ]]; then
  [[ "$source_revision" =~ ^[0-9a-f]{40}$ ]] \
    || fail "SOURCE_REVISION must be a full Git commit or local-test"
  git rev-parse --verify "${source_revision}^{commit}" >/dev/null 2>&1 \
    || fail "SOURCE_REVISION is not available in local history"
  head_revision="$(git rev-parse HEAD)"
  [[ "$source_revision" == "$head_revision" ]] \
    || fail "SOURCE_REVISION must match HEAD (${head_revision})"
  [[ -z "$(git status --porcelain --untracked-files=normal)" ]] \
    || fail "publications require a clean working tree"
fi

public_files=(
  prod/dynamic-voting-config.json
  prod/pir.json
  prod/static-voting-config.json
  prod/v2-static-voting-config.json
  stage/dynamic-voting-config.json
  stage/pir.json
  stage/static-voting-config.json
  stage/v2-static-voting-config.json
  test/prod-static-voting-config-duplicate.json
  test/static-voting-config-duplicate.json
)

for file in "${public_files[@]}"; do
  [[ -f "$file" && ! -L "$file" ]] || fail "missing or unsafe public file: ${file}"
  jq -e . "$file" >/dev/null || fail "invalid JSON: ${file}"
done

for pir_file in prod/pir.json stage/pir.json; do
  jq --slurp --exit-status '
    length == 1 and
    (.[0] |
      type == "object" and
      .schema_version == 1 and
      (.snapshot_height | type == "number" and . > 0 and floor == . and . % 10 == 0)
    )
  ' "$pir_file" >/dev/null \
    || fail "invalid PIR config: ${pir_file} must be one schema v1 object with a positive 10-block snapshot_height"
done

[[ -f _headers && ! -L _headers ]] || fail "missing or unsafe headers file: _headers"
[[ -f scripts/cloudflare-gateway.mjs && ! -L scripts/cloudflare-gateway.mjs ]] \
  || fail "missing or unsafe Cloudflare gateway: scripts/cloudflare-gateway.mjs"

if [[ -n "$(find pins -type l -print -quit)" ]]; then
  fail "immutable pins must not contain symbolic links"
fi

if git rev-parse --verify HEAD >/dev/null 2>&1; then
  while IFS= read -r historical_pin; do
    [[ -n "$historical_pin" ]] || continue
    [[ -f "$historical_pin" ]] \
      || fail "immutable pin from repository history is missing: ${historical_pin}"
  done < <(git log --format= --name-only HEAD -- pins | sort -u)
elif [[ "$source_revision" != "local-test" ]]; then
  fail "publication source is not a Git repository"
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

# A v2 static config replaces the single dynamic_config_url with an ordered
# dynamic_config_urls mirror list so a wallet survives a DNS failure at any one
# origin. Every entry must still come from an explicit allowlist: the list is
# covered by the wallet's hash pin, and round entries stay signature-verified
# against trusted_keys whichever mirror answers, but an unreviewed origin could
# still serve stale rounds.
prod_raw_dynamic_url="https://raw.githubusercontent.com/valargroup/token-holder-voting-config/main/prod/dynamic-voting-config.json"
stage_raw_dynamic_url="https://raw.githubusercontent.com/valargroup/token-holder-voting-config/main/stage/dynamic-voting-config.json"

check_v2_static_config() {
  local file="$1"
  local canonical_url="$2"
  local raw_url="$3"

  jq --slurp --exit-status \
    --arg canonical "$canonical_url" \
    --arg raw "$raw_url" '
    length == 1 and
    (.[0] |
      type == "object" and
      .static_config_version == 2 and
      (has("dynamic_config_url") | not) and
      (.dynamic_config_urls |
        type == "array" and
        length >= 2 and
        (unique | length) == length and
        all(type == "string") and
        all(. == $canonical or . == $raw)
      ) and
      .dynamic_config_urls[0] == $canonical and
      (.trusted_keys | type == "array" and length > 0)
    )
  ' "$file" >/dev/null \
    || fail "invalid v2 static config: ${file} must be static_config_version 2 with a unique, allowlisted dynamic_config_urls list led by ${canonical_url}, no dynamic_config_url, and a non-empty trusted_keys array"
}

check_v2_static_config prod/v2-static-voting-config.json "$prod_dynamic_url" "$prod_raw_dynamic_url"
check_v2_static_config stage/v2-static-voting-config.json "$stage_dynamic_url" "$stage_raw_dynamic_url"

# Both trust anchors for one environment must carry the same keys, so a key
# rotation can never land in one file and silently miss the other. CI runs this
# as its own step too; publication repeats it so a snapshot can never be built
# without it.
scripts/verify-trusted-key-parity.sh

prod_static_sha256="$(sha256_file prod/static-voting-config.json)"
stage_static_sha256="$(sha256_file stage/static-voting-config.json)"
prod_duplicate_sha256="$(sha256_file test/prod-static-voting-config-duplicate.json)"
stage_duplicate_sha256="$(sha256_file test/static-voting-config-duplicate.json)"
prod_pin="pins/prod/${prod_static_sha256}/static-voting-config.json"
stage_pin="pins/stage/${stage_static_sha256}/static-voting-config.json"
prod_duplicate_pin="pins/test/prod/${prod_duplicate_sha256}/static-voting-config.json"
stage_duplicate_pin="pins/test/stage/${stage_duplicate_sha256}/static-voting-config.json"
prod_static_v2_sha256="$(sha256_file prod/v2-static-voting-config.json)"
stage_static_v2_sha256="$(sha256_file stage/v2-static-voting-config.json)"
prod_v2_pin="pins/prod/${prod_static_v2_sha256}/v2-static-voting-config.json"
stage_v2_pin="pins/stage/${stage_static_v2_sha256}/v2-static-voting-config.json"

pin_count=0
while IFS= read -r pin; do
  if ! [[ "$pin" =~ ^pins/(test/)?(prod|stage)/([0-9a-f]{64})/(v2-)?static-voting-config\.json$ ]]; then
    fail "unexpected immutable pin path: ${pin}"
  fi
  pin_environment="${BASH_REMATCH[2]}"
  expected_pin_sha256="${BASH_REMATCH[3]}"
  pin_is_v2="${BASH_REMATCH[4]}"
  [[ "$(sha256_file "$pin")" == "$expected_pin_sha256" ]] \
    || fail "immutable pin bytes do not match its path: ${pin}"
  [[ ! -L "$pin" ]] || fail "immutable pin must be a regular file: ${pin}"
  jq -e . "$pin" >/dev/null || fail "invalid JSON: ${pin}"
  expected_pin_url="https://voting.valargroup.dev/${pin_environment}/dynamic-voting-config.json"
  if [[ -n "$pin_is_v2" ]]; then
    expected_pin_raw_url="https://raw.githubusercontent.com/valargroup/token-holder-voting-config/main/${pin_environment}/dynamic-voting-config.json"
    check_v2_static_config "$pin" "$expected_pin_url" "$expected_pin_raw_url"
  else
    jq -e --arg expected "$expected_pin_url" '.dynamic_config_url == $expected' "$pin" >/dev/null \
      || fail "${pin} points outside its controlled environment URL"
  fi
  pin_count=$((pin_count + 1))
done < <(find pins -type f -print | sort)

[[ "$pin_count" -gt 0 ]] || fail "at least one immutable static-config pin is required"

[[ -f "$prod_pin" ]] || fail "add the production static config to ${prod_pin}"
[[ -f "$stage_pin" ]] || fail "add the staging static config to ${stage_pin}"
[[ -f "$prod_duplicate_pin" ]] || fail "add the production duplicate static config to ${prod_duplicate_pin}"
[[ -f "$stage_duplicate_pin" ]] || fail "add the staging duplicate static config to ${stage_duplicate_pin}"
cmp -s prod/static-voting-config.json "$prod_pin" \
  || fail "${prod_pin} must be byte-for-byte identical to prod/static-voting-config.json"
cmp -s stage/static-voting-config.json "$stage_pin" \
  || fail "${stage_pin} must be byte-for-byte identical to stage/static-voting-config.json"
cmp -s test/prod-static-voting-config-duplicate.json "$prod_duplicate_pin" \
  || fail "${prod_duplicate_pin} must match the production duplicate static config"
cmp -s test/static-voting-config-duplicate.json "$stage_duplicate_pin" \
  || fail "${stage_duplicate_pin} must match the staging duplicate static config"
[[ -f "$prod_v2_pin" ]] || fail "add the production v2 static config to ${prod_v2_pin}"
[[ -f "$stage_v2_pin" ]] || fail "add the staging v2 static config to ${stage_v2_pin}"
cmp -s prod/v2-static-voting-config.json "$prod_v2_pin" \
  || fail "${prod_v2_pin} must be byte-for-byte identical to prod/v2-static-voting-config.json"
cmp -s stage/v2-static-voting-config.json "$stage_v2_pin" \
  || fail "${stage_v2_pin} must be byte-for-byte identical to stage/v2-static-voting-config.json"

if [[ "$source_revision" != "local-test" ]]; then
  scripts/verify-static-config-compatibility.sh
fi

for file in "${public_files[@]}"; do
  install -d "$output_dir/$(dirname "$file")"
  cp "$file" "$output_dir/$file"
done

install -d "$output_dir/pins"
cp -R pins/. "$output_dir/pins/"
cp _headers "$output_dir/_headers"
sed "s/__SOURCE_REVISION__/${source_revision}/g" \
  scripts/cloudflare-gateway.mjs > "$output_dir/_worker.js"

write_sidecar() {
  local relative_path="$1"
  local hash
  hash="$(sha256_file "$output_dir/$relative_path")"
  printf '%s  %s\n' "$hash" "$(basename "$relative_path")" > "$output_dir/${relative_path}.sha256"
}

write_sidecar prod/static-voting-config.json
write_sidecar prod/v2-static-voting-config.json
write_sidecar stage/static-voting-config.json
write_sidecar stage/v2-static-voting-config.json
write_sidecar test/prod-static-voting-config-duplicate.json
write_sidecar test/static-voting-config-duplicate.json

while IFS= read -r published_pin; do
  write_sidecar "${published_pin#"$output_dir/"}"
done < <(find "$output_dir/pins" -type f \
  \( -name 'static-voting-config.json' -o -name 'v2-static-voting-config.json' \) -print | sort)

published_at="${PUBLISHED_AT:-$(date -u +'%Y-%m-%dT%H:%M:%SZ')}"

jq -n \
  --arg source_revision "$source_revision" \
  --arg published_at "$published_at" \
  --arg prod_dynamic_sha256 "$(sha256_file prod/dynamic-voting-config.json)" \
  --arg prod_pir_sha256 "$(sha256_file prod/pir.json)" \
  --arg prod_static_sha256 "$prod_static_sha256" \
  --arg prod_static_v2_sha256 "$prod_static_v2_sha256" \
  --arg stage_dynamic_sha256 "$(sha256_file stage/dynamic-voting-config.json)" \
  --arg stage_pir_sha256 "$(sha256_file stage/pir.json)" \
  --arg stage_static_sha256 "$stage_static_sha256" \
  --arg stage_static_v2_sha256 "$stage_static_v2_sha256" \
  '{
    schema_version: 1,
    serving_model: "github-primary-cloudflare-pages-fallback",
    source_repository: "valargroup/token-holder-voting-config",
    source_revision: $source_revision,
    published_at: $published_at,
    configs: {
      prod: {
        dynamic_sha256: $prod_dynamic_sha256,
        pir_sha256: $prod_pir_sha256,
        static_sha256: $prod_static_sha256,
        static_v2_sha256: $prod_static_v2_sha256
      },
      stage: {
        dynamic_sha256: $stage_dynamic_sha256,
        pir_sha256: $stage_pir_sha256,
        static_sha256: $stage_static_sha256,
        static_v2_sha256: $stage_static_v2_sha256
      }
    }
  }' > "$output_dir/deployment-manifest.json"

printf 'Built Cloudflare Pages snapshot in %s\n' "$output_dir"
printf 'Production static pin: https://voting.valargroup.dev/%s?checksum=sha256:%s\n' "$prod_pin" "$prod_static_sha256"
printf 'Staging static pin: https://voting.valargroup.dev/%s?checksum=sha256:%s\n' "$stage_pin" "$stage_static_sha256"
printf 'Production v2 static pin: https://voting.valargroup.dev/%s?checksum=sha256:%s\n' "$prod_v2_pin" "$prod_static_v2_sha256"
printf 'Staging v2 static pin: https://voting.valargroup.dev/%s?checksum=sha256:%s\n' "$stage_v2_pin" "$stage_static_v2_sha256"
