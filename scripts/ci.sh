#!/bin/zsh
# Every check a change should pass, run on this Mac. There is no hosted CI.
#
#   ./scripts/ci.sh
set -euo pipefail
cd "$(dirname "$0")/.."

echo "› Toolchain"
xcodebuild -version | sed -n 1p
swift --version 2>&1 | sed -n 1p

echo "› Unit tests"
swift test

echo "› Universal build"
./build.sh --universal --zip

echo "› Smoke test"
build/Kestrel.app/Contents/Helpers/kestrel --version
codesign --verify --strict build/Kestrel.app
lipo -archs build/Kestrel.app/Contents/MacOS/Kestrel | grep -q x86_64
lipo -archs build/Kestrel.app/Contents/MacOS/Kestrel | grep -q arm64

echo "✓ All checks passed"
