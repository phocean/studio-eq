# Revue de code — sécurité et architecture — Studio EQ

Tu es relecteur indépendant. D'autres relecteurs font la même revue de leur côté : ne cherche
pas leurs rapports, et **ne lis pas le dossier `docs/revues/`** en dehors de ce brief.

## Règles

- **Ne modifie, ne crée et ne supprime aucun fichier.** Lecture seule. Ton rapport est ton
  message final, rien d'autre.
- **Ne lance pas l'app ni ses modes de test** (`--selftest`, `--ab-test`, `scenario.sh`,
  `audioctl`) : ils touchent la sortie audio réelle de l'utilisateur. Ne lance pas de build.
- Lecture du code, `grep`, lecture des docs : oui.
- Rédige en **français**.

## Le produit

App macOS de barre des menus (Swift 6, SwiftUI, macOS 15+, Apple Silicon), environ 2 000
lignes. Elle égalise le son **uniquement quand les haut-parleurs d'un Apple Studio Display sont
la sortie système par défaut**, sans pilote virtuel :

- un *process tap* Core Audio (`CATapDescription`, par périphérique et par flux,
  `mutedWhenTapped`, qui exclut le processus Studio EQ) capte le son destiné à l'écran et coupe
  l'original ;
- un agrégat privé {entrée : le tap ; sortie : le Studio Display} le rejoue après filtrage
  (trois biquads RBJ, préampli automatique) dans une IOProc temps réel ;
- `CaptureCheck` vérifie que l'autorisation « Enregistrement audio du système » (TCC) est
  accordée **avant** de couper quoi que ce soit, car un tap refusé coupe l'original et ne livre
  que des zéros (silence total, mesuré).

Sandbox actif sans droit supplémentaire, Hardened Runtime, aucun réseau, aucune dépendance.

À lire d'abord : `README.md`, `docs/ARCHITECTURE.md`, `docs/FAISABILITE.md`, `docs/DSP.md`,
`docs/TESTS.md`. Code : `StudioEQ/` (App, Audio, DSP), `StudioEQTests/`, `scripts/`,
`project.yml`, `StudioEQ/Info.plist`, `StudioEQ/StudioEQ.entitlements`.

## Contexte de la revue

Le projet va être **publié sur GitHub sous GPL-2.0**, avec une GitHub Action qui construira un
**DMG signé Developer ID et notarisé**. La revue doit dire ce qui doit être corrigé avant.

## Ce qu'on attend

**Sécurité**
- Surface d'attaque, droits, sandbox, Hardened Runtime, TCC : le minimum nécessaire ?
- Confidentialité : le son capté peut-il fuir, être enregistré, persister ? Journaux (`os.Logger`,
  niveaux de confidentialité) : fuient-ils des données personnelles ?
- Code non sûr : pointeurs, `unsafeBitCast`, structures C de taille variable, débordements,
  durées de vie des objets utilisés depuis le thread d'E/S.
- Entrées non fiables : préférences `UserDefaults` (arguments de lancement), noms et UID de
  périphériques, valeurs Core Audio inattendues.
- Modes de test en ligne de commande livrés dans l'app de production : risque ?
- Scripts (`scripts/`) : injection, chemins, `sudo`, suppression.
- **Publication** : secrets, identifiants personnels, chemins locaux, identifiant d'équipe dans le
  dépôt ; ce qu'il faut pour signer et notariser en CI (Developer ID, Hardened Runtime,
  `get-task-allow`, horodatage) ; points du `project.yml` à adapter.

**Architecture et fiabilité**
- Temps réel : la fermeture IOProc et `EQProcessor.process` sont-elles vraiment sans allocation,
  verrou, appel bloquant, ni runtime Swift coûteux (retain/release, exclusivité, ARC) ?
- Concurrence Swift 6 : isolation, `@unchecked Sendable`, atomiques, ordre mémoire, objets
  partagés entre thread principal et thread d'E/S, démontage pendant que l'IOProc tourne.
- Cycle de vie Core Audio : création et destruction du tap et de l'agrégat, fuites en cas
  d'échec partiel, écouteurs jamais retirés, veille et réveil, changement de fréquence,
  périphérique qui disparaît, plantage.
- `AppModel.reconcile()` : courses, boucles de réessai, états incohérents, tâches
  asynchrones obsolètes (ex. `CaptureCheck` qui se termine après un changement de sortie).
- Risque de **silence ou de double lecture** (le pire défaut pour l'utilisateur) : un chemin
  mène-t-il à un original coupé sans son traité, ou aux deux joués ensemble ?
- Reconnaissance du Studio Display (`StudioDisplayMatcher`) : faux positifs, faux négatifs.
- DSP : stabilité, dénormaux, saturation, exactitude du préampli.
- Découpage, lisibilité, code mort, tests manquants qui comptent.

## Format du rapport

1. Résumé en 5 lignes au plus : verdict pour la publication.
2. Constats, **du plus grave au moins grave**. Pour chacun :
   - **Gravité** : critique / haute / moyenne / basse / info ;
   - **Catégorie** : sécurité / temps réel / concurrence / cycle de vie / fiabilité / DSP /
     publication / qualité ;
   - **Emplacement** : `fichier:ligne` ;
   - **Constat** et **preuve** (extrait de code ou raisonnement vérifiable) ;
   - **Scénario concret** qui produit le défaut ;
   - **Recommandation**.
3. Ce que tu as vérifié et jugé correct (bref), pour que l'on sache ce qui a été couvert.

Ne signale pas comme défaut une limitation déjà décrite dans `README.md` ou `docs/TESTS.md`,
sauf si tu contestes l'analyse qui en est faite. Préfère peu de constats prouvés à beaucoup de
soupçons ; marque « à vérifier » ce que tu ne peux pas prouver.
