#!/bin/bash
# Builds the manageusers installer package: the tool and its window, in one pkg.
#
# Layout: the tool has its own folder, as outset has /usr/local/outset.
#   /usr/local/manageusers/manageusers                 the universal binary
#   /usr/local/bin/manageusers                         a symlink to it, for the PATH
#   /Applications/Utilities/Managed Users Cleanup.app  the Prefs / Run / Logs window,
#                                                      with its privileged helper inside
#   /Library/LaunchDaemons/com.github.manageusers.helper.plist
#                                                      the helper's on-demand LaunchDaemon
# Data and logs live under /Library/Managed Users; the tool creates them.
#
# The window is built by ManagedUsersCleanup/Makefile (make app). Set
# SIGNING_IDENTITY_APP to have it sign the app and helper; the tool binary is
# signed by build.sh.
#
# Usage: packaging/build-pkg.sh <version> <output-dir> [installer-signing-identity]
set -euo pipefail

VERSION="${1:?version}"
OUT="${2:?output directory}"
SIGN="${3:-}"
IDENTIFIER="com.github.rodchristiansen.manageusers"
HELPER_LABEL="com.github.manageusers.helper"
APP_REL="Applications/Utilities/Managed Users Cleanup.app"

cd "$(dirname "$0")/.."
REPO="$(pwd)"
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"

swift build -c release --product manageusers --arch arm64 --arch x86_64
BIN="$(swift build -c release --product manageusers --arch arm64 --arch x86_64 --show-bin-path)/manageusers"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
ROOT="$WORK/root"
mkdir -p "$ROOT/usr/local/manageusers" "$ROOT/usr/local/bin" "$ROOT/Applications/Utilities" "$ROOT/Library/LaunchDaemons"
cp "$BIN" "$ROOT/usr/local/manageusers/manageusers"
chmod 755 "$ROOT/usr/local/manageusers" "$ROOT/usr/local/manageusers/manageusers"
ln -s /usr/local/manageusers/manageusers "$ROOT/usr/local/bin/manageusers"

# The window: the app bundle carries the GUI and the helper, both stamped with
# the package version (YYYY.MM.DD.HHMM, split into 2026.10.06 and 1342).
make -C "$REPO/ManagedUsersCleanup" app VERSION="$VERSION"
ditto "$REPO/ManagedUsersCleanup/build/pkg-root/$APP_REL" "$ROOT/$APP_REL"

# The system LaunchDaemon. The bundle's copy uses BundleProgram, which only
# SMAppService understands; launchd needs ProgramArguments. No RunAtLoad and no
# KeepAlive: launchd starts the helper only when the window connects to its
# Mach service, so installing the package runs nothing.
DAEMON="$ROOT/Library/LaunchDaemons/$HELPER_LABEL.plist"
cp "$ROOT/$APP_REL/Contents/Library/LaunchDaemons/$HELPER_LABEL.plist" "$DAEMON"
/usr/libexec/PlistBuddy -c "Delete :BundleProgram" "$DAEMON"
/usr/libexec/PlistBuddy -c "Add :ProgramArguments array" "$DAEMON"
/usr/libexec/PlistBuddy -c "Add :ProgramArguments:0 string /$APP_REL/Contents/MacOS/ManagedUsersCleanupHelper" "$DAEMON"
chmod 644 "$DAEMON"
if /usr/libexec/PlistBuddy -c "Print :RunAtLoad" "$DAEMON" >/dev/null 2>&1 \
    || /usr/libexec/PlistBuddy -c "Print :KeepAlive" "$DAEMON" >/dev/null 2>&1; then
    echo "The helper LaunchDaemon must stay on demand: remove RunAtLoad and KeepAlive" >&2
    exit 1
fi

# Clear extended attributes where possible so the payload carries none.
find "$ROOT" -exec xattr -s -c {} + 2>/dev/null || true

# Install the app where the payload says, never over a copy found elsewhere, and
# whatever version is already there: the package version is the one that counts.
pkgbuild --analyze --root "$ROOT" "$WORK/component.plist"
i=0
while /usr/libexec/PlistBuddy -c "Print :$i" "$WORK/component.plist" >/dev/null 2>&1; do
    for key in BundleIsRelocatable BundleIsVersionChecked; do
        /usr/libexec/PlistBuddy -c "Set :$i:$key false" "$WORK/component.plist" 2>/dev/null \
            || /usr/libexec/PlistBuddy -c "Add :$i:$key bool false" "$WORK/component.plist"
    done
    i=$((i + 1))
done
if [[ $i -eq 0 ]]; then
    echo "pkgbuild found no bundle to configure in $ROOT" >&2
    exit 1
fi

pkgbuild --root "$ROOT" --component-plist "$WORK/component.plist" --identifier "$IDENTIFIER" \
    --version "$VERSION" --ownership recommended --scripts packaging/scripts --install-location / \
    "$WORK/component.pkg"
if [[ -n "$SIGN" ]]; then
    productbuild --package "$WORK/component.pkg" --identifier "$IDENTIFIER" --version "$VERSION" \
        --sign "$SIGN" --timestamp "$OUT/ManageUsers-${VERSION}.pkg"
else
    productbuild --package "$WORK/component.pkg" --identifier "$IDENTIFIER" --version "$VERSION" \
        "$OUT/ManageUsers-${VERSION}.pkg"
fi
echo "Built $OUT/ManageUsers-${VERSION}.pkg"
