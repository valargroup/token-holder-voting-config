#!/usr/bin/env bash

make_test_temp_dir() {
  local name="$1"
  local temp_root="${TMPDIR:-/tmp}"
  mktemp -d "${temp_root%/}/${name}.XXXXXXXXXX"
}
