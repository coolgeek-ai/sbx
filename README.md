# sbx

One-click sing-box **server** deployment and management script for the **latest v2rayN / v2rayNG**.

> **Why it exists:** during 2026 Xray-core tightened its rules several times: `allowInsecure` was removed, plaintext VLESS on public addresses is now rejected, and the REALITY handshake requirements changed. Links produced by older one-click scripts started to fail or show errors in current clients.
> sbx only generates configurations that current clients still accept. Key behaviors are verified by **end-to-end tests between a real Xray-core client and a real sing-box server**, every other claim links to its upstream source, and the tests re-run automatically as upstream releases change.

## Supported protocols

| Command | Protocol | Domain needed | v2rayN | v2rayNG | Notes |
|---|---|---|---|---|---|
| `reality` | VLESS + REALITY + Vision | No | ✔ | ✔ | **Recommended** |
| `hy2` | Hysteria2 (QUIC/UDP) | No | ✔ | ✔ | Without a domain: self-signed certificate with `pinSHA256` fingerprint pinning. With a domain: Let's Encrypt |
| `trojan` | Trojan + TLS | Yes | ✔ | ✔ | Certificate issued and renewed automatically by acme.sh |
| `ws` | VLESS + WS + TLS | Yes | ✔ | ✔ | Can sit behind a CDN |
| `ss` | Shadowsocks-2022 | No | ✔ | ✔ | Marked deprecated in Xray; fallback only |

**Deliberately not provided:** TUIC / AnyTLS (the Xray core used by v2rayNG does not support them), XHTTP (upstream sing-box has no server-side implementation as of the last review), and any VLESS/Trojan without TLS or REALITY (current Xray rejects them outright). Reasons and sources: [docs/COMPATIBILITY.md](docs/COMPATIBILITY.md).

> The ✔ marks are based on a review of the client source code plus end-to-end tests against the real Xray core (the GUIs themselves are not run). See [docs/COMPATIBILITY.md](docs/COMPATIBILITY.md), section 3.

## Quick start

Requirements: Linux with systemd, root access, and access to GitHub.

```bash
bash <(wget -qO- -o- https://github.com/coolgeek-ai/sbx/raw/main/sbx.sh) install
```

This installs sing-box, creates a REALITY node, prints its link and QR code, and installs the `sbx` command. If `wget` is not available, use curl instead:

```bash
bash <(curl -fsSL https://github.com/coolgeek-ai/sbx/raw/main/sbx.sh) install
```

Prefer to inspect or verify the script first? Download a release and check its checksum:

```bash
base=https://github.com/coolgeek-ai/sbx/releases/latest/download
curl -fsSLO "$base/sbx.sh" -O "$base/SHA256SUMS"
sha256sum -c SHA256SUMS --ignore-missing
bash sbx.sh install
```

Afterwards run `sbx` to open the menu, or use the commands directly:

```bash
sbx add reality                          # interactive; or: -p 443 --sni www.microsoft.com -n my-node
sbx add hy2 -p 8443                      # no domain -> self-signed certificate + pinned fingerprint
sbx add trojan -d example.com            # the domain must already resolve to this server and port 80 must be free (acme standalone)
sbx list                                 # list nodes
sbx info [name]                          # link + QR code (when qrencode is installed)
sbx change <name> port 8443              # change the port (or the SNI of a reality node)
sbx del <name>
sbx doctor                               # self-check: syntax / service / ports / certificate expiry / clock sync
sbx update [core-version]                # upgrade sing-box; rolls back automatically if the new version fails to start
sbx self-update                          # upgrade the script itself (verifies SHA256SUMS)
sbx bbr | log [-f] | status | restart | uninstall
```

> On a cloud server you must also open the port in the **security group / cloud firewall** (Hysteria2 uses **UDP**). The script only configures the local ufw / firewalld.

## Migrating from other sing-box scripts

Most other sing-box one-click scripts also use `/etc/sing-box` and `sing-box.service`, so they **cannot coexist** with sbx. sbx detects such an installation and refuses to install.

1. Uninstall with the original script.
2. Run `bash sbx.sh install`.
3. **Delete the old nodes** in your client and import the new links (UUIDs and keys are regenerated).

## Design notes (why it works with current clients)

- **Every link parameter is explicit** (`encryption/flow/security/sni/fp/pbk/sid/type`), so nothing depends on client defaults.
- **No `insecure=1`:** self-signed certificates are pinned with `pinSHA256`. For the sing-box core v2rayN adds insecure by itself; for the Xray core it passes only the fingerprint.
- **No GitHub API dependency** (60 requests/hour unauthenticated, which easily returns 403/429): versions are read from the `releases/latest` redirect.
- **Safe configuration changes:** node JSON → generate `config.json` → `sing-box check` → atomic replace → restart; any failing step rolls back.
- Only fields still supported by sing-box 1.14 are used (no legacy DNS, special outbounds, or inline ACME).

Details: [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## Compatibility and testing

CI runs on every commit and daily (against the **latest** cores):

- Config generation + `sing-box check` + link parameter / policy assertions
- **End-to-end:** Xray-core client → sing-box server, covering REALITY (chrome/firefox fingerprints), Hysteria2 (pin only), and SS-2022
- **Regression sentinels:** confirm that Xray still rejects plaintext VLESS on public addresses. If it ever stops doing so, the tests fail and the conclusions get updated

The v2rayN / v2rayNG GUIs cannot run in CI; they are covered by the Xray-core end-to-end tests plus community compatibility reports, see [docs/COMPATIBILITY.md](docs/COMPATIBILITY.md).
If you have tested a specific client version, please submit it with the **Client compatibility report** issue template.

## Troubleshooting

Causes and fixes for three common errors (`allowInsecure` will be removed / `vless without TLS ... prohibited` / REALITY stops working after a client upgrade): [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md).

## Contributing

```bash
make lint          # bash -n + shellcheck
make test          # download the cores pinned in compat/known-good.json and run all tests
make test-latest   # run against the latest sing-box / Xray-core
```

See [CONTRIBUTING.md](CONTRIBUTING.md) and [docs/MAINTAINING.md](docs/MAINTAINING.md) for adding protocols or adapting to upstream changes.

## Disclaimer

This project is intended for lawful network access and personal learning and research. Comply with the laws of your jurisdiction and the terms of your service providers; use at your own risk. Released under the MIT License.
