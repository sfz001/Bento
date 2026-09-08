#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc "$ROOT/Sources/MenuBarSemantics.swift" "$ROOT/Tests/MenuBarSemanticsTests.swift" -o "$TEST_DIR/MenuBarSemanticsTests"
"$TEST_DIR/MenuBarSemanticsTests"
