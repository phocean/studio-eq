# Compte rendu de tests

Environnement : MacBook Pro M4, macOS 27.3 (26C5035r), Xcode 27.2, Swift 6.4.2, Apple Studio
Display (model UID `Studio Display Audio Control:05AC:1114`, flux de sortie 8 canaux 5.1.2,
44,1/48/88,2/96 kHz). Date : 21 novembre 2026.

Légende : **AUTO** = test automatisé rejouable · **MACHINE** = vérifié sur ce Mac par
mesure ou journaux · **HUMAIN** = vérifié à l'oreille ou à l'écran par l'utilisateur ·
**À FAIRE** = non exécuté.

## 1. Tests unitaires — AUTO (18/18 réussis)

`make test` ou ⌘U.

| Suite | Vérifie |
|---|---|
| `EQDesignTests` | Gains atteints (plateaux, mi-gain, centre de cloche) de −12 à +12 dB ; stabilité des filtres (pôles dans le cercle unité) sur toute la plage et à 44,1–192 kHz ; préampli fixe −3 dB : courbe par défaut ≤ 0 dB partout ; **sens des curseurs** : chacun rend sa bande plus forte quand il monte, de −12 à +12 dB, et ne déplace pas le reste du spectre de plus de 0,6 dB ; bornage et sérialisation des réglages ; réglages à plat = filtres identité. |
| `EQProcessorTests` | Sinus traité = réponse théorique (±0,05 dB) ; saut de 12 dB demandé → aucune discontinuité (glissement) et cible atteinte ; silence → sortie exactement nulle, aucune valeur non finie ; entrée entrelacée → sortie non entrelacée correcte ; **flux 8 canaux** : chaque canal ressort sur le même canal ; **limiteur** : carrés pleine échelle (50, 100, 1 000 Hz, quatre réglages extrêmes) jamais au-dessus de −0,2 dBFS, sinus à 0,9 inchangé ; **NaN/Inf** injectés : sortie toujours finie, canal revenu au niveau attendu. |
| `MatcherTests` | Studio Display reconnu (y compris nom traduit, autre format d'UID, fabricant absent) ; rejetés : haut-parleurs du Mac, AirPods, pilote virtuel « USB » (eqMac), micro de l'écran, adaptateur USB-C Apple, écran LG, appareil AirPlay nommé « Studio Display », agrégat. |

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
| Échec de démarrage du moteur (`-SimulateEngineFailure YES`) | MACHINE | État « Erreur » + Réessayer, moteur non démarré, donc **original jamais coupé** ; une seule tentative, sans boucle. Nouvel essai automatique dès que la configuration change (fréquence, canaux, sortie). Revérifié après la revue (journaux : une seule tentative). |

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
| Débrancher / rebrancher le câble du Studio Display en cours de lecture | Vérifier « Aucun Studio Display connecté » puis « Actif » au retour, sans clic. Journaux : `log show --last 5m --info --predicate 'subsystem == "com.jcbaptiste.StudioEQ"'`. |
| Basculer vers des AirPods et revenir | État « Inactif : la sortie son est … », son des AirPods non traité. |
| Mise en veille puis réveil avec l'écran sélectionné | Le moteur est arrêté à la veille et remonté au réveil ; le son doit reprendre égalisé. |
| Cocher « Ouvrir à l'ouverture de session », redémarrer le Mac | Studio EQ présent dans la barre des menus et actif si l'écran est la sortie. |
| Réglages conservés après « Quitter » puis relance | Modifier un curseur, quitter, relancer. |
| Lecture prolongée de musique réelle (≥ 1 h) | Aucun craquement ; CPU stable (Moniteur d'activité). |
| Écouter les curseurs après le passage au préampli fixe | Monter et baisser chaque curseur : seule sa bande doit changer, sans saut de volume général. |
