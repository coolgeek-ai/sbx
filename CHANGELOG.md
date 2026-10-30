# Changelog

Format based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow SemVer.
`SBX_VER` in `sbx.sh` must match the latest entry; CI checks this.

## [1.0.1] - 2026-10-28
### Added
- One-line install: `bash <(wget -qO- -o- https://github.com/coolgeek-ai/sbx/raw/main/sbx.sh) install`; the `sbx` command is installed even when the script is read from a pipe

### Fixed
- Leaving the node name empty (= all nodes) in the menu's "show link" action reported "node not found"; `sbx info ""` now lists every node
- Any failing menu action (`die`) used to exit the whole menu; each action now runs in a subshell
- `sbx change <name> port` did not open the local firewall (ufw / firewalld); it now opens the port and reminds you about the cloud security group
- Deleting a node or rolling back a failed creation could remove a domain certificate directory with the same name as the node; self-signed certificates now live in `certs/_self/<node-name>`
- Trojan / VLESS-WS defaulted to a random port, which contradicted "CDN-compatible"; port 443 is now preferred, and VLESS-WS warns when the port is not one Cloudflare can proxy
- The ACME log no longer uses the fixed path `/tmp/sbx-acme.log` (uses `mktemp` instead)

### Tests
- Added `tests/link2xray.py`: parses the real share links produced by the script following the v2rayNG 2.3.14 source, converts them to Xray outbounds, and connects to a real sing-box server; covers REALITY / Hy2 / SS-2022 / Trojan / VLESS-WS (previously Trojan and VLESS-WS were only checked with `sing-box check`)
- Added 4 regression tests (empty info name, port change firewall opening, certificate directory isolation, menu error tolerance), confirmed to fail on 1.0.0

## [1.0.0] - 2026-10-28
### Added
- Protocols: VLESS+REALITY+Vision, Hysteria2, Shadowsocks-2022, Trojan+TLS, VLESS+WS+TLS
- Nodes are stored as JSON and `config.json` is generated from them; `sing-box check` runs before applying and failures roll back automatically
- Self-signed certificates with `pinSHA256` fingerprint pinning (replacing `allowInsecure`, which Xray removed); acme.sh + Let's Encrypt when a domain is used
- `doctor` self-check, `change`, `update` (core, with rollback on failure), `self-update` (SHA256 verified), BBR
- Tests: config / link / policy checks; end-to-end real Xray-core client ↔ sing-box server (REALITY, Hy2-pin, SS-2022) plus regression sentinels (Xray rejects plaintext VLESS on public addresses / rejects allowInsecure)
- CI, daily compat-watch (latest-core tests + upstream release notices), tag-based release workflow

### Compatibility basis
See docs/COMPATIBILITY.md. Tested cores: sing-box 1.14.4, Xray-core 26.10.21.
