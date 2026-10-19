# Rushes

Une app Mac qui vide les cartes à la fin d'un tournage. Elle lit toutes les cartes branchées,
quelle que soit la marque, renomme chaque prise `YYMMDD_XX_Client_Projet_0001`, range RAW, JPEG
et vidéo dans des dossiers, copie sur un ou deux disques à la fois, et relit chaque copie sur le
disque avant de dire que c'est fait.

Faite pour 3 h du matin : tu branches la carte, tu vérifies le client et le projet, tu fais ⌘↩,
tu vas dormir.

Trois règles tiennent tout le reste :

- **Une carte n'est jamais que lue.** Rien n'est déplacé, renommé, écrit ni effacé dessus.
  Formater se fait dans l'appareil photo, une fois la sauvegarde vérifiée, ou depuis Rushes si
  tu le choisis : la page de fin propose alors de formater chaque carte « formatable », une par
  une, après confirmation, et jamais une autre.
- **Rien n'est jamais remplacé sur un disque.** Un nom déjà pris est un conflit qui retient la
  sauvegarde, jamais un écrasement. Une copie coupée en route ne laisse aucun fichier qui ait
  l'air fini.
- **Vérifié veut dire relu depuis le disque.** La copie est relue en contournant le cache du Mac
  et comparée à ce qui a été lu sur la carte. À la fin, chaque carte reçoit son verdict :
  formatable, à vérifier, ou ne pas formater, avec la raison.

L'app est en français. Le code et sa documentation sont en anglais.

## Télécharger

Il faut un Mac sous **macOS 26 ou plus récent**. Pendant la bêta, l'app est signée par son
auteur mais pas encore par Apple : macOS ne la connaît pas, et la bloque quand elle vient d'un
navigateur. Il y a deux façons de l'installer.

**Par le Terminal, en une ligne.** C'est la plus simple, et c'est aussi celle des mises à jour :

```bash
curl -fsSL https://raw.githubusercontent.com/stevenrsl/Rushes/main/install.sh | bash
```

Le script prend la dernière version sur la page des
[versions](https://github.com/stevenrsl/Rushes/releases). Il vérifie que le fichier a bien
l'empreinte SHA-256 publiée à côté de lui et qu'il est signé par le certificat de Rushes, puis
il copie l'app dans Applications. S'il manque quoi que ce soit, il n'installe rien et dit
pourquoi. Il ne demande aucun mot de passe et ne touche pas à Rushes si elle est ouverte. Une
app installée ainsi n'est pas bloquée par macOS, puisque c'est le script qui a fait les
vérifications. Il est court : [lis-le](install.sh) avant de le lancer si tu veux.

**Par le navigateur.** Télécharge `Rushes-<version>.dmg` sur la page des versions, ouvre-le,
glisse Rushes sur le raccourci Applications, puis ouvre-la depuis Applications. macOS la
bloque : clique sur OK, va dans Réglages Système › Confidentialité et sécurité, et en bas, à
côté de « Rushes a été bloquée », clique sur **Ouvrir quand même**. Le bouton ne reste là
qu'une heure environ ; s'il a disparu, rouvre Rushes pour le faire revenir. C'est à refaire à
chaque nouvelle version téléchargée ainsi, jusqu'à ce que l'app soit notarisée par Apple.

**Au premier lancement, macOS demande l'accès aux volumes amovibles.** Il faut accepter, sinon
les cartes n'apparaissent pas du tout, ou apparaissent vides. Les versions suivantes portent la
même signature, donc la question n'est plus posée. Elle revient une seule fois, à la première
version signée de cette façon, pour qui avait une version plus ancienne.

Pour savoir si une nouvelle version existe : Rushes › Rechercher une mise à jour…. C'est le seul
moment où l'app se connecte à Internet, et seulement quand tu le demandes, avec l'envoi vers un
serveur si tu en règles un (Réglages › Envoi). Pour mettre à jour, relance la commande du
Terminal, ou télécharge la nouvelle version et remplace l'ancienne dans Applications. Les réglages sont
conservés d'une version à l'autre. Quand un réglage change de sens entre deux versions, l'app met
à jour ce qui est enregistré, une seule fois, au lancement suivant.

## Construire soi-même

Sans rien télécharger d'autre que le code. Ça prend une minute et ne demande aucun compte.

**Ce qu'il faut :** un Mac sous **macOS 26 ou plus récent** et **Xcode** installé depuis le Mac
App Store. Les outils en ligne de commande seuls (`xcode-select --install`) suffisent peut-être,
mais le build n'a été vérifié qu'avec Xcode.

```bash
git clone https://github.com/stevenrsl/Rushes.git
cd Rushes
./build.sh
```

Le script compile, assemble `Rushes.app` et le signe pour ce Mac. Il affiche le chemin de l'app à
la fin. Pour la mettre dans les Applications et l'ouvrir :

```bash
cp -R build/Rushes.app /Applications/ && open /Applications/Rushes.app
```

Cette signature est locale, et l'autorisation des volumes amovibles y est liée : la question
revient après chaque `./build.sh`. C'est normal pour une app construite soi-même.

Pour mettre à jour :

```bash
git pull
./build.sh
cp -R build/Rushes.app /Applications/
```

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
CSV s'ouvre dans Numbers ou Excel. À côté, `rapport-<date-heure>.html` dit la même nuit pour un
humain : le verdict de chaque carte et chaque fichier avec son nom d'origine. Il s'ouvre dans
n'importe quel navigateur, s'imprime, et s'envoie à un client.

Si le réglage est coché (Copie › Écrire un ASC MHL), un dossier `ascmhl/` dans chaque tournage
tient la même liste au format standard que lisent les DIT et les post-productions.

À la racine de chaque disque, `_RUSHES/journal.jsonl` tient une ligne par fichier, écrite au
moment où il est vérifié. C'est ce qui permet de reprendre une sauvegarde coupée, de reconnaître
une carte qui n'a pas été formatée même si le client a changé de nom entre-temps, et de ne
jamais redonner un numéro déjà attribué. Ces fichiers se suppriment sans rien casser.

Rien n'est écrit ailleurs : pas de base de données sur le Mac, pas de dossier caché dans la
maison. Les réglages tiennent dans `~/Library/Preferences/eu.stevenrsl.rushes.plist`, et le mot
de passe d'un serveur d'envoi dans le trousseau.

## Envoyer une copie ailleurs

Réglages › Envoi : une fois la sauvegarde vérifiée sur les disques, Rushes peut en envoyer une
copie vers un dossier synchronisé (iCloud Drive, Dropbox, Google Drive, OneDrive, un NAS monté)
ou un serveur FTP ou FTPS, tout seul à la fin ou avec le bouton « Envoyer » de la page de fin.
La copie est lue sur le premier disque, jamais sur la carte, et le verdict des cartes ne
l'attend pas : les disques restent la sauvegarde. Les règles des disques tiennent de l'autre
côté : un fichier part sous un nom caché et n'est nommé qu'une fois complet, rien n'est jamais
remplacé, et ce qui est déjà là à sa taille n'est pas renvoyé. Le mot de passe du serveur est
gardé dans le trousseau du Mac.

## Vérifier un disque, des mois plus tard

Fichier › Vérifier un disque (⇧⌘V), avant de vider l'autre copie ou au retour d'un voyage. On
choisit un disque entier ou le dossier d'un tournage : chaque fichier que Rushes y a copié est
relu et comparé à son relevé. Ce qui manque, a changé de taille ou ne se lit plus pareil est
nommé, avec le nom que lui avait donné l'appareil. La vérification ne fait que lire.

## Désinstaller

```bash
rm -rf /Applications/Rushes.app
defaults delete eu.stevenrsl.rushes
security delete-generic-password -s eu.stevenrsl.rushes.upload   # si un serveur a été réglé
```

Les rushes déjà copiés et les relevés restent sur les disques, évidemment.

## Bêta

Rushes est en bêta. Si tu la testes, lis d'abord [la page des testeurs](docs/testeurs.md)
([in English](docs/testers.md)) : garde ta méthode de sauvegarde habituelle en parallèle, et
pour tout retour, Aide › Décrire une carte… puis Aide › Signaler un problème…, ou un e-mail à
[rushes@stevenrsl.eu](mailto:rushes@stevenrsl.eu).

## Soutenir

Rushes est gratuite. Si elle t'épargne des nuits, tu peux la soutenir sur
[GitHub Sponsors](https://github.com/sponsors/stevenrsl) ou sur
[Ko-fi](https://ko-fi.com/stevenrsl).

## Développer

```bash
./build.sh debug                                    # build de débogage
swift test --scratch-path /tmp/rushes-build         # 105 tests
swift Tools/make-icon.swift "$(pwd)"                # redessine l'icône
```

`swift test` et `swift build` veulent un dossier de travail hors de `Documents` : ce dossier est
synchronisé, son fournisseur de fichiers pose des attributs étendus sur les produits du build,
et `codesign` les refuse. `build.sh` s'en occupe tout seul.

Une version à distribuer se fait avec `./build.sh release-signed` : signature Developer ID,
notarisation par Apple, et un `.dmg` dans `build/`. Le haut de `build.sh` dit quelles variables
d'environnement il attend ; aucun identifiant n'est dans le repo.

Tant qu'il n'y a pas de compte Developer ID, les versions de la bêta se font avec
`./build.sh release-selfsigned` : même `.dmg`, signé par un certificat auto-signé « Rushes »
au lieu d'Apple, sans notarisation, avec son `.sha256` à côté. Le certificat se fait une seule
fois avec `Tools/make-signing-certificate.sh <sauvegarde.p12>`, qui le range dans le trousseau,
garde une copie de la clé hors du repo et inscrit son empreinte dans `install.sh`. Ce sont les
deux fichiers à publier sur chaque version. Il faut garder ce certificat d'une version à
l'autre : c'est lui qui fait que macOS se souvient de l'accès aux volumes, et lui que
`install.sh` attend.

`CLAUDE.md` décrit le fonctionnement en détail : le regroupement des prises par la norme DCF,
les modèles de noms, les lettres de caméra, ce que fait le moteur de copie, et les décisions
prises en chemin.

## Licence

Rushes est un logiciel libre, sous [licence publique générale GNU, version 3](LICENSE)
(GPL-3.0). Tu peux l'utiliser, l'étudier, le modifier et le redistribuer, y compris modifié.
Celui qui redistribue Rushes ou un logiciel qui en reprend le code doit le faire sous la même
licence, avec son code source : personne ne peut en faire une app fermée sous un autre nom.

Tout le code est écrit pour Rushes, sans dépendance. L'empreinte XXH64 est écrite d'après sa
spécification publique, pas reprise de la bibliothèque de référence.
