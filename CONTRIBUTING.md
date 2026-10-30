# Contributing

1. Fork → branch → pull request. Every item of the pull request checklist must be ticked.
2. Locally run `make lint && make test`. You need `bash curl jq openssl unzip python3 shellcheck`.
3. **Every compatibility claim needs a source** (an official release note, an issue link, or a reproduction command) recorded in `docs/COMPATIBILITY.md`.
4. A new protocol must come with all of: (1) an `inbound_json` branch, (2) a `node_link` branch, (3) assertions in `tests/test_config.sh`, (4) an end-to-end case in `tests/test_e2e.sh` where possible, (5) an update to the README protocol table and the CHANGELOG.
5. Style: bash 4+, `set -Eeuo pipefail`; no `eval`; validate user input before it reaches the configuration; every path that writes configuration must be reversible.
6. Not accepted: generating unencrypted public VLESS/Trojan, emitting `insecure=1` / `allowInsecure`, or relying on the unauthenticated GitHub API (the tests assert these).
