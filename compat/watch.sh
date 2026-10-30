#!/usr/bin/env bash
# Compare upstream latest versions with compat/known-good.json; print one line for every project that is newer: <project> <new version> <known version>
set -euo pipefail
cd "$(dirname "$0")"
latest=$(./latest.sh)
for k in sing-box xray-core v2rayN v2rayNG; do
  new=$(jq -r --arg k "$k" '.[$k]' <<<"$latest")
  old=$(jq -r --arg k "$k" '(.tested[$k] // .reviewed[$k])' known-good.json)
  if [[ $new != "$old" && $(printf '%s\n%s\n' "$old" "$new" | sort -V | tail -n1) == "$new" ]]; then
    echo "$k $new $old"
  fi
done
