# Architecture

Application de barre des menus (`LSUIElement`), Swift 6 / SwiftUI, macOS 15+, Apple Silicon,
sandbox actif, Hardened Runtime, **aucune dépendance externe**. Hors commentaires et lignes vides (version 1.0.1) : ≈ 1 150 lignes de code applicatif, plus
≈ 340 lignes d’outils de validation (`SelfTest.swift`) et ≈ 300 lignes de tests.

## Fichiers

| Dossier | Fichier | Rôle |
|---|---|---|
| `StudioEQ/Audio` | `CoreAudioHelpers.swift` | Accès typé aux propriétés HAL (`HAL.value/string/array/set`), erreurs lisibles (codes à 4 caractères). |
| | `OutputDevice.swift` | Identité matérielle d'une sortie + `StudioDisplayMatcher` (reconnaissance du Studio Display). |
| | `DeviceMonitor.swift` | Surveillance **événementielle** : sortie par défaut, liste des périphériques, fréquence/format/vie de la sortie courante. Coalescence 150 ms, pas de polling. |
| | `CaptureCheck.swift` | Vérifie que la capture audio est autorisée **avant** de couper quoi que ce soit. |
| | `TapEngine.swift` | Chemin audio : process tap + agrégat privé + IOProc ; montage, démarrage, démontage. |
| `StudioEQ/DSP` | `EQDesign.swift` | Réglages, géométrie des bandes, coefficients RBJ, réponse en fréquence, préampli fixe (−3 dB). |
| | `EQProcessor.swift` | Traitement temps réel multicanal, lissage, limiteur, contrôle des échantillons invalides. |
| `StudioEQ/App` | `StudioEQApp.swift` | Point d'entrée, `MenuBarExtra`, icône d'état. |
| | `AppModel.swift` | Logique de décision (`reconcile`), préférences, lancement à l'ouverture de session. |
| | `MenuContent.swift` | Panneau du menu. |
| | `SelfTest.swift` | Outils de validation en ligne de commande (auto-test numérique, A/B, sonde permission). Compilé seulement dans les builds de validation. |
| `StudioEQ/Resources` | `*.xcstrings` | Chaînes : anglais (source) + français. |
| `StudioEQTests` | | Tests unitaires DSP, temps réel, reconnaissance du Studio Display. |
| racine | `Makefile` | Point d'entrée unique : génération du projet, build, tests, installation, validation, DMG, publication (`make help`). |
| `scripts` | `release.sh`, `scenario.sh`, `audioctl.swift` | Publication signée et notarisée (appelée par `make publish`, `make release` et `make dmg`) ; scénarios de bascule automatisés ; pilote de test (sortie par défaut, fréquence, faux périphérique, son de test). |

Séparation demandée : **détection** (`DeviceMonitor`, `OutputDevice`) / **traitement**
(`TapEngine`, `CaptureCheck`, `DSP/`) / **interface et préférences** (`App/`).

## Décision : une seule fonction, idempotente

`AppModel.reconcile()` est appelée au lancement, à chaque événement matériel, au réveil, et à
chaque action de l'utilisateur. Elle relit l'état réel et décide :

```
égalisation désactivée                      → moteur arrêté        → « désactivée »
sortie par défaut ≠ Studio Display          → moteur arrêté        → « aucun écran » / « autre sortie »
en veille                                   → moteur arrêté        → (rien jusqu'au réveil)
sortie = Studio Display, moteur à jour      → rien                 → « actif »
sortie = Studio Display, moteur à (re)monter → CaptureCheck (async, annulable) → « vérification… »
                         capture refusée    → moteur arrêté        → « autorisation manquante »
                         capture accordée   → moteur monté ; l'accord est consommé : le montage
                                              suivant revérifie     → « actif »
                         vérification non concluante (sortie arrêtée, délai) → comme un échec de montage
échec du montage                            → moteur arrêté        → « erreur » + Réessayer ;
                                              un seul nouvel essai automatique après 3 s,
                                              puis plus rien tant que la configuration
                                              (UID, fréquence, canaux) ne change pas, ni
                                              réveil, ni Réessayer
session en arrière-plan (changement rapide
d'utilisateur)                              → moteur arrêté        → (rien jusqu'au retour)
```

Un Studio Display seulement **présent** ne déclenche jamais l'égalisation : seule la sortie
système par défaut compte.

- **Vérification annulable** : une vérification en cours est abandonnée (et son résultat
  ignoré, grâce à un numéro de génération) si la sortie change, à la veille, à la
  désactivation ou à « Quitter ». Elle échoue aussi en 2 s si le périphérique cesse de répondre
  (écran débranché) au lieu d'attendre son délai maximal.
- **Veille** : moteur arrêté proprement, plus aucun montage jusqu'au réveil, même si un
  événement matériel arrive entre-temps ; au réveil, montage complet avec nouvelle vérification,
  et les échecs passés sont oubliés.
- **Changement rapide d'utilisateur** : même traitement que la veille tant que la session est
  en arrière-plan (`NSWorkspace.sessionDidResignActive` / `sessionDidBecomeActive`). La copie
  d'un autre utilisateur peut tourner dans la session au premier plan, et le verrou ci-dessous,
  propre à chaque utilisateur, ne la voit pas.
- **Une seule instance** : verrou exclusif `flock` sur un fichier du conteneur, pris au
  lancement et libéré par le noyau à la sortie ou au plantage. Contrairement à l'ancienne
  lecture de la liste des apps lancées, il est atomique : deux copies lancées au même instant ne
  peuvent pas l'obtenir toutes les deux. Pas de `LSMultipleInstancesProhibited`, qui empêcherait
  aussi les tests unitaires de démarrer pendant que l’app tourne. Deux instances captureraient
  chacune la sortie de l'autre, donc silence ou boucle.
- **Fréquence d'échantillonnage** vérifiée au montage (8 à 384 kHz), sinon refus de démarrer :
  une fréquence nulle ou aberrante donnerait des filtres muets alors que l'original est coupé.
- **Format du tap** vérifié au montage (Float32 entrelacé, 1 à 16 canaux), sinon refus de
  démarrer : l'original n'est jamais coupé pour un flux qui sortirait muet.

## Reconnaissance du Studio Display

Jamais par le nom affiché (localisé : « Haut-parleurs Studio Display »). Critères matériels,
tous requis :

- transport USB (ou Thunderbolt) — l'audio de l'écran est une fonction USB Audio Class ;
- fabricant Apple : VID USB `05AC` dans le *model UID*, ou fabricant « Apple Inc. » ;
- chaîne produit « Studio Display » dans le *model UID* ou le *device UID* (construits par le
  pilote à partir des descripteurs USB) ;
- au moins un canal de sortie (le micro de l'écran est un périphérique distinct).

Valeurs relevées sur l'écran de test : model UID `Studio Display Audio Control:05AC:1114`,
UID `AppleUSBAudioEngine:Apple Inc.:Studio Display:<série>:8,9`, 8 canaux. Les pilotes
virtuels qui se déclarent « USB » (eqMac le fait) sont rejetés par le critère fabricant.

## Fils d'exécution

- **Thread principal** : décisions, HAL non temps réel, interface. Écouteurs HAL livrés sur la
  file principale.
- **Thread d'E/S Core Audio** : uniquement `EQProcessor.process` (et les blocs de mesure). Les
  blocs IOProc sont construits hors de tout acteur : en Swift 6, une fermeture créée dans une
  fonction `@MainActor` hérite de son isolation et provoque un arrêt contrôlé quand Core Audio
  l'appelle sur son thread (constaté pendant le prototype).

## Permissions et sécurité

| Élément | Valeur | Pourquoi |
|---|---|---|
| Sandbox | activé, **aucun droit supplémentaire** | Le tap et l'agrégat privé fonctionnent dans le sandbox (vérifié). |
| Hardened Runtime | activé, aucune exception | |
| TCC | `NSAudioCaptureUsageDescription` → « Enregistrement de l'écran et de l'audio du système » (audio seul) | Indispensable pour lire un process tap. Le micro n'est **jamais** ouvert (les flux d'entrée autres que le tap sont désactivés si l'agrégat en a). |
| Réseau | aucun droit réseau | Le sandbox interdit tout accès réseau. |
| Données | réglages dans `UserDefaults` (conteneur sandbox) | Aucun son enregistré, rien transmis, pas de télémétrie, pas de compte. |
| Privilèges | aucun droit admin, aucun pilote, aucun processus auxiliaire | |
| Lancement à l'ouverture de session | `SMAppService.mainApp` | API standard, visible et révocable dans Réglages Système › Général › Ouverture. |
| Icône masquée sans écran (option) | `MenuBarExtra(isInserted:)` ; réouverture (`applicationShouldHandleReopen`) ou notification distribuée `com.jcbaptiste.StudioEQ.revealIcon`, sans contenu, envoyée par une seconde copie avant de quitter | N'importe quel processus peut envoyer cette notification : elle ne fait qu'afficher l'icône. |

## Outils de validation (sans interface)

Ils ne sont compilés que dans les **builds de validation** (condition `VALIDATION`, active en
Debug) : l'app distribuée ne les contient pas, et elle ignore `-TargetDeviceUID` et
`-SimulateEngineFailure`. Même en validation, ces deux réglages ne sont lus que sur la ligne de
commande, jamais dans les préférences enregistrées. `make validation` produit un build optimisé
qui les contient ; `make selftest` et `make scenario` l'utilisent. À la main :

```
make validation
V=build/Validation/Build/Products/Release/StudioEQ.app
open -W -n --stdout out.txt $V --args --list-devices
open -W -n --stdout out.txt $V --args --selftest [--device <uid>]
open -W -n --stdout out.txt $V --args --ab-test  [--device <uid>]
open -W -n --stdout out.txt $V --args --permission-probe [--device <uid>]
open -n $V --args -TargetDeviceUID <uid>   # cible de test ≠ Studio Display
open -n $V --args -SimulateEngineFailure YES
```

`--selftest`, `--ab-test` et `--permission-probe` refusent de tourner si Studio EQ est déjà
lancé (deux moteurs sur le même écran se chaîneraient). Les journaux masquent les UID des
périphériques (empreinte `privacy: .private(mask: .hash)`) : l'UID d'un appareil Bluetooth
contient son adresse matérielle, celui du Studio Display son numéro de série.
