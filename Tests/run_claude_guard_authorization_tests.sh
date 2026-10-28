#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# Real anonymous XPC and Security's CodeSigningHelper must be available. Run
# outside execution sandboxes that block those services; never count that
# environment failure as a successful authentication rejection.
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc -module-cache-path "$TEST_DIR/modules" \
    "$ROOT/Sources/ClaudeGuardProtocol.swift" \
    "$ROOT/ClaudeGuard/ClaudeGuardHosts.swift" \
    "$ROOT/ClaudeGuard/ClaudeGuardEngine.swift" \
    "$ROOT/ClaudeGuard/ClaudeGuardProcess.swift" \
    "$ROOT/ClaudeGuard/ClashProbe.swift" \
    "$ROOT/ClaudeGuard/ClashMerge.swift" \
    "$ROOT/ClaudeGuard/ClaudeGuardDaemon.swift" \
    "$ROOT/Tests/ClaudeGuardAuthorizationTests.swift" \
    -target arm64-apple-macosx14.0 \
    -o "$TEST_DIR/ClaudeGuardAuthorizationTests"
codesign --force --sign - --identifier com.sz.bento.authorization-tests "$TEST_DIR/ClaudeGuardAuthorizationTests"
"$TEST_DIR/ClaudeGuardAuthorizationTests"
