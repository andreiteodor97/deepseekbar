#!/bin/bash
#
# Runs the rate/schedule test suite.
#
#   ./test.sh
#
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
BIN="$(mktemp -d)/logic-tests"

swiftc -O -o "$BIN" "$DIR/tools/tests/main.swift" "$DIR/Sources/Pricing.swift"
"$BIN"
