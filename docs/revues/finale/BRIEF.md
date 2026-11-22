# Revue finale — qualité, sécurité et architecture — Studio EQ 1.0.0

Tu es relecteur indépendant. D'autres relecteurs font la même revue de leur côté : ne cherche
pas leurs rapports, et **ne lis rien dans `docs/revues/` en dehors de ce brief** (une première
série de revues y figure ; on veut un regard neuf, pas une relecture de ses conclusions).

## Règles

- **Ne modifie, ne crée et ne supprime aucun fichier.** Lecture seule. Ton rapport est ton
  message final, rien d'autre.
- **Ne lance pas l'app ni ses modes de test** (`--selftest`, `make selftest`, `make scenario`,
  `scripts/scenario.sh`, `audioctl`) : ils touchent la sortie audio réelle de l'utilisateur.
  Ne lance ni build, ni `make`, ni `git push`, ni `gh`.
- Lecture du code, `grep`, `git log` / `git show`, lecture des docs : oui.
- Rédige en **français**.

## Le produit

App macOS de barre des menus (Swift 6, SwiftUI, macOS 15+, Apple Silicon), environ 2 400 lignes
de Swift et de shell. Elle égalise le son **uniquement quand les haut-parleurs d'un Apple Studio
Display sont la sortie système par défaut**, sans pilote virtuel :

- un *process tap* Core Audio (`CATapDescription`, par périphérique et par flux,
  `mutedWhenTapped`, qui exclut le processus Studio EQ) capte le son destiné à l'écran et coupe
  l'original ;
- un agrégat privé {entrée : le tap ; sortie : le Studio Display} le rejoue après filtrage dans
  une IOProc temps réel : trois biquads RBJ (plateau bas 150 Hz, cloche 1,5 kHz, plateau haut
  6 kHz), **préampli fixe de −3 dB**, limiteur de crête commun à tous les canaux, remise à zéro
  de l'état en cas de `NaN`/`Inf` ;
- `CaptureCheck` vérifie que l'autorisation « Enregistrement audio du système » (TCC) est
  accordée **avant** chaque montage du moteur, car un tap refusé coupe l'original et ne livre
  que des zéros ;
- les outils de validation (auto-test, A/B, surcharges) ne sont compilés qu'avec la condition
  `VALIDATION` (Debug, ou `make validation`), jamais dans l'app distribuée.

Sandbox actif sans droit supplémentaire, Hardened Runtime, aucun réseau, aucune dépendance.

## État : publié

La version **1.0.0 est publiée** sur GitHub (GPL-2.0-or-later, dépôt public). Le DMG est
construit **sur le Mac du développeur** par `make publish` (`Makefile`, `scripts/release.sh`) :
tests, build Release signé Developer ID, vérifications bloquantes, DMG signé, notarisation,
agrafage, contrôle Gatekeeper, puis étiquette et release GitHub. Aucun secret n'est confié à
GitHub ; l'intégration continue (`.github/workflows/ci.yml`) ne fait que construire et tester,
en signature ad hoc. Une première série de trois revues a eu lieu avant la publication et ses
constats ont été traités ; celle-ci est la revue **finale** de la version publiée.

À lire d'abord : `README.md`, `docs/ARCHITECTURE.md`, `docs/DSP.md`, `docs/TESTS.md`,
`docs/RELEASE.md` (`docs/FAISABILITE.md` si utile). Code : `StudioEQ/` (App, Audio, DSP),
`StudioEQTests/`, `scripts/`, `Makefile`, `project.yml`, `Config/`, `StudioEQ/Info.plist`,
`StudioEQ/StudioEQ.entitlements`, `.github/`, `.gitignore`.

## Ce qu'on attend

**Qualité**
- Lisibilité, nommage, découpage des fichiers et des types, longueur des fonctions, duplication,
  code mort, commentaires faux ou périmés.
- Tests : couvrent-ils ce qui compte (DSP, reconnaissance de l'écran, décisions de
  `AppModel`) ? Quels tests manquants auraient le plus de valeur ? Tests fragiles ?
- Cohérence entre la documentation (README, docs/) et le code réel : chiffres, noms de cibles,
  comportements décrits.
- `Makefile` et scripts : robustesse (`set -euo pipefail`, guillemets, chemins avec espaces),
  messages d'erreur, portabilité vers un autre Mac de contributeur.
- Facilité de contribution : un tiers peut-il cloner, construire et tester sans compte
  développeur ?

**Sécurité**
- Surface d'attaque, droits, sandbox, Hardened Runtime, TCC : le minimum nécessaire ?
- Confidentialité : le son capté peut-il fuir, être enregistré, persister ? Journaux
  (`os.Logger`) : fuient-ils des données personnelles ?
- Code non sûr : pointeurs, structures C de taille variable, débordements, durées de vie des
  objets utilisés depuis le thread d'E/S.
- Entrées non fiables : préférences, noms et UID de périphériques, valeurs Core Audio
  inattendues, nombre de canaux, formats.
- Chaîne de publication : `make publish` et `scripts/release.sh` (vérifications suffisantes ?
  contournables ?), CI (actions épinglées, permissions), contenu du dépôt public (secrets,
  identifiants personnels, chemins locaux, données de l'utilisateur dans les docs ou les
  rapports de test).

**Architecture et fiabilité**
- Temps réel : IOProc et `EQProcessor` sans allocation, verrou, appel bloquant ni runtime Swift
  coûteux.
- Concurrence Swift 6 : isolation, `@unchecked Sendable`, atomiques, objets partagés entre
  thread principal et thread d'E/S, démontage pendant que l'IOProc tourne.
- Cycle de vie Core Audio : création et destruction du tap et de l'agrégat, échecs partiels,
  écouteurs, veille et réveil, changement de fréquence, périphérique qui disparaît.
- `AppModel` : courses, boucles de réessai, états incohérents, tâches obsolètes.
- Risque de **silence ou de double lecture** (le pire défaut pour l'utilisateur).
- DSP : stabilité, limiteur, préampli, comportement aux réglages extrêmes.
- Le découpage général tiendra-t-il une version 1.1 (nouvelles fonctions, autre écran) ?

## Format du rapport

1. Résumé en 5 lignes au plus : verdict global sur la version 1.0.0.
2. Constats, **du plus grave au moins grave**. Pour chacun :
   - **Gravité** : critique / haute / moyenne / basse / info ;
   - **Catégorie** : qualité / tests / documentation / sécurité / publication / temps réel /
     concurrence / cycle de vie / fiabilité / DSP / architecture ;
   - **Emplacement** : `fichier:ligne` ;
   - **Constat** et **preuve** (extrait de code ou raisonnement vérifiable) ;
   - **Scénario concret** qui produit le défaut (si c'en est un) ;
   - **Recommandation**.
3. Ce que tu as vérifié et jugé correct (bref), pour que l'on sache ce qui a été couvert.

Ne signale pas comme défaut une limitation déjà décrite dans `README.md` ou `docs/TESTS.md`,
sauf si tu contestes l'analyse qui en est faite. Préfère peu de constats prouvés à beaucoup de
soupçons ; marque « à vérifier » ce que tu ne peux pas prouver.
