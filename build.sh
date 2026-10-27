#!/usr/bin/env bash
# Build "OpenPuck Flasher.app" from src/main.swift with swiftc (no Xcode project).
#
# Usage:
#   ./build.sh            — build + ad-hoc sign (local dev / testing)
#   ./build.sh --sign     — build + Developer ID sign + notarize + staple,
#                           then emit release artifacts: OpenPuck-Flasher.zip
#                           (for the Homebrew cask) and OpenPuck-Flasher.dmg
#                           (for direct download).
#
# --sign defaults (override via env or a .env file beside this script):
#   TEAM_ID              Apple Developer Team ID            (default: XK6QP975ZQ)
#   NOTARYTOOL_PROFILE   notarytool keychain profile name   (default: axe)
# Or notarize with an Apple ID instead of a stored profile:
#   APPLE_ID, APP_PASSWORD   (app-specific password from appleid.apple.com)
#
# Store a profile once so you never pass credentials again:
#   xcrun notarytool store-credentials "axe" \
#     --apple-id you@example.com --team-id XK6QP975ZQ --password xxxx-xxxx-xxxx-xxxx
set -euo pipefail

APP_NAME="OpenPuck Flasher"
BUNDLE="$APP_NAME.app"
BUNDLE_ID="com.ets3d.openpuckflasher"
DEPLOY_TARGET="13.0"

ROOT="$(cd "$(dirname "$0")" && pwd)"
OUT="$ROOT/build"
APP="$OUT/$BUNDLE"
CONTENTS="$APP/Contents"

# ── Options / credentials ────────────────────────────────────────────────────
SIGN=false
while [[ $# -gt 0 ]]; do
    case $1 in --sign) SIGN=true; shift ;; *) shift ;; esac
done

[[ -f "$ROOT/.env" ]] && set -a && source "$ROOT/.env" && set +a
TEAM_ID="${TEAM_ID:-XK6QP975ZQ}"
NOTARYTOOL_PROFILE="${NOTARYTOOL_PROFILE:-axe}"
APPLE_ID="${APPLE_ID:-}"
APP_PASSWORD="${APP_PASSWORD:-}"

# Pull the version from the source so the bundle/DMG/cask never drift apart.
VERSION=$(grep '^let appVersion' "$ROOT/src/main.swift" | sed 's/.*"\(.*\)".*/\1/')
[[ -n "$VERSION" ]] || { echo "✗ could not read appVersion from src/main.swift" >&2; exit 1; }

# ── Build ──────────────────────────────────────────────────────────────────────
rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"

echo "→ Generating icon…"
xcrun swiftc -O "$ROOT/src/makeicon.swift" -o "$OUT/makeicon"
"$OUT/makeicon" >/dev/null
rm -f "$OUT/makeicon"
cp "$OUT/AppIcon.icns" "$CONTENTS/Resources/AppIcon.icns"

echo "→ Compiling (v$VERSION)…"
# -parse-as-library: main.swift declares @main, so it must not be treated as a
# top-level script.
xcrun swiftc -O -parse-as-library -target "arm64-apple-macos${DEPLOY_TARGET}" \
    "$ROOT/src/main.swift" -o "$CONTENTS/MacOS/$APP_NAME"

cat > "$CONTENTS/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundleDisplayName</key><string>$APP_NAME</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key><string>$APP_NAME</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>LSMinimumSystemVersion</key><string>$DEPLOY_TARGET</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
    <key>NSRemovableVolumesUsageDescription</key><string>OpenPuck Flasher writes firmware to the board's UF2 bootloader volume.</string>
</dict>
</plist>
PLIST

# ── Sign / notarize / artifacts ─────────────────────────────────────────────────
if $SIGN; then
    SIGN_IDENTITY="Developer ID Application: Taylor Emery ($TEAM_ID)"

    echo "→ Signing with Developer ID (hardened runtime)…"
    codesign --force --deep --options runtime \
             --entitlements "$ROOT/entitlements.plist" \
             --sign "$SIGN_IDENTITY" "$APP"
    codesign --verify --deep --strict "$APP"

    echo "→ Notarizing (takes ~1 min)…"
    TMPZIP=$(mktemp /tmp/openpuck-flasher-notarize-XXXX.zip)
    ditto -c -k --keepParent "$APP" "$TMPZIP"
    if [[ -n "$NOTARYTOOL_PROFILE" ]]; then
        xcrun notarytool submit "$TMPZIP" --keychain-profile "$NOTARYTOOL_PROFILE" --wait
    elif [[ -n "$APPLE_ID" && -n "$APP_PASSWORD" ]]; then
        xcrun notarytool submit "$TMPZIP" \
            --apple-id "$APPLE_ID" --team-id "$TEAM_ID" --password "$APP_PASSWORD" --wait
    else
        echo "✗ Set NOTARYTOOL_PROFILE (or APPLE_ID + APP_PASSWORD) to notarize." >&2
        rm -f "$TMPZIP"; exit 1
    fi
    rm -f "$TMPZIP"

    # Clear extended attributes before stapling. ditto -c -k re-encodes xattrs as
    # AppleDouble ._ entries inside the zip; Homebrew unzips with plain unzip, so
    # those land as literal files and break the install ("damaged"). The signature
    # and notarization ticket are real files in the bundle, not xattrs, so this is
    # safe — the verify gate below re-checks the seal and Gatekeeper.
    xattr -cr "$APP"

    echo "→ Stapling ticket…"
    xcrun stapler staple "$APP"
    find "$APP" -name '._*' -delete 2>/dev/null || true

    echo "→ Emitting release artifacts…"
    ZIP="$OUT/OpenPuck-Flasher.zip"
    DMG="$OUT/OpenPuck-Flasher.dmg"

    # Homebrew zip — --noextattr/--norsrc so ditto never re-embeds ._ sidecars.
    ditto --noextattr --norsrc -c -k --keepParent "$APP" "$ZIP"
    if unzip -l "$ZIP" | grep -q '/\._'; then
        echo "✗ ABORT: zip contains ._ AppleDouble sidecars." >&2; exit 1
    fi

    # Verify gate: extract the zip we just wrote and confirm Gatekeeper accepts it.
    VERIFYDIR=$(mktemp -d)
    ditto -x -k "$ZIP" "$VERIFYDIR"
    if ! codesign --verify --deep --strict "$VERIFYDIR/$BUNDLE" 2>/dev/null; then
        echo "✗ ABORT: zip fails codesign --verify (broken seal)." >&2; rm -rf "$VERIFYDIR"; exit 1
    fi
    if ! spctl -a -t exec "$VERIFYDIR/$BUNDLE" 2>/dev/null; then
        echo "✗ ABORT: zip rejected by Gatekeeper (spctl). Not distributable." >&2; rm -rf "$VERIFYDIR"; exit 1
    fi
    rm -rf "$VERIFYDIR"

    # DMG with an /Applications symlink for drag-install (direct download).
    DMGTMP=$(mktemp -d)
    cp -R "$APP" "$DMGTMP/"
    ln -s /Applications "$DMGTMP/Applications"
    hdiutil create -volname "$APP_NAME" -srcfolder "$DMGTMP" -ov -format UDZO "$DMG" >/dev/null
    rm -rf "$DMGTMP"

    echo ""
    echo "✓ Signed, notarized, stapled, Gatekeeper-verified."
    echo "  $ZIP   ($(du -sh "$ZIP" | cut -f1))   sha256 $(shasum -a 256 "$ZIP" | cut -d' ' -f1)"
    echo "  $DMG   ($(du -sh "$DMG" | cut -f1))"
else
    codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || echo "(codesign skipped)"
    echo "Built (ad-hoc): $APP   — for release use ./build.sh --sign"
fi

echo "Run:  open \"$APP\""
