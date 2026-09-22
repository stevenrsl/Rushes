# Rushes

Une app Mac qui vide les cartes à la fin d'un tournage. Elle lit toutes les cartes branchées,
quelle que soit la marque, renomme chaque prise `YYMMDD_XX_Client_Projet_0001`, range RAW, JPEG
et vidéo dans des dossiers, copie sur un ou deux disques à la fois, et relit chaque copie sur le
disque avant de dire que c'est fait.

Faite pour 3 h du matin : tu branches la carte, tu vérifies le client et le projet, tu fais ⌘↩,
tu vas dormir.

Trois règles tiennent tout le reste :

- **Une carte n'est jamais que lue.** Rien n'est déplacé, renommé, écrit ni effacé dessus.
  Formater, c'est le travail de l'appareil photo, une fois la sauvegarde vérifiée.
- **Rien n'est jamais remplacé sur un disque.** Un nom déjà pris est un conflit qui retient la
  sauvegarde, jamais un écrasement. Une copie coupée en route ne laisse aucun fichier qui ait
  l'air fini.
- **Vérifié veut dire relu depuis le disque.** La copie est relue en contournant le cache du Mac
  et comparée à ce qui a été lu sur la carte. À la fin, chaque carte reçoit son verdict :
  formatable, à vérifier, ou ne pas formater, avec la raison.

L'app est en français. Le code et sa documentation sont en anglais.

## Installer

Il n'y a pas encore de version à télécharger toute faite : l'app n'est pas signée par un compte
développeur Apple, donc un `.zip` téléchargé serait refusé par macOS. On l'installe en la
construisant soi-même, ce qui prend une minute et ne demande aucun compte.

**Ce qu'il faut :** un Mac sous **macOS 26 ou plus récent** et **Xcode** installé depuis le Mac
App Store. Les outils en ligne de commande seuls (`xcode-select --install`) suffisent peut-être,
mais le build n'a été vérifié qu'avec Xcode.

```bash
git clone https://github.com/stevenrsl/Rushes.git
cd Rushes
./build.sh
```

Le script compile, assemble `Rushes.app` et le signe. Il affiche le chemin de l'app à la fin.
Pour la mettre dans les Applications et l'ouvrir :

```bash
cp -R build/Rushes.app /Applications/ && open /Applications/Rushes.app
```

**Au premier lancement, macOS demande l'accès aux volumes amovibles.** Il faut accepter, sinon
les cartes n'apparaissent pas du tout, ou apparaissent vides. Cette autorisation est liée à la
signature de l'app, et comme la signature est locale, elle change à chaque reconstruction : la
question revient après chaque `./build.sh`. C'est normal, et ça disparaîtra le jour où l'app
sera signée avec un compte Apple.

## Mettre à jour

```bash
git pull
./build.sh
cp -R build/Rushes.app /Applications/
```

Les réglages sont conservés d'une version à l'autre. Quand un réglage change de sens entre deux
versions, l'app met à jour ce qui est enregistré, une seule fois, au lancement suivant.

## Essayer sans tournage

Une fausse carte, avec de vraies photos JPEG datées et des fichiers RAW et vidéo de taille
plausible, sur un volume exFAT comme une vraie carte, que l'app détecte toute seule :

```bash
hdiutil create -size 300m -fs ExFAT -volname SONY-TEST -layout MBRSPUD /tmp/carte.dmg
hdiutil attach /tmp/carte.dmg
swift Tools/make-test-card.swift sony /Volumes/SONY-TEST
```

`canon` et `dji` font deux autres cartes. Choisis un dossier de destination dans un coin, par
exemple `~/Downloads/essai`, et lance la sauvegarde : rien n'est écrit ailleurs, et la fausse
carte est en lecture seule comme une vraie. Pour tout ranger à la fin :

```bash
hdiutil detach /Volumes/SONY-TEST && rm /tmp/carte.dmg
```

## Ce que l'app laisse derrière elle

Sur chaque disque, dans le dossier du tournage, `_RUSHES/<date-heure>.json` et `.csv` : le nom
d'origine de chaque fichier, son nouveau nom, sa taille et son empreinte. C'est le seul endroit
où survivent les noms donnés par l'appareil, le jour où un client redemande « la DSC01234 ». Le
CSV s'ouvre dans Numbers ou Excel.

À la racine de chaque disque, `_RUSHES/journal.jsonl` tient une ligne par fichier, écrite au
moment où il est vérifié. C'est ce qui permet de reprendre une sauvegarde coupée, de reconnaître
une carte qui n'a pas été formatée même si le client a changé de nom entre-temps, et de ne
jamais redonner un numéro déjà attribué. Ces fichiers se suppriment sans rien casser.

Rien n'est écrit ailleurs : pas de base de données sur le Mac, pas de dossier caché dans la
maison. Les réglages tiennent dans `~/Library/Preferences/eu.stevenrsl.rushes.plist`.

## Désinstaller

```bash
rm -rf /Applications/Rushes.app
defaults delete eu.stevenrsl.rushes
```

Les rushes déjà copiés et les relevés restent sur les disques, évidemment.

## Développer

```bash
./build.sh debug                                    # build de débogage
swift test --scratch-path /tmp/rushes-build         # 66 tests
swift Tools/make-icon.swift "$(pwd)"                # redessine l'icône
```

`swift test` et `swift build` veulent un dossier de travail hors de `Documents` : ce dossier est
synchronisé, son fournisseur de fichiers pose des attributs étendus sur les produits du build,
et `codesign` les refuse. `build.sh` s'en occupe tout seul.

`CLAUDE.md` décrit le fonctionnement en détail : le regroupement des prises par la norme DCF,
les modèles de noms, les lettres de caméra, ce que fait le moteur de copie, et les décisions
prises en chemin.
