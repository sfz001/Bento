#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc "$ROOT/Sources/ScreenController.swift" "$ROOT/Tests/MirrorRestoreTests.swift" \
    -o "$TEST_DIR/BentoMirrorRestoreTests" -framework AppKit -framework CoreGraphics
"$TEST_DIR/BentoMirrorRestoreTests"
