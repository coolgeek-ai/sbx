#!/usr/bin/env bash
# Download sing-box and Xray-core for the tests into tests/.bin/
# Versions: environment variables SING_BOX_VERSION / XRAY_VERSION; values: "pinned" (default, read from compat/known-good.json) | "latest" | an explicit version
set -euo pipefail
cd "$(dirname "$0")/.."
OUT=tests/.bin; mkdir -p "$OUT"
resolve() {  # resolve VALUE REPO KNOWN_GOOD_KEY
  case $1 in
    pinned|"") jq -r --arg k "$3" '.tested[$k]' compat/known-good.json ;;
    latest)    local u; u=$(curl -fsSLI -o /dev/null -w '%{url_effective}' "https://github.com/$2/releases/latest"); u=${u##*/}; echo "${u#v}" ;;
    *)         echo "${1#v}" ;;
  esac
}
SB=$(resolve "${SING_BOX_VERSION:-pinned}" SagerNet/sing-box sing-box)
XR=$(resolve "${XRAY_VERSION:-pinned}"    XTLS/Xray-core     xray-core)
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
curl -fsSL --retry 3 -o "$tmp/sb.tgz" "https://github.com/SagerNet/sing-box/releases/download/v${SB}/sing-box-${SB}-linux-amd64.tar.gz"
tar -xzf "$tmp/sb.tgz" -C "$tmp"; install -m755 "$(find "$tmp" -name sing-box -type f | head -n1)" "$OUT/sing-box"
curl -fsSL --retry 3 -o "$tmp/xr.zip" "https://github.com/XTLS/Xray-core/releases/download/v${XR}/Xray-linux-64.zip"
unzip -oq "$tmp/xr.zip" xray -d "$tmp"; install -m755 "$tmp/xray" "$OUT/xray"
echo "sing-box ${SB} / xray ${XR}" | tee "$OUT/versions.txt"
