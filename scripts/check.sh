#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
forge_bin="${FORGE_BIN:-forge}"
python3 scripts/verify-asf.py
"$forge_bin" --version
npm ci --ignore-scripts --no-audit --no-fund
"$forge_bin" fmt --check
"$forge_bin" build --sizes --skip test
"$forge_bin" test --fuzz-seed 0x20261026 -vv
