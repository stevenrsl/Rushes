#!/usr/bin/env bash
# Builds "Rushes.app". SwiftPM only produces a bare executable, so the bundle
# is assembled here, the same way Cairn and Journal's Mac app are.
#
#   ./build.sh                  release, signed on this Mac only (the default)
#   ./build.sh debug            the same, unoptimised
#   ./build.sh release-signed   Developer ID, hardened runtime, notarised,
#                               packed in build/Rushes-<version>.dmg
#   ./build.sh release-selfsigned
#                               the same .dmg signed with the self-signed
#                               certificate "Rushes", not notarised: what the
#                               beta ships until there is a Developer ID
#
# Release by default, unlike Cairn: the checksum runs over every byte of every
# card, and a debug build hashes ten times slower than an optimised one.
#
# release-signed reads two things from the environment, never from the repo:
#   RUSHES_SIGN_IDENTITY   "Developer ID Application: Name (TEAMID)", as
#                          `security find-identity -v -p codesigning` prints it
#   RUSHES_NOTARY_PROFILE  a keychain profile made once with
#                          `xcrun notarytool store-credentials <profile>`
# RUSHES_SIGN_IDENTITY=- signs ad hoc and skips notarisation, to try the
# packaging. Gatekeeper blocks that .dmg on another Mac until "Ouvrir quand
# même", and the volumes permission is asked again at every version.
#
# release-selfsigned signs with the certificate Tools/make-signing-certificate.sh
# made, found by the SHA-1 install.sh pins (RUSHES_KEYCHAIN for another keychain
# than the default list). Gatekeeper still blocks a browser's download, but
# the signature is the same from one version to the next, so the volumes
# permission holds, and install.sh, whose download carries no quarantine,
# installs it without a block once it has checked the hash and the signature.
# Every .dmg gets a .sha256 beside it, for the release page.
set -euo pipefail
cd "$(dirname "$0")"

MODE="${1:-release}"
case "$MODE" in
  release|debug) CONFIG="$MODE"; SIGNED=0 ;;
  release-signed) CONFIG=release; SIGNED=1 ;;
  release-selfsigned) CONFIG=release; SIGNED=2 ;;
  *) echo "usage: ./build.sh [release|debug|release-signed|release-selfsigned]" >&2; exit 2 ;;
esac

# The version lives in Support/Info.plist and nowhere else: the About window
# reads it from the bundle, the update check too, and the .dmg is named by it,
# as the release is tagged: 0.3.0 and RushesPrerelease beta.1 → 0.3.0-beta.1.
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Support/Info.plist)"
PRERELEASE="$(/usr/libexec/PlistBuddy -c 'Print :RushesPrerelease' Support/Info.plist 2>/dev/null || true)"
if [ -n "$PRERELEASE" ]; then VERSION="$VERSION-$PRERELEASE"; fi

if [ "$SIGNED" = 1 ]; then
  IDENTITY="${RUSHES_SIGN_IDENTITY:-}"
  PROFILE="${RUSHES_NOTARY_PROFILE:-}"
  if [ -z "$IDENTITY" ]; then
    echo "release-signed needs RUSHES_SIGN_IDENTITY (see the top of build.sh)." >&2
    exit 1
  fi
  if [ "$IDENTITY" != "-" ]; then
    if [ -z "$PROFILE" ]; then
      echo "release-signed needs RUSHES_NOTARY_PROFILE (see the top of build.sh)." >&2
      exit 1
    fi
    # Checked before compiling, so a typo costs a second, not a build.
    if ! security find-identity -v -p codesigning | grep -qF "\"$IDENTITY\""; then
      echo "No signing identity \"$IDENTITY\" in the keychain." >&2
      exit 1
    fi
  fi
elif [ "$SIGNED" = 2 ]; then
  # By its hash, never by its name: the name "Rushes" proves nothing, and the
  # hash is what every tester's Mac has recorded.
  IDENTITY="$(sed -n 's/^CERT_SHA1="\([0-9a-f]\{40\}\)"$/\1/p' install.sh | tr 'a-f' 'A-F')"
  if [ -z "$IDENTITY" ]; then
    echo "install.sh pins no certificate yet: run Tools/make-signing-certificate.sh first." >&2
    exit 1
  fi
  KEYCHAIN_ARGS=()
  if [ -n "${RUSHES_KEYCHAIN:-}" ]; then KEYCHAIN_ARGS=(--keychain "$RUSHES_KEYCHAIN"); fi
  # Without -v: a self-signed certificate is "not trusted", and codesign signs
  # with it all the same.
  if ! security find-identity -p codesigning ${RUSHES_KEYCHAIN:+"$RUSHES_KEYCHAIN"} | grep -qF " $IDENTITY \""; then
    echo "The certificate install.sh pins ($IDENTITY) is not in the keychain." >&2
    echo "Import the .p12 kept when it was made, rather than making another." >&2
    exit 1
  fi
  # The app is held to its identifier as well; the image's identifier is its
  # file name, so it is held to the certificate alone.
  IMAGE_REQUIREMENT="certificate leaf = H\"$(echo "$IDENTITY" | tr 'A-F' 'a-f')\""
  REQUIREMENT="identifier \"$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' Support/Info.plist)\" and $IMAGE_REQUIREMENT"
fi

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
# The About window shows Credits.rtf under the version by itself: the
# licence, the code, and the one place Rushes asks for support.
cp Support/Credits.rtf "$STAGE/Contents/Resources/Credits.rtf"

# Copying carries extended attributes across from Support/, so the bundle is
# cleaned first.
xattr -cr "$STAGE"

# Waits for Apple's answer on one file and staples the ticket to it, so the
# Mac that opens it needs no network to trust it. notarytool's exit status
# does not say "Invalid", its JSON does; the log says why.
notarise() {
  local file="$1" upload="$1" result="$SCRATCH/notary.json"
  if [ -d "$file" ]; then
    upload="$SCRATCH/$(basename "$file").zip"
    ditto -c -k --keepParent "$file" "$upload"
  fi
  xcrun notarytool submit "$upload" --keychain-profile "$PROFILE" --wait --output-format json > "$result"
  local status id
  status="$(plutil -extract status raw -o - "$result")"
  if [ "$status" != "Accepted" ]; then
    id="$(plutil -extract id raw -o - "$result")"
    echo "Notarisation of $(basename "$file"): $status" >&2
    xcrun notarytool log "$id" --keychain-profile "$PROFILE" >&2 || true
    exit 1
  fi
  xcrun stapler staple "$file"
}

if [ "$SIGNED" = 0 ]; then
  # Ad-hoc signature: enough to run here. macOS keys the removable volumes
  # permission to it, so a rebuild asks again.
  codesign --force --sign - "$STAGE"
elif [ "$SIGNED" = 2 ]; then
  # No --timestamp: Apple's server stamps only its own certificates.
  codesign --force --options runtime ${KEYCHAIN_ARGS[@]+"${KEYCHAIN_ARGS[@]}"} --sign "$IDENTITY" "$STAGE"
  codesign --verify --strict -R="$REQUIREMENT" "$STAGE"
elif [ "$IDENTITY" = "-" ]; then
  codesign --force --options runtime --sign - "$STAGE"
else
  # The hardened runtime is what notarisation asks for. Rushes needs no
  # entitlement under it: removable volumes go through the TCC prompt.
  codesign --force --options runtime --timestamp --sign "$IDENTITY" "$STAGE"
  notarise "$STAGE"
fi

# ditto carries neither extended attributes nor resource forks, so what lands
# in build/ is the signed bundle and nothing else. Attributes the Mac adds to
# it afterwards do not touch the signature; only signing minds them.
rm -rf "$APP"
mkdir -p build
ditto --noextattr --norsrc "$STAGE" "$APP"
codesign --verify --strict "$APP"

if [ "$SIGNED" = 0 ]; then
  echo "$(pwd)/$APP"
  exit 0
fi

# A .dmg with the app beside a shortcut to Applications: what a photographer
# expects to drag. The app inside is already stapled, so it opens offline
# once copied; the image is signed and stapled too, for the download itself.
DMG_NAME="Rushes-$VERSION.dmg"
DMG_STAGE="$SCRATCH/dmg"
DMG="$SCRATCH/$DMG_NAME"
rm -rf "$DMG_STAGE" "$DMG"
mkdir -p "$DMG_STAGE"
ditto --noextattr --norsrc "$STAGE" "$DMG_STAGE/Rushes.app"
ln -s /Applications "$DMG_STAGE/Applications"
hdiutil create -quiet -volname "Rushes $VERSION" -srcfolder "$DMG_STAGE" -fs HFS+ -format UDZO -ov "$DMG"
if [ "$SIGNED" = 2 ]; then
  codesign --force ${KEYCHAIN_ARGS[@]+"${KEYCHAIN_ARGS[@]}"} --sign "$IDENTITY" "$DMG"
elif [ "$IDENTITY" = "-" ]; then
  codesign --force --sign - "$DMG"
else
  codesign --force --timestamp --sign "$IDENTITY" "$DMG"
  notarise "$DMG"
fi

# What Gatekeeper will say on a Mac that downloaded it: the image, then the
# app copied out of it with the quarantine flag a browser would set.
CHECK="$SCRATCH/check"
rm -rf "$CHECK"
mkdir -p "$CHECK"
MOUNT="$(hdiutil attach -nobrowse -readonly -mountrandom "$CHECK" "$DMG" | awk -F'\t' '/\/Volumes|check/ { print $NF }' | tail -1)"
ditto "$MOUNT/Rushes.app" "$CHECK/Rushes.app"
hdiutil detach -quiet "$MOUNT"
xattr -w com.apple.quarantine "0081;$(printf '%x' "$(date +%s)");Safari;" "$CHECK/Rushes.app"
if [ "$SIGNED" = 2 ]; then
  # What install.sh will check on the tester's Mac, image and app.
  codesign --verify --strict -R="$IMAGE_REQUIREMENT" "$DMG"
  codesign --verify --strict -R="$REQUIREMENT" "$CHECK/Rushes.app"
  echo "Self-signed: Gatekeeper blocks a browser's download until \"Ouvrir quand même\"; install.sh does not." >&2
elif [ "$IDENTITY" = "-" ]; then
  echo "Signed ad hoc: Gatekeeper blocks this .dmg on another Mac until \"Ouvrir quand même\"." >&2
else
  spctl --assess --type open --context context:primary-signature -vv "$DMG"
  spctl --assess --type execute -vv "$CHECK/Rushes.app"
fi
rm -rf "$CHECK"

cp "$DMG" "build/$DMG_NAME"
# Beside the .dmg on the release page, in the form `shasum -c` reads.
(cd build && shasum -a 256 "$DMG_NAME" > "$DMG_NAME.sha256")
echo "$(pwd)/build/$DMG_NAME"
echo "$(pwd)/build/$DMG_NAME.sha256"
