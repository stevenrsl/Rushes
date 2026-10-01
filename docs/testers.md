# For testers

*[En français](testeurs.md).*

Thank you for trying Rushes before anyone else. Rushes offloads camera cards at the end of a
shoot: it renames every shot, sorts RAW, JPEG and video into folders, copies to one or two
drives at once and reads every copy back before saying it is done. At the end, each card gets a
verdict telling you whether it is safe to format.

The beta is for one thing: seeing what Rushes makes of **your** cameras and **your** cards,
which Steven does not have to hand.

## First: keep your usual backup

**During the beta, back up your cards the way you always do as well**, with your usual software
or by hand, alongside Rushes. Only format a card once your usual method has saved it too, even
if Rushes says it can be formatted. Rushes must not be anyone's only copy before its public
release.

## The app is in French for now

An English version will come. Until then, the words that matter:

| In the app | Means |
|---|---|
| Formatable / tu peux formater | Every file of this card was copied and read back: safe to format |
| À vérifier | Something on the card could not be ticked (an unknown kind of file, a picture found hidden): look before formatting |
| Ne pas formater | Do not format: a file failed, the card was only partly read, or the backup stopped before it |
| Laissés sur la carte | Left on the card, each with its reason |
| Client, Projet | Client, project: they go into the file names |
| Disques | Drives |
| ⌘↩ (Sauvegarder) | Start the backup |
| Reprendre | Resume an interrupted backup: only what is missing is copied |
| Vérifier un disque | Read a drive back, months later, against its records |
| Tu peux aller dormir | Done. You can go to bed |

## Installing

1. Download the latest `Rushes-<version>.dmg` from the
   [releases page](https://github.com/stevenrsl/Rushes/releases). During the beta they are
   pre-releases.
2. Open it and drag Rushes onto the Applications shortcut.
3. Open Rushes from Applications. On first launch macOS asks for access to removable volumes:
   allow it, or the cards will not show up.

You need a Mac running macOS 26 or later. To find out whether a new version is out: Rushes ›
Rechercher une mise à jour…. That is the only time Rushes connects to the Internet.

## What we ask of you

- **At least three real nights**, with your own cameras and cards. A fake card never has a real
  camera's quirks.
- **Two drives if you can.** Rushes copies to both at once, and that is where the hard cases
  hide.
- After each night, **a look at each card's verdict**, on the last page or in the report
  (`_RUSHES/rapport-….html` in the shoot's folder). A verdict that surprises you, either way, is
  the most useful feedback there is.

## Sending feedback

1. **Before formatting the card**, choose Aide › Décrire une carte… and pick the card. Rushes
   reads it as a backup would and writes a `diagnostic-….json` file wherever you choose (never
   on the card).

   That file holds the names the camera gave its files, their sizes and dates, and what Rushes
   does with each one. It holds no image, not the card's name, nothing you typed in Rushes, and
   not your camera's serial number.
2. Send it with a few words:
   - on GitHub, through Aide › Signaler un problème… (three forms: my card, the verdict
     surprised me, something else);
   - or by email to [rushes@stevenrsl.eu](mailto:rushes@stevenrsl.eu), through Aide › Écrire à
     rushes@stevenrsl.eu.

Writing in English is perfectly fine. If you are happy to, attach the night's report as well. It
holds the client and project names you typed, so that is your call.
