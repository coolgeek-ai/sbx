# Compatibility

> Principle: every conclusion comes either from a **real end-to-end test in CI** or from **upstream material with a link**, and says clearly which of the two it is.
> If you find something inaccurate, please open an issue or pull request.

## 1. Tested combinations (CI end-to-end, see `tests/test_e2e.sh`)

| Server | Client core | REALITY+Vision | Hysteria2 (self-signed, pin only) | SS-2022 | Regression sentinels |
|---|---|---|---|---|---|
| sing-box 1.14.4 | Xray-core 26.10.21 | ✔ chrome / firefox | ✔ | ✔ (Xray prints a deprecation notice) | ✔ plaintext VLESS on a public IP is rejected; ✔ `allowInsecure` is rejected (even together with a pin) |

Measured Hysteria2 matrix on Xray 26.10.21 (self-signed certificate): `pinnedPeerCertSha256` only → **works**; `allowInsecure` + pin → **the core refuses to start**; `allowInsecure` only → refuses to start; neither → handshake fails. That is why links carry only `pinSHA256` and never `insecure=1`.

The currently pinned versions are in `compat/known-good.json`; they are re-tested daily against the latest releases.
v2rayN / v2rayNG use Xray-core as the core for these protocols, so the table above covers their network layer; **link parsing / import in the GUIs** is not covered by CI, see section 3.

## 2. Upstream change timeline (changes that shaped this project's design)

| Date / version | Change | Impact on sbx | Source |
|---|---|---|---|
| Xray v26.2.6 (2026-02) | TLS `allowInsecure` removed in favor of `pinnedPeerCertSha256`; a warning is printed on every start from then on | Self-signed certificates always produce `pinSHA256`, never `insecure=1` | [v2rayN #10156](https://github.com/2dust/v2rayN/issues/10156), [Xray #6247](https://github.com/XTLS/Xray-core/issues/6247) |
| 2026-06-01 | A config with `allowInsecure=true` and no pin → the core **cannot start** (Hysteria/Hysteria2 nodes were hit first) | Same as above | [v2rayN #9435](https://github.com/2dust/v2rayN/issues/9435), [v2rayN #9460](https://github.com/2dust/v2rayN/discussions/9460) |
| 2026-08-01 | Xray disables `allowInsecure` completely; from v2rayN 7.22.x a warning (the red notice) appears in the node list | Same as above | [v2rayN releases](https://github.com/2dust/v2rayN/releases/), [v2rayN #9868](https://github.com/2dust/v2rayN/discussions/9868) |
| Xray 26.3.27 | A newly created REALITY **inbound** without `minClientVer` defaults to the server's own version (older clients get silently redirected to the camouflage site) | Affects **Xray servers** only; sing-box servers are unaffected (third-party article, not independently reproduced) | [ProfitServer guide](https://profitserver.net/knowledge-base/xray-vless-reality-server-setup/) |
| Xray ≥ 26.7 (observed on 26.7.11) | VLESS on a public address without TLS / REALITY / VLESS-Encryption → config build fails: `vless without TLS or other encryption is prohibited unless the server address is a private IP or domain`; from 26.9.9 Trojan without TLS is rejected as well | Never generate unencrypted VLESS/Trojan; node links must carry explicit `security=` and `encryption=none` | [Xray #6484](https://github.com/XTLS/Xray-core/issues/6484), [Xray #6600](https://github.com/XTLS/Xray-core/issues/6600), [xray-knife v11.4.0](https://github.com/lilendian0x00/xray-knife/releases/tag/v11.4.0) |
| v2rayNG 2.3.2 | Same error reported; the reporter believes v2rayNG validates on its own | Same as above | [v2rayNG #6029](https://github.com/2dust/v2rayNG/issues/6029) |
| Xray v26.9.8 | The REALITY handshake requires the ClientHello to contain an X25519MLKEM768 key share; **sing-box clients** using the uTLS `chrome` fingerprint are rejected (Xray clients are unaffected); there are also reports about the `qq` fingerprint | This project's server is sing-box and its clients use the Xray core, so it is outside the affected topology; take care if you use sing-box as the **client** against an Xray server | [sing-box #4520](https://github.com/SagerNet/sing-box/issues/4520), [Xray #7144](https://github.com/XTLS/Xray-core/discussions/7144) |
| sing-box 1.12 / 1.13 / 1.14 | Legacy special outbounds (removed in 1.13), legacy DNS servers (removed in 1.14), inline ACME deprecated (1.14), and more | The generated config contains only `log / inbounds / outbounds(direct)` and certificates are referenced by file path | [Migration](https://sing-box.sagernet.org/migration/) |
| Xray 26.10.21 (measured) | The log prints a deprecation notice for Shadowsocks outbounds and suggests migrating to VLESS Encryption | SS-2022 is a fallback only; the README and the menu say so | `tests/test_e2e.sh` log of this project |

### Protocols that are not included, and why

| Protocol | Reason |
|---|---|
| TUIC / AnyTLS | v2rayNG uses the Xray core, which does not support them; v2rayN would have to switch to the sing-box core, and there is no reliable tested basis for the share-link parameters |
| XHTTP | As of the last review, upstream sing-box provides no server side; a community fork has only a client-side implementation ([sing-box-lx](https://github.com/Leadaxe/sing-box-lx)) |
| VLESS Encryption (ML-KEM) | Xray's recommended replacement for plaintext VLESS; no server-side support has been seen in upstream sing-box (the same fork states it ported only the client side: "decryption is server-side and deliberately not ported") |

These conclusions change as upstream changes; an issue opened by `compat-watch` triggers a re-evaluation (see MAINTAINING.md).

## 3. Client (GUI) compatibility report

The review has two layers, and **neither runs the GUI**:
- **Source review:** reading the link parsing (`VLESSFmt` / `Hysteria2Fmt` / `TrojanFmt` / `ShadowsocksFmt` / `FmtBase`) and outbound construction in v2rayN master (57f17d5) and v2rayNG master (aa4b055, 2.3.14), and `validateOutboundTransportSecurity` in Xray master (1576e79).
- **Core e2e:** `tests/link2xray.py` follows the v2rayNG parsing rules (a Python re-implementation, not its actual code), converts the real links produced by the script into Xray outbounds, and connects to a real sing-box server. v2rayN (C#) is reviewed from source only and is not executed.

| Client | Version | Method | reality | hy2 (pin) | hy2 (real cert) | trojan | vless-ws | ss2022 |
|---|---|---|---|---|---|---|---|---|
| v2rayNG | 2.3.14 (master) | source + core e2e | ✔ | ✔ | source | ✔ (pin instead of CA) | ✔ (pin instead of CA) | ✔ |
| v2rayN | 7.25.x (master) | source only | source | source | source | source | source | source |

`✔` = the Xray config produced from the link by the parsing rules connects on a real core; `source` = the parsing code was read but not executed. In the tests Trojan / VLESS-WS use a self-signed certificate plus a pin instead of a CA certificate, so they verify the server's TLS/WS wiring and the link parameters, not ACME. GUI test results are welcome through the client compatibility report template.

Client behavior verified from source:
- v2rayNG shows the red allowInsecure warning only when `insecure==true` and the fingerprint is empty; when building the Xray config it sets `allowInsecure = insecure && fingerprint is empty`. sbx Hy2 links carry no `insecure`, so the warning is not triggered.
- v2rayNG keeps only `security=tls|reality` and blanks anything else; with a blank value and a public-IP server, Xray reports `vless without TLS ... prohibited`.
- v2rayNG's `getQueryParam` does `split("=")` on each parameter and takes the first two parts, so a value containing `=` is truncated; no sbx link parameter value contains `=` (the REALITY public key is unpadded base64url).
- When importing Hy2, v2rayN clears `alpn` and, if `pinSHA256` is present, sets AllowInsecure automatically; for the Xray core the generated config contains only `pinnedPeerCertSha256` and no allowInsecure.
- Xray's `pinnedPeerCertSha256` was measured to accept both forms: uppercase with colons and lowercase without colons.

Client behavior known from upstream discussions (not measured by this project):
- For Hysteria2 links that carry `pinSHA256`, v2rayN adds `allowInsecure` automatically under the sing-box core and passes only the fingerprint under the Xray core ([v2rayN PR #10434 discussion](https://github.com/2dust/v2rayN/pull/10434)).
- [v2rayN #10433](https://github.com/2dust/v2rayN/issues/10433) (mid-2026-10): a user reports that when a Hysteria2 link carries only `pinSHA256` and no `insecure=1`, v2rayN ticks AllowInsecure automatically and the handshake fails (server log: `bad certificate`). The fix PR #10434 was closed by the author on the grounds that v2rayN removes allowInsecure for the Xray core when a fingerprint exists and keeps it for the sing-box core (needed for self-signed certificates). **The root cause is not settled**; if you run into it, see TROUBLESHOOTING §1.
- Other non-Xray clients (sing-box based ones, Hiddify, the official Hysteria2 client) usually need `insecure=1` together with `pinSHA256` for a self-signed Hysteria2 certificate; for such clients, add `&insecure=1` manually before the `#` at the end of the link. **Do not import a link containing `insecure=1` into v2rayN/v2rayNG** (the Xray core rejects it).
- A user reports that the same REALITY node fails under the Xray core but works after switching to the sing-box core (specific region/network, root cause not identified) ([v2rayN #9567](https://github.com/2dust/v2rayN/discussions/9567)).
