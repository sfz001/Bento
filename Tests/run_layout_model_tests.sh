#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc "$ROOT/Sources/LayoutModel.swift" "$ROOT/Tests/LayoutModelTests.swift" -o "$TEST_DIR/LayoutModelTests"
"$TEST_DIR/LayoutModelTests"
