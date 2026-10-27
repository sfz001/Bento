#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc "$ROOT/Sources/ClaudeGuardProtocol.swift" \
    "$ROOT/ClaudeGuard/ClaudeGuardHosts.swift" \
    "$ROOT/ClaudeGuard/ClaudeGuardEngine.swift" \
    "$ROOT/ClaudeGuard/ClaudeGuardProcess.swift" \
    "$ROOT/ClaudeGuard/ClashProbe.swift" \
    "$ROOT/ClaudeGuard/ClashMerge.swift" \
    "$ROOT/ClaudeGuard/ClaudeGuardDaemon.swift" \
    "$ROOT/Tests/ClaudeGuardTests.swift" \
    -target arm64-apple-macosx14.0 \
    -o "$TEST_DIR/ClaudeGuardTests"
"$TEST_DIR/ClaudeGuardTests"
