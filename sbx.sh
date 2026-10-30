#!/usr/bin/env bash
# =============================================================================
#  sbx — sing-box server deployment / management script
#
#  Goal: generate share links that the latest v2rayN / v2rayNG (Xray-core)
#        can import and use directly.
#
#  Upstream changes handled (as of 2026-10):
#   1. Xray-core rejects VLESS/Trojan on public addresses without TLS/REALITY/VLESS-Encryption
#        -> only VLESS+REALITY / VLESS+WS+TLS / Trojan+TLS are generated, never plaintext VLESS
#   2. Xray-core removed allowInsecure (fully disabled from 2026-08-01)
#        -> self-signed certificates are always pinned (pinSHA256), never insecure=1;
#           with a domain, a real Let's Encrypt certificate is used
#   3. Complete share-link parameters (encryption/flow/security/sni/fp/pbk/sid/type are all explicit),
#      so clients never parse a REALITY node as "no security layer"
#   4. No GitHub API dependency (60 requests/hour when unauthenticated);
#      versions are read from the releases/latest redirect
#   5. Only config fields still supported by sing-box 1.14 (no legacy DNS / special outbounds / inline ACME)
#   6. `sing-box check` runs before a config is applied; failures roll back automatically
#
#  Protocols (all usable in both v2rayN and v2rayNG):
#     reality    VLESS + REALITY + Vision (tcp)       no domain needed, recommended
#     hysteria2  Hysteria2 (UDP/QUIC)                 no domain = self-signed + pinned fingerprint; domain = real certificate
#     ss2022     Shadowsocks 2022 (blake3-aes-128)    no domain needed (deprecated in Xray, fallback only)
#     trojan     Trojan + TLS                          domain required
#     vless-ws   VLESS + WebSocket + TLS               domain required (CDN-compatible)
#
#  Deliberately not included: TUIC / AnyTLS (unsupported by the Xray core in v2rayNG),
#                             XHTTP (no server-side support in sing-box)
#
#  Usage: bash sbx.sh install         # install and create a REALITY node automatically
#         sbx                         # interactive menu
#         sbx add reality|hy2|ss|trojan|ws [-n NAME] [-p PORT] [--sni HOST] [-d DOMAIN]
#         sbx list | info [NAME] | del <NAME> | change <NAME> port|sni <VALUE>
#         sbx restart | status | log [-f] | doctor | update [CORE_VERSION] | self-update | bbr | uninstall
# =============================================================================
set -Eeuo pipefail
export PATH="/usr/local/sbin:/usr/local/bin:$PATH"

SBX_VER="1.0.1"
SBX_REPO="${SBX_REPO:-coolgeek-ai/sbx}"     # repository used by install / self-update (owner/repo)
SBX_SCRIPT_URL="${SBX_SCRIPT_URL:-https://github.com/${SBX_REPO}/raw/main/sbx.sh}"
ETC="${SBX_ETC:-/etc/sing-box}"
BIN="${SBX_BIN:-/usr/local/bin/sing-box}"
SELF="${SBX_SELF:-/usr/local/bin/sbx}"
UNIT="${SBX_UNIT:-/etc/systemd/system/sing-box.service}"
NODES="$ETC/nodes"
CERTS="$ETC/certs"
CONF="$ETC/config.json"
TEST="${SBX_TEST:-0}"                       # 1 = test mode: skip systemd / firewall / root checks
REALITY_SNI_DEFAULT="${SBX_REALITY_SNI:-www.microsoft.com}"
SELF_SNI_DEFAULT="${SBX_SELF_SNI:-www.bing.com}"

if [[ -t 1 ]]; then R=$'\e[31m'; G=$'\e[32m'; Y=$'\e[33m'; C=$'\e[36m'; N=$'\e[0m'; else R=; G=; Y=; C=; N=; fi
info() { echo -e "${G}[+]${N} $*"; }
warn() { echo -e "${Y}[!]${N} $*" >&2; }
die()  { echo -e "${R}[x]${N} $*" >&2; exit 1; }
trap 'echo -e "${R}[x]${N} script failed at line $LINENO: $BASH_COMMAND" >&2' ERR

usage() {
  if [[ -f $0 ]]; then sed -n '2,/^set -E/p' "$0" | sed '$d'
  else echo "sbx $SBX_VER — sing-box server manager. After installation run: sbx help"; fi
}
is_tty()    { [[ -t 0 && -z ${SBX_YES:-} ]]; }
need_root() { if [[ $TEST != 1 && $EUID -ne 0 ]]; then die "please run as root (sudo -i)"; fi; }
need_core() { [[ -x $BIN ]] || die "sing-box is not installed; run the install command from the README first"; }
svc()       { if [[ $TEST == 1 ]]; then return 0; fi; systemctl "$@"; }

ask() {                                   # ask "prompt" "default"
  local p=$1 d=${2:-} a=""
  if is_tty; then read -r -p "$p${d:+ [$d]}: " a </dev/tty || true; fi
  echo "${a:-$d}"
}
confirm() {                               # confirm "prompt" -> default N; treated as N when non-interactive
  local a=""
  if is_tty; then read -r -p "$1 [y/N]: " a </dev/tty || true; fi
  [[ $a =~ ^[Yy]$ ]]
}

# ----------------------------------------------------------------------------
# System / dependencies
# ----------------------------------------------------------------------------
pkg_install() {
  if   command -v apt-get >/dev/null; then DEBIAN_FRONTEND=noninteractive apt-get update -y -qq >/dev/null && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$@" >/dev/null
  elif command -v dnf     >/dev/null; then dnf install -y -q "$@" >/dev/null
  elif command -v yum     >/dev/null; then yum install -y -q "$@" >/dev/null
  elif command -v apk     >/dev/null; then apk add --no-cache "$@" >/dev/null
  else die "unsupported distribution, please install manually: $*"; fi
}

ensure_deps() {
  local miss=() c pkg
  for c in curl jq openssl tar ss; do command -v "$c" >/dev/null 2>&1 || miss+=("$c"); done
  if ((${#miss[@]} == 0)); then return 0; fi
  need_root
  info "Installing dependencies: ${miss[*]}"
  local pk=()
  for c in "${miss[@]}"; do
    case $c in
      ss) if command -v apt-get >/dev/null; then pkg=iproute2; else pkg=iproute; fi ;;
      *)  pkg=$c ;;
    esac
    pk+=("$pkg")
  done
  pkg_install "${pk[@]}"
}

detect_arch() {
  case "$(uname -m)" in
    x86_64|amd64)   echo amd64 ;;
    aarch64|arm64)  echo arm64 ;;
    armv7l|armv7)   echo armv7 ;;
    i386|i686)      echo 386 ;;
    s390x)          echo s390x ;;
    *) die "unsupported CPU architecture: $(uname -m)" ;;
  esac
}

# ----------------------------------------------------------------------------
# Core install / update   (no GitHub API: avoids the 60 requests/hour limit)
# ----------------------------------------------------------------------------
latest_version() {
  local loc
  loc=$(curl -fsSLI -o /dev/null -w '%{url_effective}' --retry 3 --max-time 20 \
        https://github.com/SagerNet/sing-box/releases/latest) || return 1
  loc=${loc##*/v}
  [[ $loc =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1     # stable releases only
  echo "$loc"
}

install_core() {
  need_root; ensure_deps
  local ver=${1:-} arch url tmp
  ver=${ver#v}
  if [[ -z $ver ]]; then ver=$(latest_version) || die "cannot determine the latest version (network issue?); try: sbx update 1.14.4"; fi
  arch=$(detect_arch)
  url="${SBX_CORE_URL:-https://github.com/SagerNet/sing-box/releases/download/v${ver}/sing-box-${ver}-linux-${arch}.tar.gz}"
  info "Downloading sing-box ${ver} (${arch})"
  tmp=$(mktemp -d)
  curl -fSL --retry 3 --max-time 300 -o "$tmp/sb.tgz" "$url" || { rm -rf "$tmp"; die "download failed: $url"; }
  tar -xzf "$tmp/sb.tgz" -C "$tmp"
  local d; d=$(find "$tmp" -maxdepth 2 -type f -name sing-box | head -n1)
  [[ -n $d ]] || { rm -rf "$tmp"; die "sing-box binary not found in the archive"; }
  install -d "$(dirname "$BIN")"
  install -m 755 "$d" "$BIN.new" && mv -f "$BIN.new" "$BIN"
  if [[ -f $(dirname "$d")/libcronet.so ]]; then install -m 644 "$(dirname "$d")/libcronet.so" "$(dirname "$BIN")/libcronet.so"; fi
  rm -rf "$tmp"
  info "Installed: $("$BIN" version | head -n1)"
}

write_unit() {
  [[ $TEST == 1 ]] && return 0
  cat >"$UNIT" <<EOF
[Unit]
Description=sing-box service
After=network-online.target nss-lookup.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$BIN run -c $CONF
ExecReload=/bin/kill -HUP \$MAINPID
Restart=on-failure
RestartSec=3s
LimitNOFILE=1048576
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable sing-box >/dev/null 2>&1
}

# ----------------------------------------------------------------------------
# Network helpers
# ----------------------------------------------------------------------------
get_ip4() {
  local u ip
  for u in https://api.ipify.org https://ipv4.icanhazip.com https://ifconfig.me/ip; do
    ip=$(curl -4fsS --max-time 5 "$u" 2>/dev/null | tr -d '[:space:]') || ip=""
    if [[ $ip =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then echo "$ip"; return 0; fi
  done
  return 1
}
get_ip6() {
  local u ip
  for u in https://api64.ipify.org https://ipv6.icanhazip.com; do
    ip=$(curl -6fsS --max-time 5 "$u" 2>/dev/null | tr -d '[:space:]') || ip=""
    if [[ $ip == *:* ]]; then echo "$ip"; return 0; fi
  done
  return 1
}
server_ip() {
  if [[ -n ${SBX_IP:-} ]]; then echo "$SBX_IP"; return 0; fi
  get_ip4 || get_ip6 || die "cannot determine the server public IP; set SBX_IP=x.x.x.x"
}
fmt_host() { if [[ $1 == *:* && $1 != \[* ]]; then echo "[$1]"; else echo "$1"; fi; }
listen_addr() {
  if [[ -f /proc/net/if_inet6 && $(cat /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null || echo 1) == 0 ]]; then echo "::"; else echo "0.0.0.0"; fi
}
port_free() { ! ss -lntuH 2>/dev/null | awk '{print $5}' | grep -Eq "[:.]$1\$"; }
rand_port() { local p; while :; do p=$(shuf -i 20000-60000 -n 1); if port_free "$p"; then echo "$p"; return; fi; done; }
valid_host() { [[ $1 =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ && ${#1} -le 253 ]]; }
urlenc() { jq -rn --arg s "$1" '$s|@uri'; }
rand_str() { openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | head -c "${1:-20}"; }

open_port() {                              # open_port PORT tcp|udp|both
  [[ $TEST == 1 ]] && return 0
  local p=$1 proto=$2 pr
  local list=(); if [[ $proto == both ]]; then list=(tcp udp); else list=("$proto"); fi
  if command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
    for pr in "${list[@]}"; do ufw allow "$p/$pr" >/dev/null; done; info "ufw: allowed $p/${list[*]}"
  fi
  if command -v firewall-cmd >/dev/null && firewall-cmd --state >/dev/null 2>&1; then
    for pr in "${list[@]}"; do firewall-cmd --permanent --add-port="$p/$pr" >/dev/null; done
    firewall-cmd --reload >/dev/null; info "firewalld: allowed $p/${list[*]}"
  fi
}

# ----------------------------------------------------------------------------
# Certificates
# ----------------------------------------------------------------------------
self_dir() { echo "$CERTS/_self/$1"; }          # self-signed cert dir: kept apart from domain cert dirs ($CERTS/<domain>) so deleting a node never removes a domain certificate
proto_of() { case $1 in hysteria2) echo udp ;; ss2022) echo both ;; *) echo tcp ;; esac; }
cert_pin() { openssl x509 -in "$1" -noout -fingerprint -sha256 | cut -d= -f2; }   # AA:BB:...

make_selfsigned() {                        # make_selfsigned NODE_NAME CN
  local name=$1 cn=$2 d san; d=$(self_dir "$name")
  mkdir -p "$d"
  if [[ $cn =~ ^[0-9.]+$ || $cn == *:* ]]; then san="IP:$cn"; else san="DNS:$cn"; fi
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -sha256 -days 3650 \
    -subj "/CN=$cn" -addext "subjectAltName=$san" \
    -keyout "$d/key.pem" -out "$d/cert.pem" >/dev/null 2>&1
  chmod 600 "$d/key.pem"
}

check_dns() {
  local d=$1 resolved ip4 ip6 ok=0 r
  resolved=$(getent ahosts "$d" 2>/dev/null | awk '{print $1}' | sort -u || true)
  [[ -n $resolved ]] || { warn "domain $d does not resolve yet; point its A/AAAA record to this server first (with Cloudflare, turn the orange-cloud proxy off)"; confirm "Continue anyway?" || die "cancelled"; return 0; }
  ip4=$(get_ip4 || true); ip6=$(get_ip6 || true)
  for r in $resolved; do [[ $r == "$ip4" || $r == "$ip6" ]] && ok=1; done
  if ((ok == 0)); then
    warn "domain $d resolves to [$(echo $resolved | tr '\n' ' ')], which does not match this server IP (${ip4:-none}/${ip6:-none})"
    confirm "Request the certificate anyway?" || die "cancelled"
  fi
}

issue_cert() {                             # issue_cert DOMAIN -> the certificate is stored in $CERTS/DOMAIN/
  local d=$1 dir="$CERTS/$1" acme="$HOME/.acme.sh/acme.sh"
  if [[ -s $dir/fullchain.pem && -s $dir/key.pem ]]; then info "Reusing existing certificate: $d"; return 0; fi
  need_root; check_dns "$d"
  command -v socat >/dev/null || pkg_install socat
  command -v crontab >/dev/null || { if command -v apt-get >/dev/null; then pkg_install cron; else pkg_install cronie; fi; }
  port_free 80 || die "port 80 is in use; the standalone ACME challenge needs it (free port 80 first)"
  open_port 80 tcp
  if [[ ! -x $acme ]]; then info "Installing acme.sh"; curl -fsSL https://get.acme.sh | sh >/dev/null 2>&1 || die "acme.sh installation failed"; fi
  "$acme" --set-default-ca --server letsencrypt >/dev/null 2>&1
  mkdir -p "$dir"
  info "Requesting a Let's Encrypt certificate for $d ..."
  local alog; alog=$(mktemp /tmp/sbx-acme.XXXXXX.log)
  "$acme" --issue -d "$d" --standalone --keylength ec-256 >"$alog" 2>&1 \
    || { tail -n 15 "$alog" >&2; die "certificate request failed (log: $alog)"; }
  rm -f "$alog"
  "$acme" --install-cert -d "$d" --ecc --key-file "$dir/key.pem" --fullchain-file "$dir/fullchain.pem" \
          --reloadcmd "systemctl restart sing-box" >/dev/null 2>&1 || die "certificate installation failed"
  chmod 600 "$dir/key.pem"
  info "Certificate issued; automatic renewal configured"
}

# ----------------------------------------------------------------------------
# Node storage (one JSON file per node; config.json is generated from them)
# ----------------------------------------------------------------------------
j() { jq -r --arg k "$2" '.[$k] // empty' "$1"; }          # j FILE KEY

node_save() {                              # node_save NAME TYPE PORT k=v ...
  local name=$1 type=$2 port=$3; shift 3
  local args=(--arg name "$name" --arg type "$type" --arg port "$port") filter='{name:$name,type:$type,port:($port|tonumber)}' kv k v
  for kv in "$@"; do
    k=${kv%%=*}; v=${kv#*=}
    args+=(--arg "k_$k" "$v"); filter+=" + {\"$k\": \$k_$k}"
  done
  mkdir -p "$NODES"; chmod 700 "$ETC" "$NODES" 2>/dev/null || true
  jq -n "${args[@]}" "$filter" >"$NODES/$name.json"
  chmod 600 "$NODES/$name.json"
}

node_files() { compgen -G "$NODES/*.json" >/dev/null && ls -1 "$NODES"/*.json || true; }

inbound_json() {                           # build a sing-box inbound from a node JSON
  jq -c --arg l "$(listen_addr)" '
    def base: {tag:("in-"+.name), listen:$l, listen_port:.port};
    if .type=="reality" then
      base + {type:"vless", users:[{name:.name, uuid:.uuid, flow:"xtls-rprx-vision"}],
              tls:{enabled:true, server_name:.sni,
                   reality:{enabled:true, handshake:{server:.sni, server_port:443},
                            private_key:.priv, short_id:[.sid]}}}
    elif .type=="hysteria2" then
      base + {type:"hysteria2", users:[{name:.name, password:.pass}],
              ignore_client_bandwidth:true,
              tls:{enabled:true, alpn:["h3"], certificate_path:.cert, key_path:.key},
              masquerade:"https://www.bing.com"}
    elif .type=="ss2022" then
      base + {type:"shadowsocks", method:.method, password:.pass}
    elif .type=="trojan" then
      base + {type:"trojan", users:[{name:.name, password:.pass}],
              tls:{enabled:true, server_name:.domain, alpn:["h2","http/1.1"],
                   certificate_path:.cert, key_path:.key}}
    elif .type=="vless-ws" then
      base + {type:"vless", users:[{name:.name, uuid:.uuid}],
              tls:{enabled:true, server_name:.domain, alpn:["http/1.1"],
                   certificate_path:.cert, key_path:.key},
              transport:{type:"ws", path:.path}}
    else error("unknown type " + .type) end' "$1"
}

build_config() {
  local f inb=()
  while IFS= read -r f; do [[ -n $f ]] && inb+=("$(inbound_json "$f")"); done < <(node_files)
  local arr="[]"
  if ((${#inb[@]} > 0)); then arr=$(printf '%s\n' "${inb[@]}" | jq -s '.'); fi
  jq -n --argjson inb "$arr" '{
    log:{level:"warn", timestamp:true},
    inbounds:$inb,
    outbounds:[{type:"direct", tag:"direct"}]
  }'
}

svc_restart() {
  [[ $TEST == 1 ]] && return 0
  systemctl restart sing-box
  sleep 2
  if ! systemctl is-active --quiet sing-box; then
    journalctl -u sing-box -n 20 --no-pager >&2 || true
    return 1
  fi
}

apply_config() {
  mkdir -p "$ETC"
  local tmp="$CONF.new"
  build_config >"$tmp"
  if ! "$BIN" check -c "$tmp"; then rm -f "$tmp"; return 1; fi
  mv -f "$tmp" "$CONF"; chmod 600 "$CONF"
  if [[ -z $(node_files) ]]; then svc stop || true; return 0; fi
  svc_restart
}

# ----------------------------------------------------------------------------
# Share links
# ----------------------------------------------------------------------------
node_host() {                              # prefer the domain, otherwise the server IP
  local f=$1 h; h=$(j "$f" domain)
  if [[ -z $h ]]; then h=$(fmt_host "$(server_ip)"); fi
  echo "$h"
}

node_link() {
  local f=$1 type name port host tag
  type=$(j "$f" type); name=$(j "$f" name); port=$(j "$f" port); host=$(node_host "$f"); tag=$(urlenc "$name")
  case $type in
    reality)
      echo "vless://$(j "$f" uuid)@${host}:${port}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=$(j "$f" sni)&fp=chrome&pbk=$(j "$f" pub)&sid=$(j "$f" sid)&type=tcp&headerType=none#${tag}" ;;
    hysteria2)
      local pin; pin=$(j "$f" pin)
      echo "hysteria2://$(j "$f" pass)@${host}:${port}?sni=$(j "$f" sni)&alpn=h3${pin:+&pinSHA256=$pin}#${tag}" ;;
    ss2022)
      local ui; ui=$(printf '%s' "$(j "$f" method):$(j "$f" pass)" | base64 -w0 | tr -d '=')
      echo "ss://${ui}@${host}:${port}#${tag}" ;;
    trojan)
      echo "trojan://$(j "$f" pass)@${host}:${port}?security=tls&sni=$(j "$f" domain)&fp=chrome&type=tcp#${tag}" ;;
    vless-ws)
      local d p; d=$(j "$f" domain); p=$(urlenc "$(j "$f" path)")
      echo "vless://$(j "$f" uuid)@${host}:${port}?encryption=none&security=tls&sni=${d}&fp=chrome&type=ws&host=${d}&path=${p}#${tag}" ;;
    *) die "unknown type: $type" ;;
  esac
}

show_node() {
  local f=$1 link
  link=$(node_link "$f")
  echo
  echo -e "${C}━━ $(j "$f" name)  [$(j "$f" type)]  port $(j "$f" port) ━━${N}"
  echo -e "${G}${link}${N}"
  if command -v qrencode >/dev/null 2>&1; then qrencode -t ANSIUTF8 "$link" || true; fi
  case $(j "$f" type) in
    hysteria2) if [[ -n $(j "$f" pin) ]]; then echo "  (self-signed certificate; the link carries its pinSHA256 fingerprint. After importing, do not enable the skip-certificate-verification option)"; fi ;;
    vless-ws)  case $(j "$f" port) in 443|8443|2053|2083|2087|2096) ;; *) echo "  (note: port $(j "$f" port) is not one of the HTTPS ports Cloudflare can proxy, so it cannot sit behind the CDN; for CDN use 443/8443/2053/2083/2087/2096)" ;; esac ;;
    ss2022)    echo "  (SS-2022 needs client and server clocks within 30 seconds of each other; Xray-core marks Shadowsocks as deprecated and may remove it, so prefer reality / hysteria2)" ;;
  esac
}

# ----------------------------------------------------------------------------
# Add a node
# ----------------------------------------------------------------------------
norm_type() {
  case ${1,,} in
    reality|vless-reality|vless) echo reality ;;
    hy2|hysteria2|hysteria)      echo hysteria2 ;;
    ss|ss2022|shadowsocks)       echo ss2022 ;;
    trojan)                      echo trojan ;;
    ws|vless-ws|vless-ws-tls)    echo vless-ws ;;
    *) echo "" ;;
  esac
}

pick_type() {
  cat >&2 <<EOF
  1) VLESS + REALITY + Vision   (no domain needed, recommended)
  2) Hysteria2                  (UDP, loss-tolerant; works without a domain)
  3) Shadowsocks 2022           (no domain needed; deprecated in Xray, not recommended)
  4) Trojan + TLS               (domain required)
  5) VLESS + WS + TLS           (domain required; behind a CDN use port 443/8443/2053/2083/2087/2096)
EOF
  case $(ask "Choose a protocol" 1) in 1) echo reality;; 2) echo hysteria2;; 3) echo ss2022;; 4) echo trojan;; 5) echo vless-ws;; *) die "invalid choice";; esac
}

check_reality_sni() {
  local s=$1 out
  out=$(echo | timeout 8 openssl s_client -connect "$s:443" -servername "$s" -tls1_3 -alpn h2 2>/dev/null || true)
  if grep -q "TLSv1.3" <<<"$out" && grep -q "ALPN protocol: h2" <<<"$out"; then
    info "REALITY target $s supports TLS1.3 + h2 ✔"
  else
    warn "cannot confirm that $s supports TLS1.3 + h2 (it may be a local network problem). REALITY requires the target site to support TLS1.3 and h2."
    if is_tty && ! confirm "Use $s anyway?"; then die "cancelled"; fi
  fi
}

cmd_add() {
  need_root; need_core; ensure_deps
  local type="" name="" port="" sni="" domain=""
  if (($# > 0)) && [[ $1 != -* ]]; then type=$(norm_type "$1"); [[ -n $type ]] || die "unknown protocol: $1"; shift; fi
  while (($#)); do
    case $1 in
      -n|--name)   name=${2:?missing value}; shift 2 ;;
      -p|--port)   port=${2:?missing value}; shift 2 ;;
      --sni)       sni=${2:?missing value}; shift 2 ;;
      -d|--domain) domain=${2:?missing value}; shift 2 ;;
      *) die "unknown option: $1" ;;
    esac
  done
  [[ -n $type ]] || type=$(pick_type)

  if [[ -n $sni ]]; then valid_host "$sni" || die "invalid SNI: $sni"; fi
  if [[ -n $domain ]]; then valid_host "$domain" || die "invalid domain: $domain"; fi

  # Port
  local def_port
  case $type in reality|trojan|vless-ws) if port_free 443; then def_port=443; else def_port=$(rand_port); fi ;; *) def_port=$(rand_port) ;; esac
  [[ -n $port ]] || port=$(ask "Listen port" "$def_port")
  [[ $port =~ ^[0-9]+$ ]] && ((port >= 1 && port <= 65535)) || die "invalid port: $port"
  port_free "$port" || die "port $port is already in use"
  local existing=(); mapfile -t existing < <(node_files)
  if ((${#existing[@]} > 0)) && jq -e --argjson p "$port" 'select(.port==$p)' "${existing[@]}" >/dev/null 2>&1; then die "port $port is already used by another node"; fi

  # Name
  [[ -n $name ]] || name="${type}-${port}"
  [[ $name =~ ^[A-Za-z0-9._-]+$ ]] || die "name may only contain letters, digits, . _ -"
  [[ ! -e $NODES/$name.json ]] || die "node $name already exists"

  local proto=tcp
  case $type in
    reality)
      [[ -n $sni ]] || sni=$(ask "REALITY target domain (must support TLS1.3+h2)" "$REALITY_SNI_DEFAULT")
      valid_host "$sni" || die "invalid SNI: $sni"
      check_reality_sni "$sni"
      local kp priv pub uuid sid
      kp=$("$BIN" generate reality-keypair)
      priv=$(awk '/PrivateKey/{print $2}' <<<"$kp"); pub=$(awk '/PublicKey/{print $2}' <<<"$kp")
      [[ -n $priv && -n $pub ]] || die "failed to generate REALITY keys"
      uuid=$("$BIN" generate uuid); sid=$(openssl rand -hex 8)
      node_save "$name" reality "$port" uuid="$uuid" priv="$priv" pub="$pub" sid="$sid" sni="$sni"
      ;;
    hysteria2)
      proto=udp
      local cert key pin="" cn
      if [[ -z $domain ]] && is_tty; then domain=$(ask "Domain (empty = self-signed certificate with pinned fingerprint)" ""); fi
      if [[ -n $domain ]]; then
        valid_host "$domain" || die "invalid domain: $domain"
        issue_cert "$domain"; cert="$CERTS/$domain/fullchain.pem"; key="$CERTS/$domain/key.pem"; cn=$domain
      else
        cn=${sni:-$SELF_SNI_DEFAULT}; make_selfsigned "$name" "$cn"
        cert="$(self_dir "$name")/cert.pem"; key="$(self_dir "$name")/key.pem"; pin=$(cert_pin "$cert")
      fi
      node_save "$name" hysteria2 "$port" pass="$(rand_str 24)" cert="$cert" key="$key" sni="$cn" domain="$domain" pin="$pin"
      ;;
    ss2022)
      proto=both
      node_save "$name" ss2022 "$port" method="2022-blake3-aes-128-gcm" pass="$(openssl rand -base64 16)"
      ;;
    trojan|vless-ws)
      [[ -n $domain ]] || domain=$(ask "Domain (required; must already resolve to this server)" "")
      [[ -n $domain ]] || die "$type requires a domain"
      valid_host "$domain" || die "invalid domain: $domain"
      issue_cert "$domain"
      if [[ $type == trojan ]]; then
        node_save "$name" trojan "$port" pass="$(rand_str 24)" domain="$domain" cert="$CERTS/$domain/fullchain.pem" key="$CERTS/$domain/key.pem"
      else
        node_save "$name" vless-ws "$port" uuid="$("$BIN" generate uuid)" domain="$domain" path="/$(rand_str 10)" cert="$CERTS/$domain/fullchain.pem" key="$CERTS/$domain/key.pem"
      fi
      ;;
  esac

  if ! apply_config; then
    warn "config validation / startup failed; rolled back"
    rm -f "$NODES/$name.json"; rm -rf "$(self_dir "$name")"
    apply_config >/dev/null 2>&1 || true
    die "failed to create node $name"
  fi
  open_port "$port" "$proto"
  info "Node $name created"
  show_node "$NODES/$name.json"
  echo
  warn "On a cloud provider, also allow $port/${proto/both/tcp+udp} in the security group / cloud firewall"
}

# ----------------------------------------------------------------------------
# Other commands
# ----------------------------------------------------------------------------
cmd_list() {
  local f any=0
  printf "%-28s %-11s %s\n" NAME PROTO PORT
  while IFS= read -r f; do
    [[ -n $f ]] || continue; any=1
    printf "%-28s %-11s %s\n" "$(j "$f" name)" "$(j "$f" type)" "$(j "$f" port)"
  done < <(node_files)
  if ((any == 0)); then echo "(no nodes yet; create one with: sbx add)"; fi
}

cmd_info() {
  local f
  if (($# > 0)) && [[ -n $1 ]]; then
    f="$NODES/$1.json"; [[ -f $f ]] || die "node not found: $1"; show_node "$f"
  else
    while IFS= read -r f; do [[ -n $f ]] && show_node "$f"; done < <(node_files)
  fi
}

cmd_del() {
  need_root; need_core
  local name=${1:-}; [[ -n $name ]] || die "usage: sbx del <name>"
  [[ -f $NODES/$name.json ]] || die "node not found: $name"
  confirm "Delete node $name?" || { is_tty || true; [[ -n ${SBX_YES:-} ]] || die "cancelled"; }
  rm -f "$NODES/$name.json"; rm -rf "$(self_dir "$name")"
  apply_config || die "failed to regenerate the config"
  info "Deleted $name"
}

cmd_change() {
  need_root; need_core
  local name=${1:-} what=${2:-} val=${3:-} f
  [[ -n $name && -n $what && -n $val ]] || die "usage: sbx change <name> port|sni <value>"
  f="$NODES/$name.json"; [[ -f $f ]] || die "node not found: $name"
  local bak; bak=$(cat "$f")
  case $what in
    port)
      [[ $val =~ ^[0-9]+$ ]] && ((val >= 1 && val <= 65535)) || die "invalid port"
      port_free "$val" || die "port $val is already in use"
      jq --argjson v "$val" '.port=$v' <<<"$bak" >"$f" ;;
    sni)
      [[ $(j "$f" type) == reality ]] || die "only reality nodes support changing the SNI"
      check_reality_sni "$val"
      jq --arg v "$val" '.sni=$v' <<<"$bak" >"$f" ;;
    *) die "unsupported setting: $what" ;;
  esac
  if ! apply_config; then printf '%s' "$bak" >"$f"; apply_config >/dev/null 2>&1 || true; die "change failed; rolled back"; fi
  if [[ $what == port ]]; then
    open_port "$val" "$(proto_of "$(j "$f" type)")"
    warn "Also allow the new port $val/$(proto_of "$(j "$f" type)" | sed 's/both/tcp+udp/') in your cloud provider's security group / firewall (the old port rule can be removed)"
  fi
  info "Updated"; show_node "$f"
}

cmd_status() { svc status sing-box --no-pager -l | head -n 20 || true; }
cmd_log()    { if [[ ${1:-} == -f ]]; then journalctl -u sing-box -f; else journalctl -u sing-box -n 100 --no-pager; fi; }
cmd_restart(){ need_root; apply_config && info "Restarted"; }

cmd_bbr() {
  need_root
  modprobe tcp_bbr 2>/dev/null || true
  if ! grep -qw bbr /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null; then die "this kernel does not support BBR"; fi
  printf 'net.core.default_qdisc=fq\nnet.ipv4.tcp_congestion_control=bbr\n' >/etc/sysctl.d/99-sbx-bbr.conf
  sysctl --system >/dev/null 2>&1 || sysctl -p /etc/sysctl.d/99-sbx-bbr.conf >/dev/null
  info "BBR enabled: $(sysctl -n net.ipv4.tcp_congestion_control)"
}

cmd_doctor() {
  need_core
  local f ok=1 t p
  echo "sbx $SBX_VER | $("$BIN" version | head -n1)"
  if "$BIN" check -c "$CONF" >/dev/null 2>&1; then info "config syntax: OK"; else warn "config syntax: FAILED"; ok=0; fi
  if [[ $TEST != 1 ]]; then
    if systemctl is-active --quiet sing-box; then info "service: running"; else warn "service: not running (journalctl -u sing-box -n 50)"; ok=0; fi
    if [[ $(timedatectl show -p NTPSynchronized --value 2>/dev/null || echo yes) != yes ]]; then warn "system clock is not synchronized (SS-2022 / QUIC are time-sensitive); run: timedatectl set-ntp true"; fi
  fi
  while IFS= read -r f; do
    [[ -n $f ]] || continue
    p=$(j "$f" port); t=$(j "$f" type)
    if ss -lntuH 2>/dev/null | awk '{print $5}' | grep -Eq "[:.]$p\$"; then info "$(j "$f" name): port $p is listening"; else warn "$(j "$f" name): port $p is not listening"; ok=0; fi
    case $t in
      hysteria2|trojan|vless-ws)
        local c; c=$(j "$f" cert)
        if [[ -f $c ]] && ! openssl x509 -in "$c" -noout -checkend 604800 >/dev/null 2>&1; then warn "$(j "$f" name): certificate expires within 7 days or has already expired"; ok=0; fi ;;
    esac
  done < <(node_files)
  echo "Client note: use the latest v2rayN / v2rayNG; if a node still cannot connect, try switching that node's core type to sing-box in v2rayN."
  if ((ok == 1)); then info "All checks passed"; fi
}

cmd_update() {
  need_root; ensure_deps
  local cur new; cur=$("$BIN" version 2>/dev/null | awk 'NR==1{print $3}' || echo none)
  new=${1:-$(latest_version || true)}; new=${new#v}
  [[ -n $new ]] || die "cannot determine the latest version"
  if [[ $cur == "$new" ]]; then info "Already up to date ($cur)"; return 0; fi
  cp -f "$BIN" "$BIN.bak" 2>/dev/null || true
  install_core "$new"
  if ! apply_config; then warn "new version failed to start; rolling back to $cur"; mv -f "$BIN.bak" "$BIN"; apply_config || true; die "update failed"; fi
  rm -f "$BIN.bak"; info "Updated: $cur -> $new"
}

cmd_self_update() {
  need_root; ensure_deps
  local base="https://github.com/${SBX_REPO}/releases/latest/download" tmp want got
  tmp=$(mktemp -d)
  curl -fsSL --retry 3 -o "$tmp/sbx.sh" "$base/sbx.sh" || { rm -rf "$tmp"; die "failed to download sbx.sh"; }
  curl -fsSL --retry 3 -o "$tmp/SHA256SUMS" "$base/SHA256SUMS" || { rm -rf "$tmp"; die "failed to download SHA256SUMS"; }
  want=$(awk '$2=="sbx.sh"||$2=="*sbx.sh"{print $1}' "$tmp/SHA256SUMS"); got=$(sha256sum "$tmp/sbx.sh" | awk '{print $1}')
  [[ -n $want && $want == "$got" ]] || { rm -rf "$tmp"; die "SHA256 verification failed; aborting"; }
  bash -n "$tmp/sbx.sh" || { rm -rf "$tmp"; die "syntax check of the new script failed; aborting"; }
  install -m 755 "$tmp/sbx.sh" "$SELF"; rm -rf "$tmp"
  info "Script updated: $("$SELF" version)"
}

cmd_install() {
  need_root; ensure_deps
  local ver="" auto=1
  while (($#)); do case $1 in -v) ver=$2; shift 2 ;; --no-node) auto=0; shift ;; *) die "unknown option: $1" ;; esac; done
  [[ $TEST == 1 ]] || command -v systemctl >/dev/null || die "systemd is required (OpenRC / Alpine are not supported)"
  if [[ ! -d $NODES && ( -d $ETC/sh || -x $ETC/bin/sing-box || -d $ETC/conf ) && -z ${SBX_FORCE:-} ]]; then
    die "an existing sing-box installation from another script was found under $ETC and would conflict with sbx. Uninstall it first, or set SBX_FORCE=1 if you are sure it is safe"
  fi
  install_core "$ver"
  mkdir -p "$ETC" "$NODES" "$CERTS"; chmod 700 "$ETC"
  # self-install: make the `sbx` command available
  if [[ -f $0 ]]; then
    if [[ $(readlink -f "$0") != "$(readlink -f "$SELF" 2>/dev/null || echo x)" ]]; then
      install -m 755 "$0" "$SELF"; info "Management command installed: sbx"
    fi
  else
    # started through a pipe / process substitution (bash <(wget ...)): fetch a copy of the script
    local stmp; stmp=$(mktemp)
    if curl -fsSL --retry 3 --max-time 60 -o "$stmp" "$SBX_SCRIPT_URL" && bash -n "$stmp"; then
      install -m 755 "$stmp" "$SELF"; info "Management command installed: sbx"
    else
      warn "could not install the sbx command from $SBX_SCRIPT_URL"
    fi
    rm -f "$stmp"
  fi
  write_unit
  if [[ -z $(node_files) && $auto == 1 ]]; then info "Creating a default node: VLESS+REALITY"; cmd_add reality; else apply_config || true; fi
  echo; info "Done. Run sbx to open the management menu."
}

cmd_uninstall() {
  need_root
  confirm "This stops and removes sing-box and all node configurations. Continue?" || die "cancelled"
  svc stop || true; svc disable || true
  rm -f "$UNIT" "$BIN" "$(dirname "$BIN")/libcronet.so" /etc/sysctl.d/99-sbx-bbr.conf
  rm -rf "$ETC"
  svc daemon-reload || true
  rm -f "$SELF"
  info "Uninstalled (acme.sh and the certificates it issued were kept in ~/.acme.sh)"
}

menu() {
  while :; do
    cat <<EOF

${C}sbx $SBX_VER — sing-box manager${N}
  1) Add node         2) List nodes       3) Show link / QR
  4) Delete node      5) Change port/SNI  6) Restart service
  7) Status           8) View log         9) Self-check (doctor)
 10) Update core     11) Enable BBR      12) Uninstall
  0) Exit
EOF
    local c; c=$(ask "Select" 0)
    case $c in
      1) ( cmd_add ) || true ;;
      2) cmd_list ;;
      3) ( cmd_info "$(ask "Node name (empty = all)" "")" ) || true ;;
      4) ( cmd_del "$(ask "Name of the node to delete" "")" ) || true ;;
      5) ( cmd_change "$(ask "Node name" "")" "$(ask "Setting to change (port/sni)" port)" "$(ask "New value" "")" ) || true ;;
      6) ( cmd_restart ) || true ;;
      7) cmd_status ;;
      8) cmd_log ;;
      9) ( cmd_doctor ) || true ;;
      10) ( cmd_update ) || true ;;
      11) ( cmd_bbr ) || true ;;
      12) ( cmd_uninstall ) || true ;;
      0|q) exit 0 ;;
      *) warn "invalid choice" ;;
    esac
  done
}

main() {
  local cmd=${1:-}; shift || true
  case $cmd in
    install)        cmd_install "$@" ;;
    add|a)          cmd_add "$@" ;;
    list|ls|l)      cmd_list ;;
    info|i|url)     cmd_info "$@" ;;
    del|rm)         cmd_del "$@" ;;
    change|c)       cmd_change "$@" ;;
    restart)        cmd_restart ;;
    status|s)       cmd_status ;;
    log)            cmd_log "$@" ;;
    doctor|check)   cmd_doctor ;;
    update|u)       cmd_update "$@" ;;
    self-update)    cmd_self_update ;;
    bbr)            cmd_bbr ;;
    uninstall)      cmd_uninstall ;;
    version|v)      echo "sbx $SBX_VER" ;;
    ""|menu)        if is_tty; then menu; else usage; fi ;;
    help|-h|--help) usage ;;
    *) die "unknown command: $cmd (try: sbx help)" ;;
  esac
}
# allow sourcing (used by the tests); main runs only when executed directly
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi
