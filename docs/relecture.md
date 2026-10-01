# Guide de relecture

Pour un ami développeur qui accepte de relire le cœur de Rushes avant la bêta. Une à deux heures
de lecture, pas plus : il y a environ 6 500 lignes de Swift, et il n'en faut lire qu'une petite
part. Le reste (les vues, le design, les noms) n'est pas ce qui peut faire perdre une photo.

## Ce que fait Rushes, en une minute

Une app Mac qui vide les cartes mémoire à la fin d'un tournage. Elle lit toutes les cartes
branchées, renomme chaque prise, copie sur un ou deux disques à la fois, relit chaque copie depuis
le disque, puis dit **pour chaque carte** si on peut la formater. Ce verdict est la seule phrase
qui compte : une carte formatée sur la foi d'un « formatable » faux, c'est un tournage perdu.

`CLAUDE.md` décrit tout en détail, en anglais. Ce guide te dit où regarder.

## Ce qu'on te demande

**Chercher une façon de faire dire « tu peux formater » à tort**, ou de perdre, écraser ou
corrompre un fichier sans que l'app s'en aperçoive. Tout le reste est secondaire.

Chaque trouvaille va dans une issue GitHub, une par sujet, avec le label `relecture`, et dedans :
le fichier et la fonction, le scénario concret (quelle carte, quel disque, quel moment), et ce que
tu crois que ça coûte. « Je ne suis pas sûr » est une réponse utile ; « c'est bon, j'ai essayé de
casser X et je n'ai pas réussi » aussi.

## Lancer et essayer

Il faut macOS 26 et Xcode. Le dossier de travail de SwiftPM doit être **hors de `Documents`**
(le dossier est synchronisé et `codesign` refuse les attributs que le fournisseur de fichiers
pose dessus).

```bash
./build.sh debug                                  # build/Rushes.app
swift test --scratch-path /tmp/rushes-build       # la suite, une minute environ
```

Les tests utiles pour toi : `CopierTests`, `BackupTests`, `JournalTests`, `VerdictTests`,
`ReadinessTests` et `FileSystemTests`. Ce dernier crée de vraies images disque exFAT et FAT32 avec
`hdiutil`, parce que ces formats se comportent autrement qu'APFS.

Une fausse carte, que l'app détecte comme une vraie :

```bash
hdiutil create -size 300m -fs ExFAT -volname SONY-TEST -layout MBRSPUD /tmp/carte.dmg
hdiutil attach /tmp/carte.dmg
swift Tools/make-test-card.swift sony /Volumes/SONY-TEST    # ou canon, dji
```

Pour un disque de destination jetable, la même commande avec un autre nom (`SSD-TEST`). Pour
couper une copie en route : débrancher l'image (`hdiutil detach -force`), annuler, ou quitter
l'app.

## Le trajet d'une nuit

Dans l'ordre où le code le fait. C'est le fil à suivre si tu lis.

1. **Lire la carte.** `CardScanner.scan` (`Model/CardScanner.swift`) parcourt toute la carte, en
   lecture seule. Chaque fichier y devient une prise, un fichier laissé avec sa raison, ou un
   dossier illisible. `Grouping` (`Model/Grouping.swift`) regroupe les fichiers par la règle DCF :
   même dossier et même nom de base, une prise. Sony et GoPro ont leurs exceptions.
2. **Faire le plan.** `Planner.plan` (`Model/Plan.swift`) nomme chaque prise, décide de son
   dossier, et saute ce qui est déjà sauvegardé (voir l'invariant 5).
3. **Retenir ⌘↩.** `Readiness.blockers` (`Model/Readiness.swift`) donne toutes les raisons de
   ne pas lancer : place, FAT32, deux dossiers sur le même disque, nom trop long, conflits.
4. **Copier.** `Backup.run` (`Transfer/Backup.swift`) prend fichier par fichier et appelle
   `Copier.copy` (`Transfer/Copier.swift`). Le journal du disque reçoit une ligne par fichier
   vérifié.
5. **Écrire les relevés et synchroniser.** À la fin de `Backup.run`, les manifestes sont écrits,
   puis chaque disque est synchronisé en entier, et enfin la ligne `end` du journal.
6. **Juger chaque carte.** `Verdicts.of` (`Model/Verdict.swift`), appelé depuis `Ingest` sur
   `runningPlan` (le plan qui a tourné, jamais un plan refait depuis).

## Les invariants à attaquer

### 1. Une carte n'est jamais que lue

Rien n'est écrit, déplacé, renommé ni effacé sur une carte. À vérifier : `CardScanner.scan`,
`CaptureDates.exif` (ImageIO, en-tête seulement), `Copier.copy` (la carte ouverte en
`O_RDONLY`), `CardDescription.save` (`App/Feedback.swift`, sur la branche bêta : le diagnostic
refuse d'être écrit sur la carte). Une carte dite « ne pas formater » n'est jamais éjectée
(`Ingest`).

**Pour attaquer :** un chemin qui écrit à partir d'une URL de carte. Un dossier « ajouté à la
main » qui serait aussi un disque de destination.

### 2. Rien n'est jamais remplacé sur un disque

Dans `Copier.copy`, la copie est écrite en `.<nom>.rushes-partial`, créé en `O_CREAT | O_EXCL`,
puis nommée par `Copier.name` :

- `renamex_np(…, RENAME_EXCL)` quand le système de fichiers le permet ;
- sur exFAT et FAT32, qui répondent `ENOTSUP`, le nom final est d'abord réservé par
  `open(O_CREAT | O_EXCL)`, puis la copie est renommée par-dessus cette réservation.

Un nom déjà pris est un conflit qui retient la sauvegarde. `Backup.sweepPartials` efface les
`.*.rushes-partial` laissés par une copie coupée, et rien d'autre.

**Pour attaquer :** la fenêtre entre la réservation et le `rename` dans le repli exFAT. Deux
cartes qui produiraient le même nom dans la même nuit. La casse (APFS et exFAT ignorent la
casse : `DSC.JPG` et `dsc.jpg` sont un seul nom). Un disque réseau qui mentirait sur `EEXIST`.

### 3. Vérifié veut dire relu depuis le disque

Dans `Copier.copy` : la carte est lue une fois, par morceaux de 8 Mo, hachée en XXH64 et écrite
sur chaque disque en parallèle (`Copier.stream`). Le nombre d'octets lus doit égaler la taille
vue par le scan. Chaque copie est `fsync`ée, puis relue disque après disque par
`Copier.readHash`, avec `F_NOCACHE` pour contourner le cache du Mac, et comparée au hash de la
carte. La copie n'est nommée que si tous les disques correspondent, et elle est nommée sur tous
ou sur aucun : un échec au nommage sur le disque B retire le nom déjà donné sur A.

**Pour attaquer :** est-ce que `F_NOCACHE` sur un descripteur garantit vraiment une lecture
depuis le support, quand la même page vient d'être écrite par un autre descripteur ? Un lecteur
de carte qui renverrait des octets faux mais en bon nombre (le hash de la carte serait alors faux
lui aussi, et la copie le reproduirait fidèlement). `XXHash64` lui-même (vérifié contre les
vecteurs publiés et contre zstd dans `HashTests`).

### 4. L'ordre de durabilité

Pour un fichier : écrit, `fsync`, relu, nommé, puis une ligne dans `_RUSHES/journal.jsonl` à la
racine du disque, écrite et `fsync`ée tout de suite (`Journal.append`). À la fin : les manifestes
(`History.write`), puis `Journal.flushDevice` sur chaque disque (`sync_volume_np` avec
`FULLSYNC | WAIT`, repli sur `F_FULLFSYNC`), puis la ligne `end`, puis le verdict. Le
`flushDevice` final est là parce que sur exFAT, les entrées de dossier qui portent les noms
peuvent rester une trentaine de secondes dans le cache du noyau. Un disque qui ne confirme pas
met toutes les cartes en « ne pas formater ».

**Pour attaquer :** le `rename` lui-même n'est pas suivi d'un `fsync` du dossier avant la ligne
du journal ; seul le `flushDevice` final le couvre. Que se passe-t-il si le disque est arraché
entre les deux ? Un crash entre le nommage d'un fichier et sa ligne de journal : au lancement
suivant, le fichier est là mais n'est dans aucun relevé, il devrait apparaître comme un nom déjà
pris (donc un conflit, du côté sûr). Est-ce bien le cas ?

### 5. On ne saute une prise que si chaque disque l'a encore

`DestinationIndex.load` (`Model/Plan.swift`) et `DriveJournal.holds` (`Model/Journal.swift`) :
une prise listée par un relevé ne compte comme sauvegardée que si son fichier est encore à son
chemin, à sa taille, **sur chaque disque**. Une prise présente sur un disque et pas sur l'autre
est recopiée.

L'identité d'un fichier est son **empreinte** (`MediaFile.fingerprint`) : nom donné par
l'appareil, taille, date de modification à la seconde. C'est le point le plus fragile du projet,
voir plus bas.

### 6. La reprise après une coupure

`DriveJournal.read` : chaque sauvegarde écrit `start`, une ligne par fichier, puis `end` avec
`complete`. Un `start` sans `end`, ou un `end` incomplet, non suivi d'une sauvegarde complète,
rend le disque « interrompu ». Ce qu'il a vérifié est alors sauté, même si le réglage dit de tout
recopier.

**Pour attaquer :** un journal tronqué au milieu d'une ligne (crash pendant `append`). Deux Macs
qui écriraient sur le même disque. Un journal effacé à la main (il est censé n'être qu'un dérivé
des manifestes).

### 7. Le verdict, carte par carte

`Verdicts.of` : « formatable » seulement si aucun fichier de cette carte n'a échoué, que la
sauvegarde n'a pas été arrêtée avant elle, que tous les disques ont confirmé leurs écritures,
que la carte a été lue en entier, et qu'aucun nom n'était déjà pris. « À vérifier » si un fichier
d'un type inconnu, ou une photo cachée ou rangée dans un dossier de service, reste dessus.

**Pour attaquer :** toute combinaison qui donne `.safe` alors qu'un fichier coché de cette carte
n'est pas vérifié sur chaque disque.

### 8. Ce qui retient ⌘↩

`Readiness.blockers`, une règle et un test chacune dans `ReadinessTests`. **Pour attaquer :** un
cas où la sauvegarde partirait vers un disque plein, un FAT32 avec un fichier de plus de 4 Go, ou
deux « disques » qui sont un seul volume (un dossier et son sous-dossier, un lien symbolique).

## Déjà trouvé et corrigé

Par un conseil de relecture le 28 septembre 2026 (détail dans `docs/conseil-2026-09-28.md`).
Inutile de les chercher à nouveau, mais vérifier que la correction tient est bienvenu.

- Le scan sautait les fichiers marqués cachés (attribut DOS sur FAT et exFAT) et les dossiers
  nommés `BACKUP`, `DATABASE`, `GENERAL` à toute profondeur : une carte pouvait être dite
  formatable avec des photos que Rushes n'avait jamais vues.
- Le verdict lisait un plan refait pendant la copie au lieu de celui qui avait tourné.
- Aucune synchronisation des dossiers après les renommages : sur exFAT, les noms pouvaient ne pas
  être sur le disque au moment de « tu peux formater ».
- Un seul fichier en échec rendait un disque « interrompu » à vie.
- Un nom donné sur le disque A puis refusé sur le disque B laissait un fichier hors de tout
  relevé.
- La taille lue sur la carte n'était pas comparée à la taille attendue : une copie tronquée se
  serait vérifiée contre elle-même.
- Un disque FAT32 arrêtait la nuit au premier clip de plus de 4 Go.
- Avant le 22 septembre, sur exFAT, chaque copie était vérifiée puis effacée faute de pouvoir
  être nommée (`RENAME_EXCL` non pris en charge).

## Laissé ouvert : ton avis est demandé

- **L'empreinte** (nom, taille, date à la seconde) ne contient ni le dossier ni le boîtier. Deux
  boîtiers du même modèle, aux compteurs alignés, en RAW non compressé (taille fixe), la même
  seconde : collision, et la seconde prise serait sautée comme déjà sauvegardée. C'est une
  perte. Pistes : le numéro de série du boîtier, ou un hash partiel du fichier. Lequel, ou autre
  chose ?
- **Le fuseau des cartes FAT.** FAT stocke l'heure locale sans fuseau. Après un changement de
  fuseau ou d'heure d'été, les empreintes changent et une carte gardée est recopiée sous de
  nouveaux numéros. Gênant, jamais une perte.
- **Le cache du disque lui-même.** `F_NOCACHE` contourne le cache du Mac, pas la mémoire du
  disque. Un `F_FULLFSYNC` avant chaque relecture le réglerait, mais coûte cher sur un disque dur
  avec des milliers de JPEG. Est-ce que la relecture prouve quelque chose sans lui ?
- **Les disques réseau.** Un NAS en SMB refuse peut-être les deux façons de synchroniser. Toutes
  les cartes seraient alors « ne pas formater » : le côté sûr, mais inutilisable.
- **Une erreur qui n'appartient à aucune carte.** Quand l'écriture du journal ou d'un manifeste
  échoue sur un disque, l'erreur est enregistrée sans carte d'origine (`source` vide dans
  `BackupReport.Failure`), et `Verdicts.of` ne regarde que les erreurs de chaque carte. Une carte
  peut donc être dite formatable alors que son manifeste n'a pas été écrit sur un disque. Les
  fichiers sont bien là et vérifiés, mais les noms d'origine (« le client veut la DSC01234 ») ne
  survivent que dans ce manifeste. Faut-il que cela retienne le verdict ?

## Ce qui n'est pas à relire

Les vues (`Views/`), le design (`Design/`), le rapport HTML, l'ASC MHL, les noms et les modèles
de dossier. Une erreur là se voit à l'écran le soir même ; elle ne se découvre pas une fois la
carte formatée.
