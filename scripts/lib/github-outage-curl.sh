#!/usr/bin/env bash

github_outage_no_proxy='github.com,api.github.com,raw.githubusercontent.com,objects.githubusercontent.com,media.githubusercontent.com,codeload.github.com'
for existing_no_proxy in "${NO_PROXY:-}" "${no_proxy:-}"; do
  if [[ -n "$existing_no_proxy" ]]; then
    github_outage_no_proxy="${github_outage_no_proxy},${existing_no_proxy}"
  fi
done

# shellcheck disable=SC2034
github_outage_curl_args=(
  --noproxy "$github_outage_no_proxy"
  --connect-to 'github.com::127.0.0.1:1'
  --connect-to 'api.github.com::127.0.0.1:1'
  --connect-to 'raw.githubusercontent.com::127.0.0.1:1'
  --connect-to 'objects.githubusercontent.com::127.0.0.1:1'
  --connect-to 'media.githubusercontent.com::127.0.0.1:1'
  --connect-to 'codeload.github.com::127.0.0.1:1'
)

unset existing_no_proxy github_outage_no_proxy
