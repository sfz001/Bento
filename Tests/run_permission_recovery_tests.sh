#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc -module-cache-path "$TEST_DIR/modules" \
    "$ROOT/Sources/PermissionRecovery.swift" \
    "$ROOT/Tests/PermissionRecoveryTests.swift" \
    -target arm64-apple-macosx14.0 \
    -o "$TEST_DIR/PermissionRecoveryTests" \
    -framework AppKit -framework Security
"$TEST_DIR/PermissionRecoveryTests"
