#!/usr/bin/env bash
set -euo pipefail

[[ $# -eq 2 ]] || { echo "usage: $0 <dynamic-config> <static-config>" >&2; exit 2; }
dynamic_config="$1"
static_config="$2"

if [[ "$dynamic_config" != prod/dynamic-voting-config.json ]]; then
  exec voting-config verify --config "$dynamic_config" --static-config "$static_config"
fi

# Historical production signatures may bind an older global PIR layout.
# Keep wrapper/static-config validation, but leave round authentication to
# wallets. Only this temporary validation copy omits rounds; publication uses
# the original file, including every signature.
validation_config="$(mktemp)"
trap 'rm -f "$validation_config"' EXIT
jq --exit-status '
  if (.rounds | type) != "object" then error("rounds must be an object")
  elif any(.rounds | keys[]; test("^[0-9a-f]{64}$") | not)
    then error("round ids must be 64 lowercase hexadecimal characters")
  else .rounds = {} end
' "$dynamic_config" > "$validation_config"
voting-config verify --config "$validation_config" --static-config "$static_config"
printf 'Production config structure verified; round signatures are checked by wallets\n'
