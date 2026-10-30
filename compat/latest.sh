#!/usr/bin/env bash
# Print the latest stable version of each upstream project (JSON). Uses redirects instead of the GitHub API to avoid unauthenticated rate limits.
set -euo pipefail
latest() {  # latest owner/repo
  local u; u=$(curl -fsSLI -o /dev/null -w '%{url_effective}' --retry 3 --max-time 20 "https://github.com/$1/releases/latest")
  u=${u##*/}; echo "${u#v}"
}
jq -n \
  --arg sb  "$(latest SagerNet/sing-box)" \
  --arg xr  "$(latest XTLS/Xray-core)" \
  --arg vn  "$(latest 2dust/v2rayN)" \
  --arg vng "$(latest 2dust/v2rayNG)" \
  '{"sing-box":$sb,"xray-core":$xr,"v2rayN":$vn,"v2rayNG":$vng}'
