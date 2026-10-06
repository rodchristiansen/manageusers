#!/bin/bash
# Builds the manageusers installer package.
#
# Layout: the tool has its own folder, as outset has /usr/local/outset.
#   /usr/local/manageusers/manageusers   the universal binary
#   /usr/local/bin/manageusers           a symlink to it, for the PATH
# Data and logs live under /Library/Managed Users; the tool creates them.
#
# Usage: packaging/build-pkg.sh <version> <output-dir> [installer-signing-identity]
set -euo pipefail

VERSION="${1:?version}"
OUT="${2:?output directory}"
SIGN="${3:-}"
IDENTIFIER="com.github.rodchristiansen.manageusers"

cd "$(dirname "$0")/.."
swift build -c release --product manageusers --arch arm64 --arch x86_64
BIN="$(swift build -c release --product manageusers --arch arm64 --arch x86_64 --show-bin-path)/manageusers"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
ROOT="$WORK/root"
mkdir -p "$ROOT/usr/local/manageusers" "$ROOT/usr/local/bin" "$OUT"
cp "$BIN" "$ROOT/usr/local/manageusers/manageusers"
chmod 755 "$ROOT/usr/local/manageusers" "$ROOT/usr/local/manageusers/manageusers"
ln -s /usr/local/manageusers/manageusers "$ROOT/usr/local/bin/manageusers"
# Clear extended attributes where possible so the payload carries none.
find "$ROOT" -exec xattr -s -c {} + 2>/dev/null || true

pkgbuild --root "$ROOT" --identifier "$IDENTIFIER" --version "$VERSION" --ownership recommended \
    --scripts packaging/scripts --install-location / "$WORK/component.pkg"
if [[ -n "$SIGN" ]]; then
    productbuild --package "$WORK/component.pkg" --identifier "$IDENTIFIER" --version "$VERSION" \
        --sign "$SIGN" --timestamp "$OUT/ManageUsers-${VERSION}.pkg"
else
    productbuild --package "$WORK/component.pkg" --identifier "$IDENTIFIER" --version "$VERSION" \
        "$OUT/ManageUsers-${VERSION}.pkg"
fi
echo "Built $OUT/ManageUsers-${VERSION}.pkg"
