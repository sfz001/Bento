#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc "$ROOT/Sources/TilingGeometry.swift" "$ROOT/Tests/TilingGeometryTests.swift" -o "$TEST_DIR/TilingGeometryTests"
"$TEST_DIR/TilingGeometryTests"
