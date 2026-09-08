#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT
sources=()
for source in "$ROOT"/Sources/*.swift; do
    [ "$(basename "$source")" = "main.swift" ] || sources+=("$source")
done
clang -c "$ROOT/Sources/CrashSignal.c" -o "$TEST_DIR/CrashSignal.o"
swiftc -D BENTO_TESTS "${sources[@]}" "$ROOT/Tests/AppDelegateStateTests.swift" "$TEST_DIR/CrashSignal.o" \
    -o "$TEST_DIR/AppDelegateStateTests" -framework AppKit -framework CoreGraphics -framework IOKit
BENTO_TEST_LOG_DIR="$TEST_DIR/logs" "$TEST_DIR/AppDelegateStateTests"
