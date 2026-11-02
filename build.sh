#!/bin/bash
# Builds build/Kestrel.app.
#
#   ./build.sh               native architecture
#   ./build.sh --universal   arm64 + x86_64, what releases ship
#   ./build.sh --zip         also write build/Kestrel-<version>.zip
#   ./build.sh --install     also copy the app to /Applications
#
# The version comes from $VERSION, else the latest git tag, else 0.1.0.
# Set KESTREL_SIGN_IDENTITY (e.g. "Apple Development: …") to sign with a real
# certificate, so macOS keeps audio and notification permissions across rebuilds.
# Releases use a Developer ID Application certificate and scripts/notarize.sh.
set -euo pipefail
cd "$(dirname "$0")"

UNIVERSAL=0 ZIP=0 INSTALL=0
for arg in "$@"; do
    case "$arg" in
        --universal) UNIVERSAL=1 ;;
        --zip) ZIP=1 ;;
        --install) INSTALL=1 ;;
        *) echo "unknown option: $arg" >&2; exit 1 ;;
    esac
done

VERSION="${VERSION:-$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || true)}"
VERSION="${VERSION:-0.1.0}"
BUILD_NUMBER="$(git rev-list --count HEAD 2>/dev/null || echo 1)"

ARGS=(-c release)
if [ "$UNIVERSAL" = 1 ]; then ARGS+=(--arch arm64 --arch x86_64); fi
swift build "${ARGS[@]}"
BIN="$(swift build "${ARGS[@]}" --show-bin-path)"

APP=build/Kestrel.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$APP/Contents/Resources"
cp "$BIN/KestrelApp" "$APP/Contents/MacOS/Kestrel"
cp "$BIN/KestrelHelper" "$APP/Contents/MacOS/KestrelHelper"
# The CLI lives in its own folder: APFS is case-insensitive, so "kestrel" would replace "Kestrel".
cp "$BIN/kestrel" "$APP/Contents/Helpers/kestrel"
cp Resources/Info.plist "$APP/Contents/Info.plist"
for l in Resources/*.lproj; do [ -d "$l" ] && cp -R "$l" "$APP/Contents/Resources/"; done
plutil -replace CFBundleShortVersionString -string "$VERSION" "$APP/Contents/Info.plist"
plutil -replace CFBundleVersion -string "$BUILD_NUMBER" "$APP/Contents/Info.plist"

if [ ! -f build/AppIcon.icns ]; then
    rm -rf build/AppIcon.iconset && mkdir -p build/AppIcon.iconset
    swift scripts/make-icon.swift build/icon-1024.png
    for s in 16 32 128 256 512; do
        sips -z $s $s build/icon-1024.png --out "build/AppIcon.iconset/icon_${s}x${s}.png" >/dev/null
        sips -z $((s * 2)) $((s * 2)) build/icon-1024.png --out "build/AppIcon.iconset/icon_${s}x${s}@2x.png" >/dev/null
    done
    iconutil -c icns build/AppIcon.iconset -o build/AppIcon.icns
fi
cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

IDENTITY="${KESTREL_SIGN_IDENTITY:--}"
SIGN=(--force --options runtime --sign "$IDENTITY")
# Notarization needs a secure timestamp on every binary; ad-hoc signatures can't have one.
[ "$IDENTITY" = "-" ] || SIGN+=(--timestamp)
for f in "$APP/Contents/Helpers/kestrel" "$APP/Contents/MacOS/KestrelHelper"; do
    codesign "${SIGN[@]}" "$f"
done
codesign "${SIGN[@]}" --entitlements Resources/Kestrel.entitlements "$APP"
echo "Built $APP $VERSION ($(lipo -archs "$APP/Contents/MacOS/Kestrel"), $(du -sh "$APP" | cut -f1), signed: $IDENTITY)"

if [ "$ZIP" = 1 ]; then
    rm -f "build/Kestrel-$VERSION.zip"
    ditto -c -k --keepParent "$APP" "build/Kestrel-$VERSION.zip"
    echo "Packed build/Kestrel-$VERSION.zip"
fi

if [ "$INSTALL" = 1 ]; then
    pkill -x Kestrel 2>/dev/null || true
    rm -rf /Applications/Kestrel.app
    cp -R "$APP" /Applications/
    echo "Installed to /Applications/Kestrel.app"
fi
