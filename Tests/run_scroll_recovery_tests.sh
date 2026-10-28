#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc -D BENTO_TESTS -module-cache-path "$TEST_DIR/modules" \
    "$ROOT/Sources/ScrollReverser.swift" \
    "$ROOT/Sources/Support.swift" \
    "$ROOT/Sources/LogRateLimiter.swift" \
    "$ROOT/Tests/ScrollRecoveryTests.swift" \
    -target arm64-apple-macosx14.0 \
    -o "$TEST_DIR/ScrollRecoveryTests" \
    -framework AppKit -framework CoreGraphics -framework IOKit
BENTO_TEST_LOG_DIR="$TEST_DIR/logs" "$TEST_DIR/ScrollRecoveryTests"
