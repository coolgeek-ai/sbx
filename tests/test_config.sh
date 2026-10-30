#!/usr/bin/env bash
# Config generation + link format + policy checks (needs sing-box)
set -uo pipefail
source "$(dirname "$0")/lib.sh"; require_bins

echo "== Static policy: the script must never emit configs that Xray has disabled =="
code=$(grep -v '^[[:space:]]*#' "$ROOT/sbx.sh")
assert_not_contains "$code" 'insecure=1'      "does not emit insecure=1"
assert_not_contains "$code" 'allowInsecure'   "does not emit allowInsecure"
assert_not_contains "$code" 'security=none'   "does not emit security=none"
assert_not_contains "$code" '"type":"dns"'    "does not use the legacy dns special outbound"

echo "== Per-protocol generation & sing-box check =="
out=$(sbx add reality -p 28443 --sni www.microsoft.com 2>&1); R=$(grep -m1 '^vless://' <<<"$out")
out=$(sbx add hy2     -p 28444 2>&1);                          H=$(grep -m1 '^hysteria2://' <<<"$out")
out=$(sbx add ss      -p 28445 2>&1);                          S=$(grep -m1 '^ss://' <<<"$out")
# trojan / vless-ws normally need a real domain + ACME; a self-signed certificate stands in here to validate the config structure
if bash -c '
  source "$0/sbx.sh"
  make_selfsigned fake example.com
  node_save tj trojan 28446 pass=abc123 domain=example.com cert=$(self_dir fake)/cert.pem key=$(self_dir fake)/key.pem
  node_save ws vless-ws 28447 uuid=$("$BIN" generate uuid) domain=example.com path=/abc cert=$(self_dir fake)/cert.pem key=$(self_dir fake)/key.pem
  apply_config' "$ROOT" >/dev/null 2>&1; then ok "trojan / vless-ws config is valid"; else bad "trojan / vless-ws config failed"; fi
if "$SBX_BIN" check -c "$SBX_ETC/config.json"; then ok "sing-box check passed (5 inbounds)"; else bad "sing-box check failed"; fi

echo "== REALITY links must carry every parameter (otherwise new clients parse them as having no security layer) =="
for k in 'encryption=none' 'flow=xtls-rprx-vision' 'security=reality' 'sni=' 'fp=chrome' 'pbk=[A-Za-z0-9_-]\{40,\}' 'sid=[0-9a-f]\{16\}' 'type=tcp'; do
  assert_contains "$R" "$k" "reality link contains $k"
done
echo "== Hysteria2: self-signed certificates must carry pinSHA256 and never insecure =="
assert_contains     "$H" 'pinSHA256=[0-9A-F:]\{95\}' "hy2 link contains the SHA-256 fingerprint"
assert_not_contains "$H" 'insecure'                  "hy2 link has no insecure parameter"
echo "== SS-2022 =="
assert_contains "$S" '^ss://[A-Za-z0-9+/]\+@' "ss link has base64 userinfo"

echo "== Port conflicts / rollback =="
if sbx add ss -p 28445 >/dev/null 2>&1; then bad "a duplicate port should be rejected"; else ok "duplicate port rejected"; fi
before=$(jq -S . "$SBX_ETC/config.json" | sha256sum)
sbx add reality -p 28450 --sni 'bad sni!' >/dev/null 2>&1 || true
after=$(jq -S . "$SBX_ETC/config.json" | sha256sum)
if [[ $before == "$after" ]]; then ok "invalid input leaves the existing config unchanged"; else bad "config was modified unexpectedly"; fi
if sbx del ss2022-28445 >/dev/null 2>&1; then ok "delete node"; else bad "delete node failed"; fi
if "$SBX_BIN" check -c "$SBX_ETC/config.json"; then ok "config still valid after deletion"; else bad "config invalid after deletion"; fi

echo "== Regression (v1.0.1): an empty node name in "show link" lists all nodes ==" 
out=$(sbx info "" 2>&1); assert_contains "$out" '^vless://' "sbx info '' lists every node instead of failing with 'node not found'"

echo "== Regression (v1.0.1): changing the port must also open the local firewall =="
log="$WORK/open_port.log"; : >"$log"
bash -c '
  source "$0/sbx.sh"; L=$1
  open_port() { echo "OPEN $*" >>"$L"; }
  cmd_change reality-28443 port 28460' "$ROOT" "$log" >/dev/null 2>&1 || true
assert_contains "$(cat "$log")" 'OPEN 28460 tcp' "change port calls open_port(new port, tcp)"

echo "== Regression (v1.0.1): deleting a node must not remove a domain certificate directory with the same name =="
mkdir -p "$SBX_ETC/certs/example.org"; echo keep >"$SBX_ETC/certs/example.org/fullchain.pem"
sbx add hy2 -p 28470 -n example.org >/dev/null 2>&1
sbx del example.org >/dev/null 2>&1
if [[ -s $SBX_ETC/certs/example.org/fullchain.pem ]]; then ok "domain certificate directory preserved"; else bad "domain certificate directory was deleted by mistake"; fi

echo "== Regression (v1.0.1): a failing menu action must not exit the whole menu =="
if command -v script >/dev/null 2>&1; then
  mout=$(printf '3\nno-such-node\n2\n0\n' | SBX_YES='' script -qec "bash $ROOT/sbx.sh menu" /dev/null 2>&1 | sed 's/\r//')
  assert_contains "$mout" 'NAME \+PROTO' "menu keeps running after an error (the following list action ran)"
else echo "  - skipped (no script command)"; fi
finish
