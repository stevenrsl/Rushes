#!/usr/bin/env bash
# Installs or updates Rushes from its GitHub releases, from the Terminal:
#
#   curl -fsSL https://raw.githubusercontent.com/stevenrsl/Rushes/main/install.sh | bash
#   curl -fsSL https://raw.githubusercontent.com/stevenrsl/Rushes/main/install.sh | bash -s -- v0.6.0-beta.1
#
# Until Rushes has a Developer ID, the release is signed with a self-signed
# certificate (Tools/make-signing-certificate.sh) that Gatekeeper does not
# know, so a .dmg downloaded by a browser is blocked until "Ouvrir quand
# même". A file curl downloads carries no quarantine flag, so Gatekeeper is not
# asked; this script asks in its place, and installs nothing unless:
#   - the .dmg has the SHA-256 published beside it on the release, which says
#     the download is whole;
#   - the .dmg and the app inside are signed by the certificate pinned below,
#     for Rushes's bundle identifier, which says who made them. A release
#     replaced on GitHub by someone else fails here, whatever its SHA-256.
# It never removes a quarantine flag, never asks for a password, and never
# touches a Rushes that is running: a backup may be under way.
#
# RUSHES_DEST installs elsewhere than /Applications (~/Applications, say).
#
# Everything is in main, called on the last line, so a download cut short
# runs nothing.
set -euo pipefail

# Written by Tools/make-signing-certificate.sh; build.sh signs with it.
CERT_SHA1="7ad9ccc9e8634244b217ea10028554dce5a56bf3"
BUNDLE_ID="eu.stevenrsl.rushes"
REPO="stevenrsl/Rushes"

say() { printf '%s\n' "$*"; }
fail() { printf '\nRushes n’est pas installé : %s\n' "$*" >&2; exit 1; }

# The newest release that carries a .dmg and its .sha256, compared as the
# app's own update check compares them (0.10 after 0.9, 1.0 after 1.0-beta.2),
# or the one tagged. Prints its tag, the .dmg's name and both URLs.
pick_release() {
  osascript -l JavaScript -e '
    ObjC.import("Foundation");
    function version(tag) {
      const m = /^[vV]?([0-9.]+)(?:-(.+))?$/.exec(tag);
      return m ? { numbers: m[1].split(".").map(Number), pre: m[2] || "" } : null;
    }
    function compare(a, b) {
      for (let i = 0; i < Math.max(a.numbers.length, b.numbers.length); i++) {
        const d = (a.numbers[i] || 0) - (b.numbers[i] || 0);
        if (d) return d;
      }
      if (a.pre === b.pre) return 0;
      if (!a.pre) return 1;
      if (!b.pre) return -1;
      return a.pre.localeCompare(b.pre, undefined, { numeric: true });
    }
    function run(argv) {
      const text = $.NSString.stringWithContentsOfFileEncodingError(argv[0], $.NSUTF8StringEncoding, null);
      let answer = JSON.parse(text.js);
      if (!Array.isArray(answer)) answer = [answer];
      let best = null;
      for (const r of answer) {
        if (r.draft || !r.tag_name || !r.assets) continue;
        const v = version(r.tag_name);
        const dmg = r.assets.find(a => /^Rushes-.+\.dmg$/.test(a.name));
        const sum = dmg && r.assets.find(a => a.name === dmg.name + ".sha256");
        if (!v || !sum) continue;
        if (!best || compare(v, best.v) > 0) best = { v, r, dmg, sum };
      }
      if (!best) return "";
      return [best.r.tag_name, best.dmg.name, best.dmg.browser_download_url, best.sum.browser_download_url].join("\n");
    }' "$1"
}

main() {
  local tag="${1:-}" dest="${RUSHES_DEST:-/Applications}"

  [ "$(uname -s)" = Darwin ] || fail "Rushes est une app pour Mac."
  case "$CERT_SHA1" in
    *[!0-9a-f]*|"") fail "ce script ne connaît pas encore le certificat de Rushes. Télécharge le .dmg depuis https://github.com/$REPO/releases." ;;
  esac
  [ "${#CERT_SHA1}" = 40 ] || fail "le certificat attendu par ce script est mal écrit."
  # The image's own identifier is its file name, so it is held to the
  # certificate alone; the app to Rushes's identifier as well.
  local image_requirement="certificate leaf = H\"$CERT_SHA1\""
  local requirement="identifier \"$BUNDLE_ID\" and $image_requirement"

  if pgrep -xq Rushes; then
    fail "Rushes est ouvert. Quitte-le (une sauvegarde est peut-être en cours), puis relance cette commande."
  fi
  [ -d "$dest" ] && [ -w "$dest" ] || fail "impossible d’écrire dans $dest. Essaie avec RUSHES_DEST=~/Applications devant bash."

  local work
  work="$(mktemp -d)"
  # The image is detached and the folder removed whatever happens.
  trap 'hdiutil detach -quiet "'"$work"'/mnt" 2>/dev/null || true; rm -rf "'"$work"'"' EXIT

  local api="https://api.github.com/repos/$REPO/releases?per_page=30"
  [ -n "$tag" ] && api="https://api.github.com/repos/$REPO/releases/tags/$tag"
  say "Recherche de la version${tag:+ $tag} sur GitHub…"
  curl -fsSL --proto '=https' -H 'Accept: application/vnd.github+json' -o "$work/releases.json" "$api" \
    || fail "GitHub ne répond pas${tag:+, ou la version $tag n’existe pas}."

  local picked name dmg_url sum_url
  picked="$(pick_release "$work/releases.json")"
  [ -n "$picked" ] || fail "aucune version publiée n’a de .dmg avec son .sha256."
  { read -r tag; read -r name; read -r dmg_url; read -r sum_url; } <<<"$picked"
  case "$dmg_url$sum_url" in
    *[[:space:]]*) fail "GitHub a répondu une adresse inattendue." ;;
  esac
  case "$name" in
    */*|.*) fail "GitHub a répondu un nom de fichier inattendu." ;;
  esac

  say "Téléchargement de $name…"
  curl -fL# --proto '=https' -o "$work/$name" "$dmg_url" || fail "le téléchargement de $name a échoué."
  curl -fsSL --proto '=https' -o "$work/$name.sha256" "$sum_url" || fail "le téléchargement de $name.sha256 a échoué."

  local expected actual
  expected="$(awk 'NR == 1 { print tolower($1) }' "$work/$name.sha256")"
  actual="$(shasum -a 256 "$work/$name" | awk '{ print $1 }')"
  [ "${#expected}" = 64 ] || fail "le fichier $name.sha256 ne contient pas d’empreinte."
  [ "$expected" = "$actual" ] || fail "$name n’a pas l’empreinte SHA-256 publiée : le téléchargement est abîmé ou ce n’est pas le bon fichier."
  say "Empreinte SHA-256 vérifiée."

  codesign --verify --strict -R="$image_requirement" "$work/$name" 2>/dev/null \
    || fail "$name n’est pas signé par le certificat de Rushes. Rien n’a été installé."

  mkdir "$work/mnt"
  hdiutil attach -quiet -nobrowse -readonly -noautoopen -mountpoint "$work/mnt" "$work/$name" 2>/dev/null \
    || fail "impossible d’ouvrir $name."
  local app="$work/mnt/Rushes.app"
  [ -d "$app" ] || fail "$name ne contient pas Rushes.app."
  codesign --verify --strict --deep -R="$requirement" "$app" 2>/dev/null \
    || fail "l’app dans $name n’est pas signée par le certificat de Rushes. Rien n’a été installé."
  say "Signature vérifiée : certificat Rushes ${CERT_SHA1:0:8}…"

  local needed have
  needed="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$app/Contents/Info.plist" 2>/dev/null || echo 0)"
  have="$(sw_vers -productVersion)"
  if [ "${have%%.*}" -lt "${needed%%.*}" ]; then
    fail "Rushes $tag demande macOS $needed ou plus récent, ce Mac a macOS $have."
  fi

  # Copied beside its final place, checked again there, then swapped in, so
  # a copy cut short never leaves a half Rushes.app in Applications.
  local staged="$dest/.Rushes.app.installing"
  rm -rf "$staged"
  ditto "$app" "$staged" || fail "la copie dans $dest a échoué."
  codesign --verify --strict --deep -R="$requirement" "$staged" 2>/dev/null \
    || { rm -rf "$staged"; fail "la copie dans $dest ne se vérifie pas."; }
  if pgrep -xq Rushes; then
    rm -rf "$staged"
    fail "Rushes vient d’être ouvert. Quitte-le, puis relance cette commande."
  fi
  rm -rf "$dest/Rushes.app"
  mv "$staged" "$dest/Rushes.app"

  say ""
  say "Rushes $tag est installé dans $dest."
  say "Ouvre-le depuis $dest. S’il demande l’accès aux volumes amovibles, accepte : sans lui, les cartes n’apparaissent pas."
}

main "$@"
