# Rushes

A native macOS app that offloads camera cards at the end of a shoot: it reads every card
plugged in, whatever the brand, renames each shot `YYMMDD_XX_Client_Projet_0001`, sorts RAW,
JPEG and video into folders, copies to one or two drives at once and proves every copy before
saying it is done. Made for 3 in the morning: plug the card, check the client and project,
press ⌘↩, go to bed. Started on 2026-09-21.

The interface is in French. Code, comments and this file are in English. Same build as Cairn
and Journal's Mac app: SwiftPM without Xcode, `build.sh` assembles the bundle.

```bash
./build.sh                                          # release build → build/Rushes.app
./build.sh debug
swift test --scratch-path /tmp/rushes-build         # 48 tests and a bench skipped unless asked
RUSHES_BENCH=1 swift test -c release -Xswiftc -enable-testing --scratch-path /tmp/rushes-release --filter Bench
swift Tools/make-icon.swift "$(pwd)"                # redraws Support/AppIcon.icns
swift Tools/make-test-card.swift sony /Volumes/X    # a fake card to try the app (also `canon`, `dji`)
```

`swift test` and `swift build` need `--scratch-path` outside Documents: the folder is synced,
its file provider puts extended attributes on the build products and codesign refuses them
(the same trap as Cairn). `build.sh` builds in `/tmp/rushes-build` for that reason, and in
release by default because the checksum runs over every byte of every card.

## The rules that shape everything

**A card is only ever read.** Nothing is moved, renamed, written or deleted on a card, ever.
Formatting is the camera's job, once the backup is verified.

**Nothing on a drive is ever replaced.** A copy is written as `.<name>.rushes-partial` beside
its final name, read back, and named only if it matches, with `renamex_np(…, RENAME_EXCL)`.
exFAT and FAT32, the format the drives are sold in, answer `ENOTSUP` to that call, so there the
final name is reserved with `open(O_CREAT|O_EXCL)` first and the copy renamed over that
reservation: still atomic, still never an overwrite (`Copier.name`, measured 2026-09-22 on
exFAT images; before that fix every copy was checked and then deleted for want of a name). A
name already taken is a conflict that holds the whole backup back. A copy cut off (cable,
cancel, full disk) leaves no file that looks finished.

**Verified means read back from the drive.** The card is read once in 8 MB chunks; each chunk
is hashed (XXH64) and written to every drive in parallel while the next is read. Each drive's
copy is then read again and hashed. Reads and writes use `F_NOCACHE`: reading back from memory
would prove nothing. Measured 2026-09-21 on the internal SSD: XXH64 at ~24 GB/s, 2 GB copied to
two folders and checked in 2.8 s, so the card reader is always the limit.

**The drive keeps the history, not the Mac.** Each backup writes `_RUSHES/<yyMMdd-HHmmss>.json`
and `.csv` in the shoot's folder on every drive: card path, new path, size, xxh64, fingerprint.
It is the only place the camera's names survive the renaming ("the client wants DSC01234"), and
it travels with the folder when the shoot is archived. There is no database.

Beside it, `_RUSHES/journal.jsonl` at the **drive's root** holds one line per file, appended and
flushed the moment that file is verified, between a `start` and an `end` line per backup
(`Journal`, `DriveJournal`). The manifests are written when a backup ends, which is too late for
three questions: what survived a backup that never ended (a `start` with no `end` is resumed,
and skipping is forced for what it verified, whatever the setting says); where a shot went
whatever it was filed under (rename the client and yesterday's card is still recognised, and
stays in yesterday's folder); and which numbers are already spoken for (sort out some rejects or
empty the drive, and those numbers are still not handed out twice). It is derived: every line is
also in a manifest, so deleting it costs those three answers until the next backup, never a
file. It is read once per state of itself and kept in memory, because a plan is made again at
every keystroke.

**A shot is skipped only if every drive still has it.** The manifest is a memory, not a proof:
a file it lists is counted as saved only if it is lying at its path, at its size
(`DestinationIndex`). Sorted out by hand, moved to an archive, or on a drive emptied for the
trip, and it is copied again. On one drive but not the other, likewise (with new numbers on the
first): duplicates are tidiness, a missing copy is loss. That check is why Steven ticked
"copier à nouveau" in the first place (2026-09-22: "par peur de louper des data"); the setting
is still his.

**Nothing is left out silently.** Unticked kinds, proxies, thumbnails, orphan files (Sony's
MEDIAPRO.XML) and files of a kind nobody listed are all listed under "Laissés sur la carte"
with the reason. A folder the Mac refuses to open is named too: that card was not read whole,
so it is never ejected and the pages say so, but it does not hold the backup back, because
rushes that can be saved tonight are saved tonight.

## Layout

```
Sources/Rushes/
  Model/      MediaFile (roles, extensions per brand), Grouping (DCF objects), CardScanner
              (+ CameraBrand), CaptureDates (EXIF via ImageIO), Cameras (identity, letters),
              Naming (ShootDay, NameTemplate, presets, Sanitize, FolderLayout), Settings,
              Plan (Planner, DestinationIndex), History, Journal (per-drive record)
  Transfer/   XXHash64, Copier (one file, every drive, checked), Backup (a whole plan +
              manifests), Volumes (mount watching, free space, eject)
  App/        RushesApp (+ AppDelegate: quitting mid-backup is asked), Ingest (the observable
              model: cards, drives, plan, backup, notifications, sleep assertion)
  Design/     Palette (Cairn's tokens, forest in pastel, TypeScale, Radius), Components (Cairn's
              page frame, PageTrail, PageSection, Field, chips, accent buttons, checkbox)
  Views/      RootView (+ PrepareView, ActionBar), CardsColumn, PreparePanels (shoot, drives,
              naming blocks), PreviewTable, TransferViews (copying, done), SettingsView (tabs)
Tests/        Swift Testing: hash (vectors + zstd), grouping per brand, naming, planner, backup,
              camera letters
Tools/        make-icon.swift, make-test-card.swift
```

## Cards and brands

The scanner walks the whole card and classifies by extension, so a camera nobody listed still
works. Hidden files and the cameras' housekeeping folders (MISC, AVF_INFO, DATABASE, CANONMSC,
GENERAL, CLIPINF, PLAYLIST…) are skipped. A mounted volume is a card when it has DCIM, XDROOT,
CONTENTS, PRIVATE/M4ROOT|AVCHD|XDROOT, or BRAW/R3D at its root. Anything else can be added by
hand ("Ajouter un dossier…").

**Pairing is the DCF rule** (JEITA CP-3461): files sharing a folder and a base name are one
shot, one number. DSC01234.JPG + .ARW, IMG_0001.CR3 + .JPG + .HIF, DJI_0001.MP4 + .SRT + .LRF,
Nikon's DSC_0001.NEV + its .MP4 proxy + .DAT. The folder is part of the key because Canon starts
IMG_0001 again in 101CANON. Two brands need help (`Grouping.key`):

- **Sony XAVC** spreads a clip over `PRIVATE/M4ROOT/{CLIP,SUB,THMBNL}` with suffixes:
  C0001.MP4, C0001M01.XML, SUB/C0001S03.MP4 (proxy), THMBNL/C0001T01.JPG (a thumbnail, not a
  photo). Same for XDROOT on the FX6/FX9. The rule applies only under those roots.
- **GoPro** changes the second letter for the proxy: GX010042.MP4 and GL010042.LRV. Only in
  `NNNGOPRO` folders. Chapters (GX01…, GX02…) stay separate shots.

A companion keeps what its own name has beyond its anchor's: C0001M01.XML becomes
`…_0001M01.XML` beside `…_0001.MP4`, the convention Sony's software pairs by.

## Kinds of file

The Fichiers block lists every kind of file on the cards in use, by family (photos, videos,
sounds, metadata, proxies, thumbnails), each ticked or not in one click; Steven asked on
2026-09-21 to keep ARW, JPG, MP4 and MOV and leave the XML of a Sony card. A kind is a role and
an extension (`FileKind`), not an extension alone: Sony's SUB/C0001S03.MP4 is a proxy, so
unticking MP4 clips leaves proxies to their own choice. Choices are kept by kind id in
`settings.kindChoices`; a kind never touched is copied, except proxies, thumbnails and XML. They
replaced the three "fichiers annexes" switches of the first version.

Within a shot, only ticked files go, and the anchor is chosen among them: without the JPEG the
RAW keeps its number, without the RAW the XMP moves beside the JPEG. A shot none of whose
pictures, clips or sounds is ticked stays on the card with its sidecars (`GroupStatus.unticked`)
and takes no number, so the numbering stays continuous.

## Names

`NameTemplate` reads `{TOKEN}` patterns: YYMMDD, YYYYMMDD, HHMMSS, INIT, CLIENT, PROJET, CAM,
NUM, ORIG, TYPE (plus French aliases). Presets: Caméra au bout
`{YYMMDD}_{INIT}_{CLIENT}_{PROJET}_{NUM}_{CAM}` (the default), Standard `{YYMMDD}_{INIT}_{CLIENT}_{PROJET}_{NUM}`,
Multicam (`…_{CAM}{NUM}`), with the original name, long date. Anything typed is a custom pattern.
A pattern must hold `{NUM}` or `{ORIG}`.

- **Fields are made safe**: `Sanitize.field` folds to ASCII, drops apostrophes, keeps
  underscores as typed and turns every run of anything else into one hyphen. "Café d'Été" →
  `Cafe-dEte`, "RX_500h" → `RX_500h`. The first version turned underscores into hyphens too, as
  the separator of the name's fields; Steven wanted to type them (2026-09-21), and nothing reads
  a name back by splitting it. Initials and camera letters (`Sanitize.code`) keep letters and
  digits only.
- **A night shoot keeps its day.** Until the cutoff hour (5 h by default), a shot belongs to
  the day before (`ShootDay`). The day can also be fixed by hand for one backup (not remembered).
- **Numbers follow the order shots were taken**, every card together, and carry on after the
  highest already on the drives for the same day, client and project (`counterExpression`
  matches the pattern with the number captured). With `{CAM}` in the name, each camera counts on
  its own, as A-cam and B-cam do on a set (decided 2026-09-21). Photos and videos share one
  counter unless the setting says otherwise.
- **Dates**: EXIF DateTimeOriginal from the group's JPEG (fastest header) for photos, read in
  parallel; the file system's date (earlier of creation and modification = start of recording)
  for video, because many cameras write local time where MP4 says UTC. All read as the camera's
  wall clock in the Mac's time zone.
- **The fingerprint** of a file is its card name, size and modification time in whole seconds.

Folders: the shoot's folder is a pattern (`{YYMMDD}_{CLIENT}_{PROJET}` by default, `/` for a
subfolder, a menu of common ones beside it). Inside it, `FolderLayout` holds one path pattern
per kind (RAW, JPEG, HEIF, video, proxy, sound), with the name's tokens: `VIDEO/{CAM}` puts
each camera apart. Presets (`FolderPreset`): Par type (`PHOTO/RAW`, `PHOTO/JPG`, `PHOTO/HEIF`,
`VIDEO`, `VIDEO/PROXY`, `AUDIO`, the default), Par caméra, Photo et vidéo (RAW and JPEG side by
side), Sans PHOTO/, Tout ensemble; any edit is "Personnalisé". The first version saved the
layout as a name ("byType"), still read. Sidecars go beside their anchor (an XMP beside its RAW).
A typed token used in a folder blocks the button when empty, as in the name.

**Defaults are Steven's own settings** (asked 2026-09-22): Caméra au bout, separate
counters for photos and videos, already-saved shots skipped, XML left on the card, cards
ejected. Skipping was off at first, because Steven did not trust a record to prove a file was
there ("par peur de louper des data", 2026-09-22); it went on the same day, once skipping meant
the file had been found on every drive at its size rather than merely listed. Nothing personal is written in: initials start empty
(the placeholder is SR), client and project examples are Kaffi and Lexus. Tests written for the
old defaults pin them in their fixtures.

## Camera letters

`{CAM}` is a letter per camera, typed on the card's badge in the column (A, D, B2: three
characters at most). Steven asked on 2026-09-21 for A on the A7 IV and D on the drone, every
night without typing it, so a letter typed by hand is remembered for that body
(`settings.cameras`, `CameraLetters`). A body is its EXIF model plus BodySerialNumber when the
camera writes one, so two A7 IV are two cameras; else the model; for a video-only Sony card, the
`<Device modelName serialNo>` of the first clip's M01.XML; else the brand. A card of a known
camera takes its letter back once read, unless another card of this backup already shows it; a
new camera gets the first letter no card shows and no known camera holds, so it never borrows the
drone's D. The Caméras tab of the settings renames or forgets them.

## Design

Cairn's design system (the "Laine" redesign of 2026-09-21), which Steven asked for in forest
green, then the same day, through a design review, softer: "sobre, minimaliste, serif et
sans-serif, couleurs pastels". What holds from Cairn: OKLCH tokens by role, six type sizes with
serif titles (New York) and sans for everything that is read or typed, `PageScroll`,
`PageTrail` above a display title and an italic sentence, capsule `.accentFilled` for the one
button, `.accentLink` for the rest, a drawn checkbox, the wash at the top, `late` (peat) and
`alert` (sea thrift) as signals.

- **One sheet, not cards.** The preparation page was five bordered blocks; it is now
  `PageSection`s on the ground, a hairline between them, each name in serif in a 150 pt column
  and its content in sans beside it (stacked when the window is narrow). Only the preview table
  keeps a container, because its rows scroll. The copying and done pages follow.
- **Pastel, in three roles**, because a pastel cannot carry text: `accent` is the pastel sage
  that fills (the button, a chosen chip, a ticked kind) with `onAccent` on it; `accentInk` the
  deep forest that writes (links, what is saved); `accentLine` the green that draws (bars,
  strokes, a checkbox's edge). Camera badges are pastel fills with a deep ink of the same hue.
  Every pair was measured: text at 4.52:1 at worst, `onAccent` on `accent` 9:1, bars against
  their track 3.17:1.
- **Quiet copy.** At most one middle dot a line; sentences rather than lists of fragments; no
  em dash anywhere. The camera's "lettre retenue" is in the badge's tooltip, not a line of its own.
- **States**: "Lecture des cartes…" while scanning, "Préparation de l'aperçu…" while the plan is
  made, rather than a false "rien à copier".

The icon is drawn from the same colours (`Tools/make-icon.swift`).

## Before ⌘↩

The plan carries the drives it counted and the change it was made from, and the button waits
for both to be current: a project typed a second before ⌘↩ used to be copied under the name
before it, and a drive plugged in at the last moment used to receive a plan that had never
looked at it. The action bar also holds back a name whose `.rushes-partial` would be too long
for the drive, two destination folders that turn out to be one disk, and a disk without a
margin over the bytes to copy. What it cannot hold back it says anyway, in the same line.

## At night

The backup holds a `ProcessInfo` activity: the Mac does not idle-sleep (the screen may). A
notification with sound says when it is done ("Tu peux aller dormir"); verified cards are
ejected. Quitting mid-backup asks. What was checked before a cancel or a failure is in the
manifest, so "Reprendre" copies only the rest: after a cut-off or failed backup the plan skips
what every drive has, even with "Ignorer ce qui est déjà sauvegardé" off (`Ingest.resuming`). A
card left unticked does not hold the button while it is read. Appearance can be forced dark in Settings
(Copie tab).

The first launch asks for removable volumes access (`NSRemovableVolumesUsageDescription`); the
ad-hoc signature means every rebuild asks again, as Cairn's microphone does.

## Not done yet

- **A camera plugged by USB.** Only mounted volumes are read: a card reader, or a camera in
  mass-storage mode. Canon bodies (and iPhones) speak PTP only, which needs ImageCaptureCore,
  is several times slower than a reader and hides Sony's XML. A reader is the recommendation.
- An ASC MHL file beside the JSON manifest, for DITs and post houses.
- An option to keep an untouched dump of the card's structure next to the renamed files, for
  spanned clips (AVCHD, XF-AVC across cards) that editing software rebuilds from the structure.
- Opening by itself when a card is inserted (a login item watching mounts).
