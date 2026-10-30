# Maintenance: how the project keeps up with upstream

## What is automated

| Mechanism | Frequency | Purpose |
|---|---|---|
| `ci.yml` | every push / PR | lint + run all tests with the core versions recorded in `compat/known-good.json` |
| `compat-watch / latest-cores` | daily | run all tests with the **latest** sing-box + Xray-core; a failure opens a `compat-break` issue automatically |
| `compat-watch / upstream-watch` | daily | when sing-box / Xray-core / v2rayN / v2rayNG publish a new version, open an `upstream-update` issue (with a checklist, deduplicated per version) |
| `release.yml` | on tag | verify tag == `SBX_VER` → test → publish `sbx.sh` + `SHA256SUMS` |
| dependabot | weekly | update GitHub Actions versions |

## Handling a `compat-break` issue

1. Read the failure log in the issue and reproduce locally with `make test-latest`.
2. Work out what changed:
   - **A sing-box server field changed** → update `inbound_json`; see <https://sing-box.sagernet.org/migration/>
   - **Xray client behavior changed** (an end-to-end case fails) → first check whether it is an intended security tightening; if so, adjust `node_link` or the protocol policy and add a row (with a source) to the timeline in `docs/COMPATIBILITY.md`
   - **A regression sentinel failed** (Xray no longer rejects plaintext VLESS on public addresses) → good news; the script does not need to change, but update the docs and set the sentinel to the new expectation
3. Fix → update `compat/known-good.json` → CHANGELOG → publish a patch release.

## Handling an `upstream-update` issue

- sing-box / Xray-core: check whether the same day's compat-watch passed; read the release notes for entries about the server, links, TLS, or REALITY.
- v2rayN / v2rayNG: CI cannot run a GUI. Import the link for each protocol by hand, record the result in the client table of `docs/COMPATIBILITY.md`, and update the `reviewed` version in `known-good.json`.

## When new protocols or parameters are accepted

A protocol or parameter is added only if all of these hold:

1. The latest v2rayN **and** v2rayNG can both import and use it (someone has tested it, or their source/documentation clearly supports it)
2. An end-to-end test can be written (an Xray or sing-box client against a sing-box server)
3. It does not depend on a feature upstream has announced as deprecated

Currently excluded and under observation: **VLESS Encryption (ML-KEM)** and **XHTTP** (upstream sing-box has no server-side implementation as of the last review; see COMPATIBILITY.md), and **TUIC / AnyTLS** (not supported by the Xray core in v2rayNG). They are re-evaluated when the upstream situation changes.
