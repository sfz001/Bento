#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="Bento"
BUNDLE_ID="com.sz.bento"
APP_BUNDLE="$SCRIPT_DIR/$APP_NAME.app"
LOCAL_CODESIGN_NAME="Bento Local Code Signing"
LOCAL_CODESIGN_DIR="$SCRIPT_DIR/.bento-codesign"
LOCAL_CODESIGN_KEYCHAIN="$HOME/Library/Keychains/BentoLocalCodeSigning.keychain-db"
LOCAL_CODESIGN_PASSWORD_FILE="$LOCAL_CODESIGN_DIR/keychain-password"
# 仅供旧钥匙串迁移：老版本把这个口令硬编码在脚本里（且仓库公开）。
# 新口令随机生成、存 gitignore 的 .bento-codesign/keychain-password（0600）
LEGACY_CODESIGN_PASSWORD="bento-local-codesign"
LOCAL_CODESIGN_PASSWORD=""

# 取（或生成）钥匙串口令。旧钥匙串用 set-keychain-password 原地换口令：
# 证书和私钥都不动，designated requirement 不变，已授予的 TCC 权限全部保住
ensure_codesign_password() {
    mkdir -p "$LOCAL_CODESIGN_DIR"
    if [ -f "$LOCAL_CODESIGN_PASSWORD_FILE" ]; then
        LOCAL_CODESIGN_PASSWORD="$(cat "$LOCAL_CODESIGN_PASSWORD_FILE")"
        return
    fi
    LOCAL_CODESIGN_PASSWORD="$(openssl rand -hex 24)"
    if [ -f "$LOCAL_CODESIGN_KEYCHAIN" ]; then
        if ! security set-keychain-password \
            -o "$LEGACY_CODESIGN_PASSWORD" -p "$LOCAL_CODESIGN_PASSWORD" \
            "$LOCAL_CODESIGN_KEYCHAIN"; then
            echo "error: 钥匙串口令迁移失败（口令文件丢失且旧口令不匹配）。" >&2
            echo "  恢复 $LOCAL_CODESIGN_PASSWORD_FILE，或删除 $LOCAL_CODESIGN_KEYCHAIN 重建（需重新授予辅助功能/输入监控权限）。" >&2
            exit 1
        fi
    fi
    (umask 077; printf '%s' "$LOCAL_CODESIGN_PASSWORD" > "$LOCAL_CODESIGN_PASSWORD_FILE")
}

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
        # 读不到现有搜索列表时绝不整表改写——那会把用户配置的其它钥匙串清掉
        echo "warning: 无法读取钥匙串搜索列表，跳过登记 $LOCAL_CODESIGN_KEYCHAIN" >&2
        return
    fi

    if [ "$found" != true ]; then
        keychains+=("$LOCAL_CODESIGN_KEYCHAIN")
        security list-keychains -d user -s "${keychains[@]}"
    fi
}

# 私钥/P12 一旦进了钥匙串就没有留在磁盘上的理由。Bento 的辅助功能/输入监控授权
# 是按签名要求绑定的：谁拿到这把明文私钥（openssl -nodes 产物，同用户可读），谁就能
# 签出满足同一 designated requirement 的替代程序，继承这些权限。
# 证书 .crt 留着——重建身份时 add-trusted-cert 要用。
discard_on_disk_private_key() {
    rm -f "$LOCAL_CODESIGN_DIR/BentoLocal.key" "$LOCAL_CODESIGN_DIR/BentoLocal.p12"
}

ensure_local_codesign_identity() {
    ensure_codesign_password

    if [ -f "$LOCAL_CODESIGN_KEYCHAIN" ]; then
        # 先解锁再查身份：锁着的钥匙串会让 find-identity 假阴性
        security unlock-keychain -p "$LOCAL_CODESIGN_PASSWORD" "$LOCAL_CODESIGN_KEYCHAIN" >/dev/null 2>&1 || true
        if security find-identity -v -p codesigning "$LOCAL_CODESIGN_KEYCHAIN" 2>/dev/null | grep -q "$LOCAL_CODESIGN_NAME"; then
            discard_on_disk_private_key  # 旧构建留下的残留也一并清掉
            ensure_codesign_keychain_visible
            return
        fi
        # 钥匙串在、身份查不到：可能只是解锁/查询故障。此时销毁重建会轮换证书、
        # 让已授予的辅助功能/输入监控权限全部失效——绝不自动做，交用户显式确认
        if [ "${BENTO_REBUILD_CODESIGN:-0}" != "1" ]; then
            echo "error: $LOCAL_CODESIGN_KEYCHAIN 存在但找不到签名身份，拒绝自动重建。" >&2
            echo "  确认要重建（会轮换证书、TCC 权限需重新授予）请运行: BENTO_REBUILD_CODESIGN=1 ./build_app.sh" >&2
            exit 1
        fi
        echo "BENTO_REBUILD_CODESIGN=1：按要求重建签名身份（TCC 权限将失效）"
    fi

    echo "Creating local code-signing identity..."
    # 任何一步失败（set -e 直接退出）都不能把明文私钥留在盘上
    trap 'discard_on_disk_private_key' EXIT
    local p12_password
    p12_password="$(openssl rand -hex 16)"  # 只在导入的几秒里有用，用完即弃
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
        -passout "pass:$p12_password"

    security create-keychain -p "$LOCAL_CODESIGN_PASSWORD" "$LOCAL_CODESIGN_KEYCHAIN"
    security unlock-keychain -p "$LOCAL_CODESIGN_PASSWORD" "$LOCAL_CODESIGN_KEYCHAIN"
    security import "$LOCAL_CODESIGN_DIR/BentoLocal.p12" \
        -k "$LOCAL_CODESIGN_KEYCHAIN" \
        -P "$p12_password" \
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

    discard_on_disk_private_key
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
# 签完立刻验：TCC 授权按签名要求绑定，坏签名的产物跑起来会静默丢掉全部权限
codesign --verify --strict "$APP_BUNDLE"

echo "Done: $APP_BUNDLE"
echo "Run: open $APP_BUNDLE"
