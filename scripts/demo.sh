#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
forge_bin="${FORGE_BIN:-forge}"
"$forge_bin" test --match-test testDemo_TwoMarketsShareTenReportAdmissions -vv
