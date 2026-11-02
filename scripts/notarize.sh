#!/bin/bash
# Notarizes a signed app with Apple and staples the ticket to it, so Gatekeeper
# opens it without a warning, even offline.
#
#   scripts/notarize.sh build/App.app
#
# The app must already be signed with a Developer ID Application certificate,
# the hardened runtime and a secure timestamp. Authentication uses an App Store
# Connect API key:
#
#   NOTARY_KEY_PATH   path to the AuthKey_XXXXXXXXXX.p8 file
#   NOTARY_KEY_ID     the key's ID
#   NOTARY_ISSUER_ID  the issuer ID shown above the key list in App Store Connect
set -euo pipefail

APP="${1:?usage: scripts/notarize.sh path/to/App.app}"
: "${NOTARY_KEY_PATH:?set NOTARY_KEY_PATH to the .p8 API key}"
: "${NOTARY_KEY_ID:?set NOTARY_KEY_ID}"
: "${NOTARY_ISSUER_ID:?set NOTARY_ISSUER_ID}"
AUTH=(--key "$NOTARY_KEY_PATH" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID")

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
ditto -c -k --keepParent "$APP" "$TMP/upload.zip"

echo "Submitting $(basename "$APP") for notarization..."
xcrun notarytool submit "$TMP/upload.zip" "${AUTH[@]}" --wait --timeout 30m \
    --output-format json > "$TMP/result.json" || true
STATUS="$(plutil -extract status raw "$TMP/result.json" 2>/dev/null || echo unknown)"
ID="$(plutil -extract id raw "$TMP/result.json" 2>/dev/null || true)"
echo "Notarization $STATUS${ID:+ ($ID)}"

if [ "$STATUS" != Accepted ]; then
    cat "$TMP/result.json" >&2
    [ -n "$ID" ] && xcrun notarytool log "$ID" "${AUTH[@]}" >&2
    exit 1
fi

xcrun stapler staple "$APP"
spctl --assess --type execute --verbose=2 "$APP"
