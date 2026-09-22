#!/usr/bin/env bash
# Builds "Rushes.app". SwiftPM only produces a bare executable, so the bundle
# is assembled here, the same way Cairn and Journal's Mac app are.
#
# Release by default, unlike Cairn: the checksum runs over every byte of every
# card, and a debug build hashes ten times slower than an optimised one.
set -euo pipefail
cd "$(dirname "$0")"

CONFIG="${1:-release}"
# The build products live outside Documents: the folder is synced, its file
# provider puts extended attributes on them, and codesign refuses those.
SCRATCH="/tmp/rushes-build"
swift build -c "$CONFIG" --scratch-path "$SCRATCH"
BIN="$(swift build -c "$CONFIG" --scratch-path "$SCRATCH" --show-bin-path)/Rushes"

APP="build/Rushes.app"
# The bundle is assembled and signed in the scratch folder, not in build/.
# codesign refuses a bundle carrying extended attributes, and under Documents
# they come back on their own between the clean and the signature: the file
# provider adds its own, and LaunchServices tags an app that has been run.
# Out here nothing puts them back, so one clean holds until the signature.
STAGE="$SCRATCH/Rushes.app"
rm -rf "$STAGE"
mkdir -p "$STAGE/Contents/MacOS" "$STAGE/Contents/Resources/fr.lproj"
cp "$BIN" "$STAGE/Contents/MacOS/Rushes"
cp Support/Info.plist "$STAGE/Contents/Info.plist"
# The only localisation the bundle declares is French, so AppKit draws its own
# menus (Édition, Fenêtre, Quitter) in French whatever the Mac is set to.
cp Support/InfoPlist.strings "$STAGE/Contents/Resources/fr.lproj/InfoPlist.strings"
if [ -f Support/AppIcon.icns ]; then
  cp Support/AppIcon.icns "$STAGE/Contents/Resources/AppIcon.icns"
fi

# Copying carries extended attributes across from Support/, so the bundle is
# cleaned first. Ad-hoc signature: enough to run here. macOS keys the removable
# volumes permission to it, so a rebuild asks again.
xattr -cr "$STAGE"
codesign --force --sign - "$STAGE"

# ditto carries neither extended attributes nor resource forks, so what lands
# in build/ is the signed bundle and nothing else. Attributes the Mac adds to
# it afterwards do not touch the signature; only signing minds them.
rm -rf "$APP"
mkdir -p build
ditto --noextattr --norsrc "$STAGE" "$APP"
codesign --verify --strict "$APP"

echo "$(pwd)/$APP"
