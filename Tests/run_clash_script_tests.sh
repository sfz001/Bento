#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc "$ROOT/ClaudeGuard/ClashMerge.swift" \
    "$ROOT/Tests/ClashScriptTests.swift" \
    -module-cache-path "$TEST_DIR/ModuleCache" \
    -target arm64-apple-macosx14.0 -framework JavaScriptCore \
    -o "$TEST_DIR/ClashScriptTests"
"$TEST_DIR/ClashScriptTests"
