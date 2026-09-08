#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
"$ROOT/build_app.sh" --check
for test in "$ROOT"/Tests/run_*_tests.sh; do
    [ "$(basename "$test")" = "run_all_tests.sh" ] && continue
    echo "Running $(basename "$test")"
    "$test"
done
