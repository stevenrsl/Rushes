# Rushes

A native macOS app that offloads camera cards at the end of a shoot: it reads every card
plugged in, whatever the brand, renames each shot `YYMMDD_XX_Client_Projet_0001`, sorts RAW,
JPEG and video into folders, copies to one or two drives at once and proves every copy before
saying it is done. Made for 3 in the morning: plug the card, check the client and project,
press ⌘↩, go to bed. Started on 2026-09-21.

The interface is in French. Code, comments and this file are in English. Free software under
GPL-3.0 (`LICENSE`, chosen 2026-10-01 so nobody sells it closed under another name); everything
is written for Rushes, with no dependency. Same build as Cairn
and Journal's Mac app: SwiftPM without Xcode, `build.sh` assembles the bundle.

```bash
./build.sh                                          # release build → build/Rushes.app
./build.sh debug
./build.sh release-signed                           # Developer ID, notarised, build/Rushes-<version>.dmg
./build.sh release-selfsigned                       # the beta's .dmg: self-signed "Rushes", not notarised
Tools/make-signing-certificate.sh ~/backup.p12      # that certificate, made once; pins it in install.sh
swift test --scratch-path /tmp/rushes-build         # 135 tests; benches and snapshots skipped unless asked
RUSHES_BENCH=1 swift test -c release -Xswiftc -enable-testing --scratch-path /tmp/rushes-release --filter Bench
swift Tools/make-icon.swift "$(pwd)"                # redraws Support/AppIcon.icns
swift Tools/make-test-card.swift sony /Volumes/X    # a fake card to try the app (also `canon`, `dji`)
RUSHES_SNAPSHOTS=/tmp/snaps swift test --scratch-path /tmp/rushes-build --filter SnapshotTests  # pages as PNG
```

`swift test` and `swift build` need `--scratch-path` outside Documents: the folder is synced,
its file provider puts extended attributes on the build products and codesign refuses them
(the same trap as Cairn). `build.sh` builds in `/tmp/rushes-build` for that reason, and in
release by default because the checksum runs over every byte of every card. The bundle is
assembled and signed there too, then copied into `build/` with `ditto --noextattr --norsrc`:
under Documents the attributes come back between the clean and the signature, the file provider
adding its own and LaunchServices tagging an app that has been run. Signing outside, then
copying, is what makes a rebuild after a run work at all.

## The rules that shape everything

**A card is only ever read.** Nothing is moved, renamed, written or deleted on a card, ever,
by the backup. Formatting is the camera's job, once the backup is verified, with one door Steven
opened on 2026-10-15: with Copie › "À la fin, les cartes formatables" set to "Proposer de les
formater", the done page offers "Formater…" on each card told formatable, one at a time, after a
destructive confirmation (`Ingest.format`, `VolumeWatcher.format`). Everything is checked again
at that moment: the card's volume serial is the one read before the backup (`Card.identity`,
`verifiedIdentities`, since two cards swapped in a reader mount at the same path), it is still
mounted there, it is ejectable or removable media, it is not a destination, and it is exFAT or
FAT. Then `diskutil eraseVolume` with its own file system and name, and an eject. Never a card
"à vérifier" or "ne pas formater", never by itself, never several at once. A second door, the
same setting, opened on 2026-10-16: "Supprimer les fichiers copiés…" deletes from a card only
what is on every drive (`CardCleanup`, `Ingest.deleteCopied`), for bodies that keep settings or
a clip nobody ticked on the card. Offered on a card "formatable" or "à vérifier" (what makes it
"à vérifier" is never in the list), never "ne pas formater". At that moment the volume serial is
checked again, and each file must still have on the card the size and date it was copied with
and lie on every drive at that size, or it stays; an already-saved shot counts only where the
journal can still place its copy on every drive. Unlinked, not moved to a trash.

**Nothing on a drive is ever replaced.** A copy is written as `.<name>.rushes-partial` beside
its final name, read back, and named only if it matches, with `renamex_np(…, RENAME_EXCL)`.
exFAT and FAT32, the format the drives are sold in, answer `ENOTSUP` to that call, so there the
final name is reserved with `open(O_CREAT|O_EXCL)` first and the copy renamed over that
reservation: still atomic, still never an overwrite (`Copier.name`, measured 2026-09-22 on
exFAT images; before that fix every copy was checked and then deleted for want of a name). A
name already taken is a conflict that holds the whole backup back. A copy cut off (cable,
cancel, full disk) leaves no file that looks finished.

**A card is told whether it may be formatted, one card at a time.** At the end of a backup each
card gets a verdict (`Verdicts.of`): formatable when every ticked file of that card was copied
and verified, "à vérifier" when something is on it that nobody could have ticked (a file of a
kind Rushes does not know, or a picture found hidden or in the camera's housekeeping), "ne pas
formater" when a file failed, the card was read in part, a name was already taken, the backup
stopped before reaching the end of it, or a drive would not confirm its writes. One card failing
says nothing about the next. A card told "ne pas formater" is never ejected. The verdict is
judged on the plan that ran (`runningPlan`), never on one made since; no plan is made while
copying. Before any of this is shown, every drive is synced whole with
`sync_volume_np(FULLSYNC | WAIT)`, falling back to `F_FULLFSYNC` (`Journal.flushDevice`): each
copy was fsynced before it was named, and on exFAT the folder entries holding the names can sit
in the Mac's cache for half a minute (council of 2026-09-28). The sentence "tu peux formater"
exists nowhere else, and never for all the cards at once; the format offered from the done
page follows it card by card.

**Verified means read back from the drive.** The card is read once in 8 MB chunks; each chunk
is hashed (XXH64) and written to every drive in parallel while the next is read. Each drive's
copy is then read again and hashed, one drive after the other. Reads and writes use
`F_NOCACHE`: reading back from memory would prove nothing. The bytes read from the card must
equal the size the scan saw: a reader that gives up says "end of file", and a copy of what it
gave would check out against itself. A copy is named on every drive or on none. Measured
2026-09-21 on the internal SSD: XXH64 at ~24 GB/s, 2 GB copied to two folders and checked in
2.8 s. Reading the drives back in parallel was tried on 2026-09-29 and was two to three times
slower on one SSD; on two separate hard drives the read-back, not the card, may be the limit,
which only real drives can settle.

**The drive keeps the history, not the Mac.** Each backup writes `_RUSHES/<yyMMdd-HHmmss>.json`
and `.csv` in the shoot's folder on every drive: card path, new path, size, xxh64, fingerprint.
Beside them, `rapport-<stamp>.html` is the same night for a person: each card's verdict and
every file with its camera name, self-contained, printable (`TransferReport`, written by
`Ingest` once the verdicts are known). With the setting on, an ASC MHL generation goes into the
shoot's `ascmhl/` folder, the standard's place, sealed in `ascmhl_chain.xml` by C4 (`ASCMHL`,
checked against the ascmitc/mhl XSDs and example chain).
It is the only place the camera's names survive the renaming ("the client wants DSC01234"), and
it travels with the folder when the shoot is archived. There is no database.

Beside it, `_RUSHES/journal.jsonl` at the **drive's root** holds one line per file, appended and
flushed the moment that file is verified, between a `start` and an `end` line per backup
(`Journal`, `DriveJournal`). The manifests are written when a backup ends, which is too late for
three questions: what survived a backup that never ended (a `start` with no `end`, or an `end`
with `complete: false`, not followed by a complete backup, is resumed, and skipping is forced
for what it verified, whatever the setting says; before 2026-09-28 one failed file forced it
for good); where a shot went
whatever it was filed under (rename the client and yesterday's card is still recognised, and
stays in yesterday's folder); and which numbers are already spoken for (sort out some rejects or
empty the drive, and those numbers are still not handed out twice). It is derived: every line is
also in a manifest, so deleting it costs those three answers until the next backup, never a
file. It is read once per state of itself and kept in memory, because a plan is made again at
every keystroke. Since 0.5 a `start` line also says who the backup was for (client, project,
initials as typed, and its shoot days), so a card brought back in the evening is told which
shoot it carries on (`ShootContinuation`, asked 2026-10-16): the backup that already holds some
of its shots, else the last one of the same shoot day. The Tournage section says it, and when
the fields name another shoot offers "Reprendre ce tournage", which puts the client and project
back so the numbers carry on in the same folder. Older journals, without those fields, offer
nothing.

**Each drive may receive only some kinds** (asked 2026-10-16 for 0.6): the photos on one disk
and the videos on another, or in two folders of one. Destinations shows a "Reçoit" menu per
drive (Tout, or any of Photos, Vidéos, Sons), kept in `settings.destinationKinds` by path, absent
meaning everything. Each `PlannedGroup` carries its `drives`; everywhere below that says "every
drive", read "every drive that receives this kind of shot": the copy, its journal line, the
skip, the name conflicts, the room and FAT32 checks, the cleanup. Numbers still count against
every drive, so no two shots share one. Each drive's manifest, CSV, MHL and HTML report list what
that drive holds and nothing else (`BackupReport.onDrives`), since the audit reads them back
against it; the send takes each file from the first drive that holds it, and a second drive's
records with its name added. A kind no drive receives is a `noDrive` shot: it holds the button
("Aucun disque ne reçoit les vidéos") and its card "ne pas formater". Two folders on one volume
are refused only when they share a kind. The page says how many copies each kind gets, and
that what sits on one drive has no second copy.

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

**The drive can be asked again, months later.** File › Vérifier un disque (`Audit`,
`AuditView`) walks a drive or a shoot folder for its `_RUSHES/*.json`, reads every listed file
back around the cache and names what is gone, resized or reads differently, with the camera
name to look for. It only ever reads. Manifests, not the journal: an archived shoot keeps the
first and leaves the second behind.

## Layout

```
Sources/Rushes/
  Model/      MediaFile (roles, extensions per brand), Grouping (DCF objects), CardScanner
              (+ CameraBrand), CaptureDates (EXIF via ImageIO), Cameras (identity, letters),
              Naming (ShootDay, NameTemplate, presets, Sanitize, FolderLayout), Settings,
              Plan (Planner, DestinationIndex), History, Journal (per-drive record), Verdict,
              Readiness (what holds ⌘↩), Report (the HTML page), MHL (ASC MHL v2),
              Continuation (the shoot an evening's card carries on),
              Diagnostic (a card described for a beta tester to send)
  Transfer/   XXHash64, Copier (one file, every drive, checked), Backup (a whole plan +
              manifests), Audit (a drive read back against its records), Volumes (mount
              watching, free space, file system, eject, the guarded format), Cleanup
              (copied files deleted from a card, each checked again), Upload (the copy
              sent elsewhere: a synced folder or FTP/FTPS through curl, Keychain),
              Throughput (the speed over a backup, in bins, for the curve)
  App/        RushesApp (+ AppDelegate: quitting mid-backup is asked), Ingest (the observable
              model: cards, drives, plan, backup, notifications, sleep assertion), Feedback
              (the Aide menu: describe a card, report a problem, write)
  Design/     Palette (Cairn's tokens per Ambiance, forest in pastel, TypeScale, Radius, Theme),
              Components (Cairn's
              page frame, PageTrail, PageSection, Field, chips, accent buttons, checkbox)
  Views/      RootView (+ PrepareView, ActionBar), CardsColumn, PreparePanels (shoot, drives,
              naming blocks), PreviewTable, TransferViews (copying, done, sending), SettingsView
              (tabs: Rangement, Caméras, Copie, Envoi, Apparence),
              AuditView (+ AuditModel, its own window)
Tests/        Swift Testing: hash, grouping per brand, naming, planner, backup, copier edges,
              scanner, journal, verdicts, readiness, report, audit, ASC MHL, file systems
              (hdiutil exFAT/FAT32 images), camera letters, settings, upload
Tools/        make-icon.swift, make-test-card.swift, make-signing-certificate.sh
docs/         the council's notes (French), relecture.md (the guide for an outside review of the core)
```

## Cards and brands

The scanner walks the whole card and classifies by extension, so a camera nobody listed still
works. The Mac's dot files are skipped. The cameras' housekeeping folders (MISC, AVF_INFO,
DATABASE, CANONMSC, GENERAL, CLIPINF, PLAYLIST, BACKUP…) and files flagged hidden (the DOS
attribute on FAT and exFAT) are walked but never copied: a picture, clip or sound found there is
listed (`setAside`) and makes the card "à vérifier"; previews (THM, THMBNL, caches) are not
counted. Until 2026-09-28 they were skipped outright, and a card could be called formatable with
pictures the scan never saw. A file whose attributes will not read makes the card one read in
part. A mounted volume is a card when it has DCIM, XDROOT,
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
Multicam (`…_{CAM}{NUM}`), with the original name, long date. Anything typed is a custom pattern,
which "Enregistrer ce modèle…" keeps under a name of one's own (`settings.namePresets`, asked
2026-10-16): a chip beside the built-in ones, renamed or deleted from its context menu.
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

**A default that changes has to travel.** Settings already saved hold the values of the day they
were written, so changing a default in the code reaches new installs only. Each change that has
to reach an existing one gets a number in `IngestSettings.schema` and a line in `migrate`,
applied once on the next launch and written straight back. Only a default whose old value would
now be wrong belongs there, never a choice someone made on purpose: schema 2 (2026-09-22) turns
"Ignorer ce qui est déjà sauvegardé" on, because what it means changed underneath it.

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
- **Signals in a list** (2026-10-16): a card's verdict is a `StatusPill`, its colour on a wash
  of itself (`lateSoft`, `alertSoft`, `accentSoft`, all measured at 4.5:1 or more), icons in a
  column of one width. A small cross is a `RemoveButton`, 22 pt to click. A control held while
  copying looks held (the checkbox, "Ajouter un dossier…"). Settings say their help in the
  section's footer, never as a row of the section.
- **States**: "Lecture des cartes…" while scanning, "Préparation de l'aperçu…" while the plan is
  made, rather than a false "rien à copier".

- **Ambiances** (asked 2026-10-15, "custom l'ambiance graphique"): Réglages › Apparence offers
  Forêt (the original, number for number), Océan, Lavande and Ardoise, and titles with or
  without serifs. Presets, not a colour picker, because a pastel picked by hand cannot be
  promised to carry text. Each `Ambiance` moves the hues of `Palette.Tokens` and keeps their
  lightness; all four were measured like the forest (worst: `inkFaint` on `groundSunk` 4.64:1,
  `alert` on `groundSunk` 4.50:1, within sRGB). `late`, `alert` and the camera hues are the same
  in every ambiance. The tokens are read through `Theme.shared`, an `@Observable`, so a change
  redraws every window; `Ingest` keeps it equal to the settings.

The icon is drawn from the same colours (`Tools/make-icon.swift`), always the forest.

**Support is asked in one place.** Rushes is free; the About window (`Support/Credits.rtf`, Ko-fi
only since 2026-10-15, Steven's request), the README and `.github/FUNDING.yml` (GitHub Sponsors
and Ko-fi) say how to support it. Never on the
preparation page nor while copying, and not on the done page during the beta (Steven,
2026-10-01). The credits set no colour, so dark mode reads them.

## Before ⌘↩

The plan carries the drives it counted and the change it was made from, and the button waits
for both to be current: a project typed a second before ⌘↩ used to be copied under the name
before it, and a drive plugged in at the last moment used to receive a plan that had never
looked at it. The action bar also holds back a name whose `.rushes-partial` would be too long
for the drive, two destination folders that turn out to be one disk, and a disk without a
margin over the bytes to copy, and a FAT32 drive when a clip is over 4 GB (`EFBIG` would stop
the night). What it cannot hold back it says anyway, in the same line. These rules are
`Readiness`, a plain value with a test per rule. A plan is made off the main thread, with the
preview's rows (`PreviewRows`) and the shoot it continues; the page only reads what is ready.
A setting a plan never reads (`plansLike`) makes none, and the scan's ticks are paced to ten a
second: changing settings while a card of thousands of photos was read used to freeze the window
(2026-10-16; `PlanBench` measures it, 520 ms then 150 ms for 10 000 shots). The preview table
shows ten rows, "Tout afficher" the rest: a table of ten thousand rows was laid out again at
every setting changed and froze the window (reported 2026-10-17); the chips keep the counts.
The theme is set only when it changes, since every view reads it. The page also says when the backup should end
("fini vers 04:10"), from the pace of the last backup worth measuring
(`settings.measuredThroughput`).

## At night

The backup holds a `ProcessInfo` activity: the Mac does not idle-sleep (the screen may). A
notification with sound says when it is done ("Tu peux aller dormir"); cards read whole and
verified are ejected, the others never (or left in, or offered a format: `settings.whenDone`,
which replaced the `ejectWhenDone` switch on 2026-10-15 and still reads it). A card is ejected
as its whole disk (`diskutil eject` on the parent), so a camera plugged by USB lets go of it too
(reported 2026-10-16), unless another volume of that disk must stay; a device that will not
eject its medium is still unmounted, and the page says the body can be unplugged. Not yet tried
on a real body. Quitting mid-backup asks, then stops the copy and waits
for the record to be written. What was verified before a cancel, a failure, a quit or a crash is
in the journal, so "Reprendre" copies only the rest, even with "Ignorer ce qui est déjà
sauvegardé" off and even after the app was killed. A card left unticked does not hold the button
while it is read. Twenty seconds without a byte moving is said on the copying page: a stuck
copy and a slow one look the same on a percentage. Under the figure, a curve of the speed over
the backup (`SpeedGraph`, asked 2026-10-17 "un peu comme Windows"): what was read, the card in
the accent and the drives read back in its softer shade, a dashed line at the speed now. It
is `ThroughputHistory`, bytes summed into bins that merge two by two past 240, so three hours
cost what a minute does. Appearance can be forced dark in Settings
(Copie tab).

Rushes touches the network in two places only, both asked for: Rushes › Rechercher une mise à
jour… (`UpdateCheck`) reads GitHub's releases and says, nothing more; and a send to a server set
up in Réglages › Envoi. No telemetry, nothing in the background (2026-10-01).

**The send comes after the backup, never instead of it** (asked 2026-10-15). Réglages › Envoi
names one target: a folder the Mac syncs (iCloud Drive, Dropbox, Google Drive, a NAS) or an
FTP/FTPS server. The preparation page shows it under the drives in Destinations (`SendRow`,
2026-10-16): the synced folder is chosen there and "à la fin / sur demande" switched there, while a
server's address and password stay in the settings, opened on that tab. It runs by itself at the
end (`uploadWhenDone`) or from "Envoyer" on the done page, holds its own `ProcessInfo` activity, and quitting asks and waits for curl to stop.
`Upload.items` lists what the backup verified plus the night's `_RUSHES` records, read from the
first drive still plugged in, never from the card. The drives' rules hold on the other side: a
hidden `.<name>.rushes-partial` named only once whole (`Copier.name` in a folder, curl's
post-quote `RNFR`/`RNTO` on a server), a name already taken at another size is a failure and
never replaced, one at its size is "déjà là" and not sent twice. A folder copy is read back
against the manifest's XXH64; a server is asked the size, all FTP can be held to. The verdicts
neither wait for it nor depend on it. FTP goes through the Mac's `/usr/bin/curl`, so there is
still no dependency; the password is in the keychain (`Keychain`, service
`eu.stevenrsl.rushes.upload`) and reaches curl on its standard input, never its command line.
SFTP is not offered: macOS's curl does not speak it. Distribution is direct, never the Mac App Store, whose sandbox would
turn the cards' detection into an open panel per card: `build.sh release-signed` signs with
the hardened runtime from `RUSHES_SIGN_IDENTITY`, notarises and staples the app then the
`.dmg` with `RUSHES_NOTARY_PROFILE`, and asks Gatekeeper about a quarantined copy. The version
lives in `Support/Info.plist` only: `CFBundleShortVersionString` in digits (macOS wants them),
`RushesPrerelease` for the rest (`beta.1`, empty once public), joined by `Bundle.version` as
the release is tagged (`v0.3.0-beta.1`, decided 2026-10-01).

**Until there is a Developer ID** (decided 2026-10-19), the beta ships from `build.sh
release-selfsigned`: the same `.dmg`, hardened runtime, signed with a self-signed certificate
"Rushes" made once by `Tools/make-signing-certificate.sh` (key in the login keychain and a
`.p12` kept outside the repo), not notarised, with a `.sha256` beside it; both go on the
release. It buys two things an ad-hoc signature does not. The designated requirement is
`identifier "eu.stevenrsl.rushes" and certificate leaf = H"…"`, the same at every version, so
the removable volumes permission holds across updates (ad hoc, it is keyed to the cdhash and
asked again every time). And `install.sh`, run as `curl … | bash`, installs without Gatekeeper's
block, since curl sets no quarantine: it picks the newest release as `UpdateCheck` does, checks
the SHA-256, then holds the image to the certificate pinned in its `CERT_SHA1` and the app to
the bundle identifier as well, copies beside `/Applications/Rushes.app`, checks again, and
swaps. It refuses while Rushes runs, never asks for a password and never removes a quarantine
flag. `build.sh` signs by the hash `install.sh` pins, never by the name, so the two cannot
drift; making a second certificate would cost every tester the permission once. A browser's
download is still blocked until "Ouvrir quand même", at every version. When the Developer ID
comes, `release-signed` replaces it and `install.sh` pins the new leaf or goes.

The first launch asks for removable volumes access (`NSRemovableVolumesUsageDescription`); the
ad-hoc signature of a local build means every rebuild asks again, as Cairn's microphone does.

## The beta

Testers run bodies Steven does not own (worksheet of 2026-10-01). Aide › Décrire une carte…
(`CardDiagnostic`, `CardDescription`) reads a card through the backup's own `CardScanner.scan`
then `dated`, and writes JSON where the tester says, refused on the card itself: every entry
with its size, dates, hidden flag and fate (`Fate`: the shot and role, or why it stays), the
kinds and the tester's own choices, the EXIF models. Never an image byte, the volume's name or
path, anything typed, or the serial (only `hasSerial`). The same menu opens GitHub's issue
forms (`.github/ISSUE_TEMPLATE`: carte, verdict, autre) or mails rushes@stevenrsl.eu.
`docs/testeurs.md` and `docs/testers.md` (with a glossary, the app being French only) say what
is asked: three real nights, two drives, and their usual backup kept alongside.

## Not done yet

- **A camera plugged by USB.** Only mounted volumes are read: a card reader, or a camera in
  mass-storage mode. Canon bodies (and iPhones) speak PTP only, which needs ImageCaptureCore,
  is several times slower than a reader and hides Sony's XML. A reader is the recommendation.
- Trying the ASC MHL with the `ascmhl` tool itself (`ascmhl verify`); only the schemas were
  checked.
- An option to keep an untouched dump of the card's structure next to the renamed files, for
  spanned clips (AVCHD, XF-AVC across cards) that editing software rebuilds from the structure.
- Opening by itself when a card is inserted (a login item watching mounts).
