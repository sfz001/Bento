#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT
clang -std=c11 -Wall -Wextra -Werror "$ROOT/Sources/CrashSignal.c" "$ROOT/Tests/CrashSignalTests.c" -o "$TEST_DIR/CrashSignalTests"
python3 - "$TEST_DIR" <<'PY'
import pathlib, signal, subprocess, sys
root = pathlib.Path(sys.argv[1])
for sig in (signal.SIGTRAP, signal.SIGILL, signal.SIGABRT):
    log = root / (sig.name + '.log')
    result = subprocess.run([str(root / 'CrashSignalTests'), str(log), str(sig)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    assert result.returncode == -sig, (sig, result.returncode)
    assert log.read_text() == '[fatal] ' + sig.name + '\n'
print('PASS: fatal markers written and original signal exits preserved')
PY
