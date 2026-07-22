#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="Bento"
BUNDLE_ID="com.sz.bento"
APP_BUNDLE="$SCRIPT_DIR/$APP_NAME.app"
LOCAL_CODESIGN_NAME="Bento Local Code Signing"
LOCAL_CODESIGN_DIR="$SCRIPT_DIR/.bento-codesign"
LOCAL_CODESIGN_KEYCHAIN="$HOME/Library/Keychains/BentoLocalCodeSigning.keychain-db"
LOCAL_CODESIGN_PASSWORD="bento-local-codesign"
LOCAL_CODESIGN_P12_PASSWORD="bento-local-p12"

ensure_codesign_keychain_visible() {
    local found=false
    local keychains=()
    local line

    while IFS= read -r line; do
        line="${line//\"/}"
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"
        [ -n "$line" ] || continue
        keychains+=("$line")
        [ "$line" = "$LOCAL_CODESIGN_KEYCHAIN" ] && found=true
    done < <(security list-keychains -d user 2>/dev/null || true)

    if [ "${#keychains[@]}" -eq 0 ]; then
        keychains=("$HOME/Library/Keychains/login.keychain-db")
    fi

    if [ "$found" != true ]; then
        keychains+=("$LOCAL_CODESIGN_KEYCHAIN")
        security list-keychains -d user -s "${keychains[@]}"
    fi
}

ensure_local_codesign_identity() {
    mkdir -p "$LOCAL_CODESIGN_DIR"

    if security find-identity -v -p codesigning "$LOCAL_CODESIGN_KEYCHAIN" 2>/dev/null | grep -q "$LOCAL_CODESIGN_NAME"; then
        security unlock-keychain -p "$LOCAL_CODESIGN_PASSWORD" "$LOCAL_CODESIGN_KEYCHAIN" >/dev/null 2>&1 || true
        ensure_codesign_keychain_visible
        return
    fi

    echo "Creating local code-signing identity..."
    rm -f \
        "$LOCAL_CODESIGN_DIR/BentoLocal.crt" \
        "$LOCAL_CODESIGN_DIR/BentoLocal.key" \
        "$LOCAL_CODESIGN_DIR/BentoLocal.p12"
    security delete-keychain "$LOCAL_CODESIGN_KEYCHAIN" >/dev/null 2>&1 || rm -f "$LOCAL_CODESIGN_KEYCHAIN"

    openssl req \
        -x509 \
        -newkey rsa:2048 \
        -nodes \
        -days 3650 \
        -sha256 \
        -subj "/CN=$LOCAL_CODESIGN_NAME" \
        -addext "basicConstraints=critical,CA:FALSE" \
        -addext "keyUsage=critical,digitalSignature" \
        -addext "extendedKeyUsage=codeSigning" \
        -keyout "$LOCAL_CODESIGN_DIR/BentoLocal.key" \
        -out "$LOCAL_CODESIGN_DIR/BentoLocal.crt"

    # Legacy PBE/MAC algorithms: OpenSSL 3.x defaults produce a p12 that
    # `security import` rejects with "MAC verification failed".
    openssl pkcs12 \
        -export \
        -certpbe PBE-SHA1-3DES \
        -keypbe PBE-SHA1-3DES \
        -macalg sha1 \
        -out "$LOCAL_CODESIGN_DIR/BentoLocal.p12" \
        -inkey "$LOCAL_CODESIGN_DIR/BentoLocal.key" \
        -in "$LOCAL_CODESIGN_DIR/BentoLocal.crt" \
        -passout "pass:$LOCAL_CODESIGN_P12_PASSWORD"

    security create-keychain -p "$LOCAL_CODESIGN_PASSWORD" "$LOCAL_CODESIGN_KEYCHAIN"
    security unlock-keychain -p "$LOCAL_CODESIGN_PASSWORD" "$LOCAL_CODESIGN_KEYCHAIN"
    security import "$LOCAL_CODESIGN_DIR/BentoLocal.p12" \
        -k "$LOCAL_CODESIGN_KEYCHAIN" \
        -P "$LOCAL_CODESIGN_P12_PASSWORD" \
        -T /usr/bin/codesign
    security add-trusted-cert \
        -d \
        -r trustRoot \
        -p codeSign \
        -k "$LOCAL_CODESIGN_KEYCHAIN" \
        "$LOCAL_CODESIGN_DIR/BentoLocal.crt"
    security set-key-partition-list \
        -S apple-tool:,apple: \
        -s \
        -k "$LOCAL_CODESIGN_PASSWORD" \
        "$LOCAL_CODESIGN_KEYCHAIN" >/dev/null
    ensure_codesign_keychain_visible
}

# --check：秒级类型检查，不编译产物、不打包（改代码时的快速反馈）
if [ "${1:-}" = "--check" ]; then
    echo "Type-checking (arm64)..."
    swiftc "$SCRIPT_DIR"/Sources/*.swift \
        -typecheck \
        -target arm64-apple-macosx14.0
    echo "OK"
    exit 0
fi

# 默认只编本机的 arm64（构建时间减半）；需要双架构时 BUILD_UNIVERSAL=1 ./build_app.sh
echo "Compiling $APP_NAME (arm64)..."
swiftc "$SCRIPT_DIR"/Sources/*.swift \
    -O \
    -o "$SCRIPT_DIR/${APP_NAME}_arm64" \
    -target arm64-apple-macosx14.0 \
    -framework AppKit \
    -framework CoreGraphics \
    -framework IOKit
if [ "${BUILD_UNIVERSAL:-0}" = "1" ]; then
    echo "Compiling $APP_NAME (x86_64)..."
    swiftc "$SCRIPT_DIR"/Sources/*.swift \
        -O \
        -o "$SCRIPT_DIR/${APP_NAME}_x86_64" \
        -target x86_64-apple-macosx14.0 \
        -framework AppKit \
        -framework CoreGraphics \
        -framework IOKit
    lipo -create \
        "$SCRIPT_DIR/${APP_NAME}_arm64" \
        "$SCRIPT_DIR/${APP_NAME}_x86_64" \
        -output "$SCRIPT_DIR/$APP_NAME"
    rm "$SCRIPT_DIR/${APP_NAME}_arm64" "$SCRIPT_DIR/${APP_NAME}_x86_64"
else
    mv "$SCRIPT_DIR/${APP_NAME}_arm64" "$SCRIPT_DIR/$APP_NAME"
fi

echo "Creating app bundle..."
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"

mv "$SCRIPT_DIR/$APP_NAME" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
cp "$SCRIPT_DIR/Assets/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"

cat > "$APP_BUNDLE/Contents/Info.plist" << 'PLIST_EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>com.sz.bento</string>
    <key>CFBundleName</key>
    <string>Bento</string>
    <key>CFBundleExecutable</key>
    <string>Bento</string>
    <key>CFBundleVersion</key>
    <string>1.0</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSInputMonitoringUsageDescription</key>
    <string>Bento needs input monitoring to distinguish trackpad gestures from mouse wheel scrolling.</string>
</dict>
</plist>
PLIST_EOF

ensure_local_codesign_identity
codesign \
    --force \
    --sign "$LOCAL_CODESIGN_NAME" \
    --identifier "$BUNDLE_ID" \
    "$APP_BUNDLE"

echo "Done: $APP_BUNDLE"
echo "Run: open $APP_BUNDLE"
