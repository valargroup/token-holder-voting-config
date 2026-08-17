#!/usr/bin/env bash

# shellcheck disable=SC2034
github_outage_curl_args=(
  --noproxy 'github.com,api.github.com,raw.githubusercontent.com,objects.githubusercontent.com,media.githubusercontent.com,codeload.github.com'
  --connect-to 'github.com::127.0.0.1:1'
  --connect-to 'api.github.com::127.0.0.1:1'
  --connect-to 'raw.githubusercontent.com::127.0.0.1:1'
  --connect-to 'objects.githubusercontent.com::127.0.0.1:1'
  --connect-to 'media.githubusercontent.com::127.0.0.1:1'
  --connect-to 'codeload.github.com::127.0.0.1:1'
)
