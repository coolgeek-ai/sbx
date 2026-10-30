# Architecture

```
sbx.sh
 ├─ node storage   /etc/sing-box/nodes/<name>.json      (single source of truth, mode 600)
 ├─ certificates   /etc/sing-box/certs/<name|domain>/
 ├─ generate       inbound_json(node) ─► build_config() ─► config.json.new
 ├─ validate       sing-box check -c config.json.new    (failure → discard, keep the old config)
 ├─ apply          mv → systemctl restart → is-active   (failure → caller rolls the node back and rebuilds)
 └─ link           node_link(node)  (every parameter explicit)
```

## Why "node JSON → generated config" instead of editing config.json directly

- The information a link needs (public key, short id, fingerprint, path) is not the same data as the sing-box configuration (for example the private key lives in the server config while the public key only appears in the link). Storing nodes separately lets links be regenerated at any time.
- When a sing-box upgrade changes a field, only `inbound_json` needs to change and every existing node migrates automatically.

## Node fields

| type | fields |
|---|---|
| reality | uuid, priv, pub, sid, sni |
| hysteria2 | pass, cert, key, sni, domain (may be empty), pin (self-signed only) |
| ss2022 | method, pass |
| trojan | pass, domain, cert, key |
| vless-ws | uuid, domain, path, cert, key |

## Test mode

`SBX_TEST=1` skips the root check, systemd, and the firewall; `SBX_ETC`, `SBX_BIN`, and `SBX_IP` override paths and the IP.
The script can be `source`d (`main` only runs when it is executed directly), which lets the tests call internal functions.

## Adding a protocol

1. Add an alias in `norm_type` and a menu entry in `pick_type`
2. Add a `case` branch in `cmd_add` and store the fields with `node_save`
3. Add a branch in `inbound_json` (only fields the current sing-box still supports)
4. Add a branch in `node_link` (**explicit parameters**)
5. Set the protocol type (tcp/udp/both) used by `open_port`
6. Tests + docs + CHANGELOG (see CONTRIBUTING)
