#!/bin/bash

# Sourced by build_app.sh and fixture tests; sourcing never touches a keychain.
# Select by exact certificate hash, not a possibly ambiguous common name.
bento_resolve_codesign_identity() {
    local requested="$1" identities line hash name
    local identity_line='^[[:space:]]*[0-9]+\)[[:space:]]+([[:xdigit:]]{40})[[:space:]]+"([^"]+)"[[:space:]]*$'
    if [[ "$requested" =~ ^[[:xdigit:]]{40}$ ]]; then
        requested="$(printf '%s' "$requested" | tr '[:lower:]' '[:upper:]')"
    fi
    identities="$(security find-identity -v -p codesigning)" || {
        echo "error: 无法查询可用签名身份；保留现有 App。" >&2
        return 1
    }
    CODESIGN_IDENTITY=""
    while IFS= read -r line; do
        # Reject revoked/expired entries with trailing error annotations, even
        # when a security version includes them in its -v output.
        [[ "$line" =~ $identity_line ]] || continue
        hash="$(printf '%s' "${BASH_REMATCH[1]}" | tr '[:lower:]' '[:upper:]')"
        name="${BASH_REMATCH[2]}"
        [ "$requested" = "$hash" ] || [ "$requested" = "$name" ] || continue
        if [ -n "$CODESIGN_IDENTITY" ] && [ "$CODESIGN_IDENTITY" != "$hash" ]; then
            echo "error: 签名名称对应多个有效证书，请用 BENTO_CODESIGN_IDENTITY 指定完整 SHA-1：$requested" >&2
            return 1
        fi
        CODESIGN_NAME="$name"
        CODESIGN_IDENTITY="$hash"
    done <<< "$identities"
    if [ -z "$CODESIGN_IDENTITY" ]; then
        echo "error: 找不到原定签名的有效证书及私钥：$requested；保留现有 App，不自动切换签名。" >&2
        return 1
    fi
}

bento_select_codesign_identity() {
    local requested certificate_dir signing_info fingerprint authority
    CODESIGN_PRESERVE_RUNTIME=0
    if [ "${BENTO_CODESIGN_IDENTITY+x}" = x ]; then
        requested="$BENTO_CODESIGN_IDENTITY"
        if [ -z "$requested" ]; then
            echo "error: BENTO_CODESIGN_IDENTITY 不能为空。" >&2
            return 1
        fi
        if [ "$requested" = "$LOCAL_CODESIGN_NAME" ]; then
            # Keep this unguarded: the existing setup function relies on the
            # caller's set -e to stop on a failed keychain operation.
            ensure_local_codesign_identity
        fi
    elif [ -e "$APP_BUNDLE" ]; then
        codesign --verify --strict --deep "$APP_BUNDLE" || {
            echo "error: 现有 Bento.app 签名不完整；请明确指定 BENTO_CODESIGN_IDENTITY，未替换原 App。" >&2
            return 1
        }
        certificate_dir="$(mktemp -d "${TMPDIR:-/tmp}/bento-signing.XXXXXX")" || return 1
        if ! signing_info="$(codesign -d --verbose=4 --extract-certificates="$certificate_dir/cert" "$APP_BUNDLE" 2>&1)" \
            || [ ! -s "$certificate_dir/cert0" ]; then
            rm -rf "$certificate_dir"
            echo "error: 无法读取现有 App 的签名证书；不自动切换到自签名。" >&2
            return 1
        fi
        fingerprint="$(shasum -a 1 "$certificate_dir/cert0")" || {
            rm -rf "$certificate_dir"
            return 1
        }
        rm -rf "$certificate_dir"
        requested="${fingerprint%% *}"
        authority="$(printf '%s\n' "$signing_info" | sed -n 's/^Authority=//p' | head -n 1)"
        if [ "$authority" = "$LOCAL_CODESIGN_NAME" ]; then
            # Unlock the original keychain only. Never create/rotate its
            # identity while trying to preserve an installed App's signature.
            unlock_existing_local_codesign_identity
        fi
        case "$signing_info" in *'(runtime)'*) CODESIGN_PRESERVE_RUNTIME=1 ;; esac
    else
        requested="$LOCAL_CODESIGN_NAME"
        ensure_local_codesign_identity
    fi
    bento_resolve_codesign_identity "$requested" || return 1
    echo "Signing identity: $CODESIGN_NAME ($CODESIGN_IDENTITY)"
}
