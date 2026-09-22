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
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/fr.lproj"
cp "$BIN" "$APP/Contents/MacOS/Rushes"
cp Support/Info.plist "$APP/Contents/Info.plist"
# The only localisation the bundle declares is French, so AppKit draws its own
# menus (Édition, Fenêtre, Quitter) in French whatever the Mac is set to.
cp Support/InfoPlist.strings "$APP/Contents/Resources/fr.lproj/InfoPlist.strings"
if [ -f Support/AppIcon.icns ]; then
  cp Support/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
fi

# Copying carries extended attributes across, and codesign refuses a bundle
# that has any; the file provider can put them back between the clean and the
# signature, so the pair is retried. Ad-hoc signature: enough to run here.
# macOS keys the removable volumes permission to it, so a rebuild asks again.
for attempt in 1 2 3 4 5; do
  xattr -cr "$APP"
  if codesign --force --sign - "$APP" >/dev/null 2>&1; then
    break
  fi
  if [ "$attempt" -eq 5 ]; then
    codesign --force --sign - "$APP"
  fi
  sleep 1
done

echo "$(pwd)/$APP"
