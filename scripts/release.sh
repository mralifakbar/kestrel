#!/bin/zsh
# Publishes a release from this Mac. There is no hosted CI: this script is the release pipeline.
#
#   ./scripts/release.sh 1.2.0
#
# It checks everything first, then: runs the tests, builds the universal app signed with the
# Developer ID, notarizes and staples it, zips it with its SHA-256, pushes the branch and a
# v1.2.0 tag, and publishes the GitHub release with the CHANGELOG.md section as notes.
#
# Before the first release on this Mac:
#   - the Developer ID Application certificate in the login keychain (Xcode › Settings › Accounts)
#   - notarization credentials saved once, see scripts/notarize.sh
#   - the GitHub CLI signed in: gh auth login
#
# Move the Unreleased notes in CHANGELOG.md under "## [1.2.0]" and commit before running it.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?usage: scripts/release.sh <version>, for example 1.2.0}"
VERSION="${VERSION#v}"
TAG="v$VERSION"
REPO="mralifakbar/kestrel"
APP="build/Kestrel.app"
ZIP="build/Kestrel-$VERSION.zip"
IDENTITY="${SIGN_IDENTITY:-Developer ID Application: Alif Akbar Kartadinata (5583X832TP)}"

fail() { echo "✗ $1" >&2; exit 1; }

echo "› Preflight"
[[ "$(git branch --show-current)" == main ]] || fail "Release from main."
[[ -z "$(git status --porcelain)" ]] || fail "Commit or stash your changes first."
git fetch -q origin
[[ -z "$(git log HEAD..origin/main --oneline)" ]] || fail "origin/main has commits you don't have: git pull first."
grep -q "^## \[$VERSION\]" CHANGELOG.md || fail "Add a ## [$VERSION] section to CHANGELOG.md first."
git rev-parse -q --verify "refs/tags/$TAG" >/dev/null && fail "$TAG already exists."
git ls-remote --exit-code --tags origin "$TAG" >/dev/null 2>&1 && fail "$TAG already exists on GitHub."
security find-identity -v -p codesigning | grep -qF "\"$IDENTITY\"" || fail "No \"$IDENTITY\" certificate in the keychain."
gh auth status >/dev/null 2>&1 || fail "Sign in to the GitHub CLI first: gh auth login"
if [[ -z "${NOTARY_KEY_PATH:-}" ]]; then
  xcrun notarytool history --keychain-profile "${NOTARY_PROFILE:-notary}" >/dev/null 2>&1 \
    || fail "No notarization credentials. Save them once: see the top of scripts/notarize.sh."
fi

echo "› Unit tests"
swift test

echo "› Signed universal build"
rm -rf "$APP"
VERSION="$VERSION" KESTREL_SIGN_IDENTITY="$IDENTITY" ./build.sh --universal
codesign --verify --strict --deep "$APP"

echo "› Notarize"
scripts/notarize.sh "$APP"

echo "› Package"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
(cd build && shasum -a 256 "Kestrel-$VERSION.zip" | tee SHA256SUMS.txt)

NOTES=build/notes.md
awk -v v="[$VERSION]" '/^## \[/ { p = index($0, v) > 0; next } /^\[[^]]+\]: / { p = 0 } p' CHANGELOG.md > $NOTES
{
  echo
  echo "### Install"
  echo
  echo "Unzip, move **Kestrel.app** to Applications and open it. The app is signed with a Developer ID and notarized by Apple, so macOS opens it without a warning."
  echo
  echo "SHA-256:"
  echo '```'
  cat build/SHA256SUMS.txt
  echo '```'
} >> $NOTES
cat $NOTES

echo "› Publish"
git push origin HEAD
git tag -a "$TAG" -m "Kestrel $VERSION"
git push origin "$TAG"
gh release create "$TAG" "$ZIP" build/SHA256SUMS.txt --repo "$REPO" --title "Kestrel $VERSION" --notes-file $NOTES --verify-tag
echo "✓ Released Kestrel $VERSION: https://github.com/$REPO/releases/tag/$TAG"
