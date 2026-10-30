# shellcheck shell=bash
# Shared test helpers
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
BINDIR="$ROOT/tests/.bin"
export SBX_TEST=1 SBX_YES=1 SBX_IP=127.0.0.1
export SBX_BIN="$BINDIR/sing-box"
WORK=$(mktemp -d); export SBX_ETC="$WORK/etc"
PIDS=()
cleanup() { local p; for p in "${PIDS[@]:-}"; do if [[ -n $p ]]; then kill "$p" 2>/dev/null || true; fi; done; rm -rf "$WORK"; }
trap cleanup EXIT
PASS=0; FAIL=0
ok()   { echo "  ✔ $*"; PASS=$((PASS+1)); }
bad()  { echo "  ✘ $*"; FAIL=$((FAIL+1)); }
assert_contains()     { if grep -q -- "$2" <<<"$1"; then ok "$3"; else bad "$3  (missing: $2)"; fi; }
assert_not_contains() { if grep -q -- "$2" <<<"$1"; then bad "$3  (unexpected: $2)"; else ok "$3"; fi; }
finish() { echo; echo "passed $PASS, failed $FAIL"; [[ $FAIL -eq 0 ]]; }
require_bins() { [[ -x $SBX_BIN && -x $BINDIR/xray ]] || { echo "test cores are missing; run tests/fetch-cores.sh first"; exit 2; }; }
sbx() { bash "$ROOT/sbx.sh" "$@"; }
