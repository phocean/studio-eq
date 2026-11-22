# Compte rendu de tests

Environnement : MacBook Pro M4, macOS 27.3 (26C5035r), Xcode 27.2, Swift 6.4.2, Apple Studio
Display (model UID `Studio Display Audio Control:05AC:1114`, flux de sortie 8 canaux 5.1.2,
44,1/48/88,2/96 kHz). Date : 21 novembre 2026.

Légende : **AUTO** = test automatisé rejouable · **MACHINE** = vérifié sur ce Mac par
mesure ou journaux · **HUMAIN** = vérifié à l'oreille ou à l'écran par l'utilisateur ·
**À FAIRE** = non exécuté.

## 1. Tests unitaires — AUTO (21/21 réussis)

`make test` ou ⌘U.

| Suite | Vérifie |
|---|---|
| `EQDesignTests` | Gains atteints (plateaux, mi-gain, centre de cloche) de −12 à +12 dB ; stabilité des filtres (pôles dans le cercle unité) sur toute la plage et à 44,1–192 kHz ; préampli fixe −3 dB : courbe par défaut ≤ 0 dB partout ; **sens des curseurs** : chacun rend sa bande plus forte quand il monte, de −12 à +12 dB, et ne déplace pas le reste du spectre de plus de 0,6 dB ; bornage et sérialisation des réglages ; réglages à plat = filtres identité. |
| `EQProcessorTests` | Sinus traité = réponse théorique (±0,05 dB) ; saut de 12 dB demandé → aucune discontinuité (glissement) et cible atteinte ; silence → sortie exactement nulle, aucune valeur non finie ; entrée entrelacée → sortie non entrelacée correcte ; **flux 8 canaux** : chaque canal ressort sur le même canal ; **limiteur** : carrés pleine échelle (50, 100, 1 000 Hz, quatre réglages extrêmes) jamais au-dessus de −0,2 dBFS, sinus à 0,9 inchangé, sinus de 40, 50 et 100 Hz au-dessus du plafond ramenés au plafond avec moins de 0,1 % de distorsion ; **NaN/Inf** injectés : sortie toujours finie, canal revenu au niveau attendu ; **rafale de ±3,4·10³⁸** : sortie finie, jamais muette, niveau attendu retrouvé. |
| `MatcherTests` | Studio Display reconnu : **identité réelle relevée** (`Studio Display Audio Control:05AC:1114`, 8 canaux), nom traduit, autre format d'UID, fabricant absent ; rejetés : haut-parleurs du Mac, AirPods, pilote virtuel « USB » (eqMac), micro de l'écran, adaptateur USB-C Apple, écran LG, appareil AirPlay nommé « Studio Display », agrégat. |

## 2. Chaîne audio de bout en bout — MACHINE

Auto-test `--selftest` : `afplay` (autre processus) joue 10 sons purs ; un tap de mesure capte
l'original, puis le moteur réel tourne et un second tap capte ce que Studio EQ envoie à l'écran.

| Sortie | Écart de forme max (courbe) | Décalage global | Latence ajoutée mesurée | CPU pendant le traitement |
|---|---|---|---|---|
| Haut-parleurs MacBook Pro (cible de test), 48 kHz, Debug | 0,00 dB | 0,00 dB | — | 1,9 % (Debug, mesure incluse) |
| **Studio Display**, 48 kHz, 8 canaux, Release (1er essai) | 0,08 dB (écart brut) | — | — | 0,25 % |
| **Studio Display**, 44,1 kHz, Release | 0,07 dB (écart brut) | — | **5,2 ms** | 0,37 % |
| **Studio Display**, 48 kHz, Release (version finale) | **0,01 dB** | +0,29 dB | **4,2 ms** | 0,33 % |

Réglages par défaut dans tous les cas. Rapports bruts : [48 kHz](selftest-studio-display-48k.txt),
[44,1 kHz](selftest-studio-display-44k1.txt). Le niveau **traité** est identique à 0,01 dB près
sur les trois essais à 48 kHz. Le décalage global vient de la capture de **référence**, dont le
niveau varie de quelques dixièmes de dB d'un essai à l'autre. L'auto-test sépare donc l'erreur de
forme (critère < 0,5 dB) et le décalage global (critère < 1 dB).

Latence ajoutée : les deux flux (original et traité) sont capturés simultanément, alignés sur
leurs horodatages, puis le délai résiduel est obtenu par corrélation croisée. Ce délai comprend
le délai de groupe des filtres (< 1 ms au-dessus de 100 Hz).

## 3. Absence de double lecture — HUMAIN

`--ab-test` sur le Studio Display : un son de 440 Hz passe par le moteur ; une période de 2 s
sur deux, la sortie de Studio EQ est rendue muette. Résultat rapporté : **silence total pendant
les périodes muettes**. L'original est donc réellement coupé : pas d'écho, pas de double
lecture. Par construction, le processus Studio EQ est exclu du tap (pas de boucle) et le moteur
refuse de démarrer s'il ne peut pas s'exclure.

## 4. Permission refusée — MACHINE + HUMAIN

| Étape | Résultat |
|---|---|
| Prototype sans protection, autorisation refusée | **Son coupé net** (rapporté). Le tap tourne (~187 cycles/s) mais ne livre que des zéros, et l'original reste coupé. **Défaut critique, corrigé.** |
| Version corrigée, autorisation refusée | `CaptureCheck` conclut « refusé » en ≈ 1,2 s, **le moteur n'est pas démarré, le son reste intact**, le menu affiche « Autorisation de capture audio manquante » + bouton Réglages. |
| Autorisation accordée ensuite dans Réglages Système, puis « Réessayer » | Vérification accordée en 0,6 s → **Actif** sur le Studio Display (rapporté + journaux). |

## 5. Bascules et périphériques

| Scénario | Méthode | Résultat |
|---|---|---|
| Studio Display ↔ haut-parleurs du Mac, musique en cours | HUMAIN + journaux | Inactif sur le Mac, actif au retour sur l'écran, sans intervention (moteur remonté en 5 ms après l'événement). |
| Musique dans un navigateur et dans un lecteur ; interrupteur et curseurs | HUMAIN | Effet audible, **aucun clic, coupure ni saut de volume**. |
| Volume et sourdine de l'écran pendant l'égalisation | HUMAIN | Normaux. |
| Deuxième sortie qui apparaît / est sélectionnée / disparaît ; écran simulé branché, sélectionné, débranché pendant l'activité, rebranché | AUTO `scripts/scenario.sh` (périphérique agrégé temporaire en guise d'écran) | 10/10 conformes. macOS re-sélectionne seul un périphérique qui revient, et l'app suit. |
| Débrancher / rebrancher le câble du vrai Studio Display | HUMAIN | Réponse « reprend seul » reçue, mais **aucun débranchement n'apparaît dans les journaux** : test considéré **non observé, à refaire**. |
| AirPods | — | **À FAIRE** (logique identique à « autre sortie », couverte ci-dessus). |
| Changement de fréquence 48 → 44,1 → 48 kHz (haut-parleurs du Mac, puis **Studio Display**) | MACHINE (`audioctl rate`) | Moteur reconstruit automatiquement à chaque changement ; auto-test réussi à 44,1 kHz sur l'écran. |
| Autorisation retirée dans Réglages Système pendant la lecture | HUMAIN + journaux | **Le son continue** ; l'app reste en marche, aucun événement. La vérification faite avant le prochain montage du moteur traite le refus. |
| Échec de démarrage du moteur (`-SimulateEngineFailure YES`) | MACHINE | État « Erreur » + Réessayer, moteur non démarré, donc **original jamais coupé** ; une tentative, plus un seul nouvel essai automatique 3 s après (depuis 1.1.0), sans boucle. Nouvel essai automatique dès que la configuration change (fréquence, canaux, sortie). Revérifié après la revue (journaux : une seule tentative). |

## 6. Ressources — MACHINE (build Release)

| Mesure | Résultat |
|---|---|
| CPU, sortie active, aucune lecture depuis le lancement | ≈ 0 % (l'E/S du tap ne tourne pas tant que rien ne joue) |
| CPU en lecture (haut-parleurs du Mac / Studio Display 8 canaux) | ≈ 0,2 % / 0,25 % d'un cœur |
| CPU après la fin d'une lecture (E/S restée active) | ≈ 0,3 % d'un cœur |
| **Lecture continue de 10 min sur le Studio Display** (relevé chaque minute) | **0,18 % d'un cœur**, mémoire stable à ≈ 99 Mo. Seul pic (≈ 2 s de CPU) : ouverture du menu par l'utilisateur, coût de rendu SwiftUI. |
| Mémoire résidente | ≈ 75–108 Mo (base d'une app SwiftUI), stable |
| Assertion de veille due à Studio EQ | **aucune** (`pmset -g assertions`) |
| Latence **ajoutée** par Studio EQ (mesurée) | **4,2 ms** à 48 kHz, 5,2 ms à 44,1 kHz |
| Latence de sortie totale annoncée par l'agrégat (inclut les 22 ms propres à l'écran, présentes aussi sans Studio EQ) | 27,6 ms |

## 7. Validation après les revues de code (21 novembre 2026)

Trois revues indépendantes (Claude, Codex, Grok) : rapports et synthèse dans
[revues/](revues/SYNTHESE.md). Après correction :

| Vérification | Méthode | Résultat |
|---|---|---|
| Tests unitaires | AUTO | 18/18 (5 nouveaux : sens des curseurs, 8 canaux, limiteur, transparence du limiteur, NaN). |
| Chaîne complète sur le Studio Display, 48 kHz | MACHINE (`make selftest`, build de validation optimisé) | **Réussi** trois fois. Sans autre son en cours : écart de forme **0,01 dB**, décalage global +0,10 dB. Deux essais précédents ; 4,2 ms ajoutées ; 0,39 % d'un cœur. Écart de forme 0,00–0,02 dB de 700 Hz à 16 kHz ; 0,3–0,4 dB, de signe variable, de 40 à 300 Hz, parce que l'utilisateur écoutait de la musique pendant la mesure (elle est captée avec les sons de test). Les rapports de référence ci-dessus restent valables : avec les réglages par défaut et un niveau normal, le traitement est mathématiquement identique. |
| Bascules (`make scenario`) avec vérification d'autorisation à chaque montage | AUTO | 10/10. |
| Échec de démarrage simulé | MACHINE | Une seule tentative, état « Erreur ». |
| Deuxième instance lancée pendant que l'app tourne | MACHINE | Elle se ferme aussitôt ; l'app installée reste seule et active. |
| Build distribué sans outils de test | MACHINE | Aucune trace de `--selftest`, `-TargetDeviceUID` ni `afplay` dans le binaire Release. |
| Journaux | MACHINE | UID affichés sous forme d'empreinte (`<mask.hash: …>`). |

## 8. Reste à exécuter — À FAIRE

| Test | Comment |
|---|---|
| Changement rapide d'utilisateur, Studio EQ ouvert dans les deux sessions | Journaux : moteur arrêté quand la session passe en arrière-plan, remonté au retour ; le son de l'autre session n'est ni coupé ni doublé. |
| Cocher « Masquer l'icône sans Studio Display », débrancher puis rebrancher l'écran | L'icône disparaît au débranchement, revient au branchement ; ouvrir Studio EQ depuis le Finder la fait revenir entre-temps. |
| Écouter une basse forte avec les graves à +6 dB (limiteur au travail) | Plus de grain ni de saturation dans les graves (correction du limiteur, 1.1.0). |
| Débrancher / rebrancher le câble du Studio Display en cours de lecture | Vérifier « Aucun Studio Display connecté » puis « Actif » au retour, sans clic. Journaux : `/usr/bin/log show --last 5m --info --predicate 'subsystem == "com.jcbaptiste.StudioEQ"'` (chemin complet : sous zsh, `log` seul est une commande intégrée). |
| Basculer vers des AirPods et revenir | État « Inactif : la sortie son est … », son des AirPods non traité. |
| Mise en veille puis réveil avec l'écran sélectionné | Le moteur est arrêté à la veille et remonté au réveil ; le son doit reprendre égalisé. |
| Cocher « Ouvrir à l'ouverture de session », redémarrer le Mac | Studio EQ présent dans la barre des menus et actif si l'écran est la sortie. |
| Réglages conservés après « Quitter » puis relance | Modifier un curseur, quitter, relancer. |
| Lecture prolongée de musique réelle (≥ 1 h) | Aucun craquement ; CPU stable (Moniteur d'activité). |
| Écouter les curseurs après le passage au préampli fixe | Monter et baisser chaque curseur : seule sa bande doit changer, sans saut de volume général. |

## 9. Validation après la revue finale (22 novembre 2026)

Revue finale de la version 1.0.0 publiée : [revues/finale/](revues/finale/SYNTHESE.md).
Corrections de la version 1.1.0 (préparée sous le numéro 1.0.1) :

| Vérification | Méthode | Résultat |
|---|---|---|
| Tests unitaires | AUTO | 21/21 (3 nouveaux : distorsion du limiteur, échantillons démesurés, identité réelle de l'écran). |
| Les deux nouveaux tests DSP détectent bien les défauts | MACHINE | Lancés sur le code 1.0.0 : **échec**, 3,2 % de distorsion à 40 Hz (2,6 % à 50 Hz, 1,4 % à 100 Hz), et sortie muette (−∞ dB) après la rafale. Réussis sur le code corrigé. |
| Contrôles de `release.sh` | MACHINE | Passent sur l'app 1.0.0 publiée ; bloquent le build de validation (symboles `SelfTest`) et un build Debug (droits en plus du sandbox, dont `get-task-allow`). |
| `SKIP_NOTARIZATION=1` exporté puis `make release` | MACHINE (`make -n`) | Le script reçoit `SKIP_NOTARIZATION=0`. |
| DMG d'essai (`make dmg`) avec les nouveaux contrôles | MACHINE | Build Release 1.0.1 signé Developer ID : tous les contrôles passent. |
| Deuxième copie lancée pendant que l'app tourne | MACHINE + journaux | Elle quitte (« another instance is running ») ; la première reste active. |
| Échec de montage simulé (`-SimulateEngineFailure YES`, build de validation) | MACHINE + journaux | Échec, « automatic retry after a failure » 3 s plus tard avec nouvelle vérification, second échec, puis plus aucune tentative. Son jamais coupé. |
| **Deux copies lancées au même instant** (`open -n` ×2) | MACHINE + journaux | Une seule quitte, l'autre monte le moteur et passe « active » sur le Studio Display. |

## 10. Option « Masquer l'icône sans Studio Display » (22 novembre 2026)

MACHINE, build de validation. L'option est passée sur la ligne de commande
(`-HideIconWithoutDisplay YES`), l'absence d'écran simulée par `-TargetDeviceUID none`. Les
icônes de la barre des menus ne sont pas visibles des autres processus : le build de validation
journalise le nombre de ses fenêtres d'icône (« menu bar icon windows », une par barre des
menus, 5 sur ce Mac).

| Cas | Résultat |
|---|---|
| Option active, pas d'écran | 0 fenêtre : icône masquée. |
| Puis Studio EQ rouvert (`open`) | 5 : icône affichée. |
| Option active, pas d'écran, puis seconde copie (`open -n`) | La copie quitte ; 0 → 5 : icône affichée. |
| Option active, écran branché | 5. |
| Option inactive, pas d'écran | 5. |

Reste à faire (§8) : débrancher puis rebrancher le vrai écran avec l'option cochée dans le menu.

