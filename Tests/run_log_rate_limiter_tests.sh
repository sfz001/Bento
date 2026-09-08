#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc "$ROOT/Sources/LogRateLimiter.swift" "$ROOT/Tests/LogRateLimiterTests.swift" -o "$TEST_DIR/LogRateLimiterTests"
"$TEST_DIR/LogRateLimiterTests"
