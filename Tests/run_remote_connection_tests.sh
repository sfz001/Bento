#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc "$ROOT/Sources/RemoteConnectionProbe.swift" "$ROOT/Tests/RemoteConnectionTests.swift" -o "$TEST_DIR/RemoteConnectionTests" -framework AppKit
"$TEST_DIR/RemoteConnectionTests"
