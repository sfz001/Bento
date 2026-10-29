#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT
mkdir -p "$TEST_DIR/bin" "$TEST_DIR/project/Scripts" "$TEST_DIR/project/Tests" "$TEST_DIR/project/Bento.app"
cp "$ROOT/build_app.sh" "$TEST_DIR/project/build_app.sh"
cp "$ROOT/Scripts/build_signing.sh" "$TEST_DIR/project/Scripts/build_signing.sh"
printf 'original app\n' > "$TEST_DIR/project/Bento.app/keep"
printf 'fixture leaf certificate\n' > "$TEST_DIR/certificate"
CERT_HASH="$(shasum -a 1 "$TEST_DIR/certificate" | cut -d ' ' -f 1 | tr '[:lower:]' '[:upper:]')"
OTHER_HASH=1111111111111111111111111111111111111111
APPLE_NAME='Apple Development: Fixture (TEAM123456)'
export APP_BUNDLE="$TEST_DIR/project/Bento.app"
export LOCAL_CODESIGN_NAME='Bento Local Code Signing'
export BENTO_SIGNING_FIXTURE_DIR="$TEST_DIR"
export BENTO_SIGNING_FIXTURE_AUTHORITY="$APPLE_NAME"
export PATH="$TEST_DIR/bin:$PATH"
unset BENTO_CODESIGN_IDENTITY

cat > "$TEST_DIR/bin/codesign" <<'SH'
#!/bin/bash
printf 'codesign %s\n' "$*" >> "$BENTO_SIGNING_FIXTURE_DIR/calls"
if [ "$1" = '--verify' ]; then exit "${BENTO_SIGNING_FIXTURE_VERIFY_ERROR:-0}"; fi
if [ "$1" = '-d' ]; then
    while [ "$#" -gt 0 ]; do
        if [[ "$1" = --extract-certificates=* ]]; then
            if [ "${BENTO_SIGNING_FIXTURE_NO_CERT:-0}" != 1 ]; then
                cp "$BENTO_SIGNING_FIXTURE_DIR/certificate" "${1#--extract-certificates=}0"
            fi
            break
        fi
        shift
    done
    printf 'Authority=%s\nCodeDirectory flags=0x10000(runtime)\n' "$BENTO_SIGNING_FIXTURE_AUTHORITY" >&2
    exit 0
fi
exit 98
SH
cat > "$TEST_DIR/bin/security" <<'SH'
#!/bin/bash
printf 'security %s\n' "$*" >> "$BENTO_SIGNING_FIXTURE_DIR/calls"
[ "$*" = 'find-identity -v -p codesigning' ] || exit 98
[ "${BENTO_SIGNING_FIXTURE_SECURITY_ERROR:-0}" = 0 ] || exit 1
cat "$BENTO_SIGNING_FIXTURE_DIR/identities"
SH
cat > "$TEST_DIR/bin/clang" <<'SH'
#!/bin/bash
printf 'clang\n' >> "$BENTO_SIGNING_FIXTURE_DIR/calls"
exit 77
SH
cat > "$TEST_DIR/bin/swiftc" <<'SH'
#!/bin/bash
printf 'swiftc\n' >> "$BENTO_SIGNING_FIXTURE_DIR/calls"
SH
cat > "$TEST_DIR/project/Tests/run_all_tests.sh" <<'SH'
#!/bin/bash
printf 'test-dispatch\n' >> "$BENTO_SIGNING_FIXTURE_DIR/calls"
SH
chmod +x "$TEST_DIR/bin/"* "$TEST_DIR/project/Tests/run_all_tests.sh"

cat > "$TEST_DIR/select.sh" <<'SH'
#!/bin/bash
set -euo pipefail
source "$BENTO_SIGNING_FIXTURE_DIR/project/Scripts/build_signing.sh"
ensure_local_codesign_identity() { printf 'create-local\n' >> "$BENTO_SIGNING_FIXTURE_DIR/calls"; }
unlock_existing_local_codesign_identity() {
    printf 'unlock-local\n' >> "$BENTO_SIGNING_FIXTURE_DIR/calls"
    return "${BENTO_SIGNING_FIXTURE_UNLOCK_ERROR:-0}"
}
bento_select_codesign_identity
printf 'SELECTED=%s\nRUNTIME=%s\n' "$CODESIGN_IDENTITY" "$CODESIGN_PRESERVE_RUNTIME"
SH

fail() { echo "FAIL: $*" >&2; cat "$TEST_DIR/output" >&2; exit 1; }
identity() { printf '  1) %s "%s"%s\n' "$1" "$2" "${3:-}"; }
run_selection() {
    local expected="$1" result=0
    : > "$TEST_DIR/calls"
    bash "$TEST_DIR/select.sh" > "$TEST_DIR/output" 2>&1 || result=$?
    [ "$result" = "$expected" ] || fail "selection returned $result, expected $expected"
}
assert_call() { grep -q "$1" "$TEST_DIR/calls" || fail "missing call: $1"; }
assert_no_call() { if grep -q "$1" "$TEST_DIR/calls"; then fail "unexpected call: $1"; fi; }
assert_selected() { grep -q "SELECTED=$1" "$TEST_DIR/output" || fail "wrong signing identity"; }

# Exact installed certificate wins over another certificate with the same name.
{
    identity "$OTHER_HASH" "$APPLE_NAME"
    identity "$CERT_HASH" "$APPLE_NAME"
} > "$TEST_DIR/identities"
run_selection 0
assert_selected "$CERT_HASH"
grep -q 'RUNTIME=1' "$TEST_DIR/output" || fail 'installed runtime not preserved'
assert_no_call 'create-local\|unlock-local'

# No fallback for missing keys, revoked identities, invalid signatures or ad-hoc apps.
identity "$OTHER_HASH" "$LOCAL_CODESIGN_NAME" > "$TEST_DIR/identities"
run_selection 1
assert_no_call 'create-local\|unlock-local'
identity "$CERT_HASH" "$APPLE_NAME" ' (CSSMERR_TP_CERT_REVOKED)' > "$TEST_DIR/identities"
run_selection 1
identity "$CERT_HASH" "$APPLE_NAME" > "$TEST_DIR/identities"
export BENTO_SIGNING_FIXTURE_VERIFY_ERROR=1
run_selection 1
assert_no_call security
unset BENTO_SIGNING_FIXTURE_VERIFY_ERROR
export BENTO_SIGNING_FIXTURE_NO_CERT=1
run_selection 1
assert_no_call security
unset BENTO_SIGNING_FIXTURE_NO_CERT
export BENTO_SIGNING_FIXTURE_SECURITY_ERROR=1
run_selection 1
unset BENTO_SIGNING_FIXTURE_SECURITY_ERROR

# Explicit choice may replace the existing identity; matching is exact and unique.
export BENTO_CODESIGN_IDENTITY="$APPLE_NAME"
identity "$OTHER_HASH" "$APPLE_NAME" > "$TEST_DIR/identities"
run_selection 0
assert_selected "$OTHER_HASH"
assert_no_call '^codesign '
identity "$CERT_HASH" "$APPLE_NAME" >> "$TEST_DIR/identities"
run_selection 1
export BENTO_CODESIGN_IDENTITY="$OTHER_HASH"
run_selection 0
assert_selected "$OTHER_HASH"
export BENTO_CODESIGN_IDENTITY='Apple Development: Fixture'
run_selection 1
export BENTO_CODESIGN_IDENTITY=''
run_selection 1
unset BENTO_CODESIGN_IDENTITY

# Installed local identity only unlocks; it must not generate a replacement key.
export BENTO_SIGNING_FIXTURE_AUTHORITY="$LOCAL_CODESIGN_NAME"
identity "$CERT_HASH" "$LOCAL_CODESIGN_NAME" > "$TEST_DIR/identities"
run_selection 0
assert_selected "$CERT_HASH"
assert_call unlock-local
assert_no_call create-local
export BENTO_SIGNING_FIXTURE_UNLOCK_ERROR=1
run_selection 1
assert_no_call create-local
unset BENTO_SIGNING_FIXTURE_UNLOCK_ERROR

# A first build keeps the local default; an explicit local choice remains supported.
mv "$APP_BUNDLE" "$TEST_DIR/saved.app"
run_selection 0
assert_call create-local
assert_selected "$CERT_HASH"
mv "$TEST_DIR/saved.app" "$APP_BUNDLE"
export BENTO_CODESIGN_IDENTITY="$LOCAL_CODESIGN_NAME"
run_selection 0
assert_call create-local
assert_no_call '^codesign '
unset BENTO_CODESIGN_IDENTITY

# Exercise the real build script entry points: checks never query certificates;
# an unavailable original signer fails before compilation or old-bundle deletion.
: > "$TEST_DIR/calls"
bash "$TEST_DIR/project/build_app.sh" --check > "$TEST_DIR/output" 2>&1 || fail '--check'
assert_call swiftc
assert_no_call '^codesign\|^security'
: > "$TEST_DIR/calls"
bash "$TEST_DIR/project/build_app.sh" --test > "$TEST_DIR/output" 2>&1 || fail '--test'
assert_call test-dispatch
assert_no_call '^codesign\|^security'
export BENTO_SIGNING_FIXTURE_AUTHORITY="$APPLE_NAME"
identity "$OTHER_HASH" "$APPLE_NAME" > "$TEST_DIR/identities"
: > "$TEST_DIR/calls"
if bash "$TEST_DIR/project/build_app.sh" > "$TEST_DIR/output" 2>&1; then fail 'missing signer accepted'; fi
assert_no_call clang
[ "$(cat "$APP_BUNDLE/keep")" = 'original app' ] || fail 'old app was modified'
identity "$CERT_HASH" "$APPLE_NAME" > "$TEST_DIR/identities"
: > "$TEST_DIR/calls"
result=0
bash "$TEST_DIR/project/build_app.sh" > "$TEST_DIR/output" 2>&1 || result=$?
[ "$result" = 77 ] || fail 'valid signer did not reach compiler'
assert_call clang
[ "$(cat "$APP_BUNDLE/keep")" = 'original app' ] || fail 'preflight modified old app'
echo 'PASS: build preserves exact signer, rejects unavailable/revoked/ambiguous identities before replacement, and bypasses signing for checks/tests'
