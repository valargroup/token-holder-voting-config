#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
command -v node >/dev/null || { printf 'error: node is required\n' >&2; exit 1; }
node "${script_dir}/wallet-list-alerts.test.mjs"
