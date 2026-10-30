#!/usr/bin/env bash
set -uo pipefail
cd "$(dirname "$0")" || exit 1
rc=0
bash test_config.sh || rc=1
echo
bash test_e2e.sh || rc=1
exit $rc
