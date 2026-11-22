# Revue finale de Studio EQ 1.0.0 : Codex

## 1. Résumé

La 1.0.0 présente une architecture compacte, lisible et une surface d’attaque réduite ; aucun défaut critique n’est démontré.
Un cas d’entrée numérique extrême peut toutefois empoisonner durablement le limiteur et rendre toute la sortie silencieuse.
Trois contrôles de publication méritent d’être renforcés : détection des outils de validation, notarisation obligatoire et vérification des droits.
Les tests DSP sont pertinents ; les décisions et annulations d’`AppModel` restent sans couverture unitaire.
Revue statique du tag `v1.0.0` (`032d4d5`), dont le code est identique à HEAD `9aabab5` ; aucun fichier modifié, aucun build ni essai audio lancé, aucun rapport antérieur consulté.

## 2. Constats, par priorité décroissante

### 1 — Une conversion en Float peut rendre le limiteur définitivement silencieux

- **Gravité : moyenne**
- **Catégorie : DSP**
- **Emplacement :** `StudioEQ/DSP/EQProcessor.swift:137`, `:144`, `:163`.

**Constat et preuve.** Le filtre calcule en `Double`, puis écrit `Float(y)`. Sa protection vérifie seulement que les états récursifs en `Double` sont finis. Un résultat supérieur au maximum représentable en `Float` devient donc infini sans déclencher cette protection.

Le limiteur exécute ensuite :

```swift
env = max(peak, env * release)
let g = ceiling / env
```

Avec `peak == .infinity`, `env` devient infini et `g` vaut zéro. Les échantillons infinis deviennent `NaN` par multiplication par zéro. Aux cycles suivants, `infinity * release` reste infini : les échantillons normaux sont alors multipliés par zéro, sur **tous les canaux**.

**Scénario concret.** Un flux Float32 contient des valeurs finies proches de `Float.greatestFiniteMagnitude`, avec une accentuation suffisante, par exemple une sinusoïde à 1,5 kHz et les médiums à +12 dB. Le calcul reste fini en `Double`, mais déborde à la conversion. Le silence persiste après le retour à un signal normal, jusqu’à reconstruction du processeur.

Le défaut du processeur découle du code ; l’acheminement de telles amplitudes par le tap Core Audio reste **à vérifier**, sans reproduction matérielle ici.

**Recommandation.** Contrôler la représentabilité et la finitude des valeurs avant leur écriture en Float ; réinitialiser aussi toute enveloppe non finie. Ajouter un test « entrée finie extrême, puis signal normal », vérifiant sortie finie, plafond et récupération.

### 2 — Le contrôle d’absence des outils de validation peut manquer une correspondance

- **Gravité : moyenne**
- **Catégorie : publication**
- **Emplacement :** `scripts/release.sh:66`.

**Constat et preuve.**

```sh
strings "$APP/Contents/MacOS/StudioEQ" | grep -q -E -- "--selftest|TargetDeviceUID" \
  && fail "validation tools compiled into the distributed app"
```

Le script active `pipefail`. Dès sa première correspondance, `grep -q` peut fermer le tube alors que `strings` écrit encore. Si `strings` reçoit `SIGPIPE`, le pipeline devient non nul malgré la correspondance ; `fail` n’est pas exécuté. Comme le pipeline est à gauche de `&&`, `set -e` ne provoque pas non plus l’arrêt.

**Scénario concret.** Un binaire contenant les outils de validation présente une chaîne recherchée avant une quantité suffisante d’autres chaînes. Le contrôle peut annoncer leur absence à tort. Le déclenchement exact dépend du binaire et du tamponnement ; il n’a pas été exécuté ici.

**Recommandation.** Faire consommer intégralement la sortie de `strings`, sans `grep -q`, et distinguer explicitement correspondance, absence et erreur. Vérifier également que les conditions de compilation Release excluent `VALIDATION`.

Le code publié est bien protégé par `#if VALIDATION` ; ce constat concerne la fiabilité de la vérification supplémentaire.

### 3 — `make publish` accepte le contournement de notarisation réservé aux essais

- **Gravité : moyenne**
- **Catégorie : publication**
- **Emplacement :** `Makefile:92`, `:105`, `scripts/release.sh:80`.

**Constat et preuve.** `make publish` appelle `make release`, qui transmet l’environnement au script. Celui-ci saute notarisation, agrafage et contrôle Gatekeeper lorsque `SKIP_NOTARIZATION=1`, puis termine normalement. La publication poursuit alors la création de l’étiquette et de la release GitHub.

**Scénario concret.** `SKIP_NOTARIZATION` reste exporté après un essai local, ou l’opérateur lance `SKIP_NOTARIZATION=1 make publish`. Un DMG non notarisé peut être publié malgré la garantie décrite dans `docs/RELEASE.md`.

**Recommandation.** Forcer `SKIP_NOTARIZATION=0` dans la cible `release`, et réserver la valeur `1` à `dmg`. Ajouter un contrôle final de notarisation avant l’étiquetage et l’envoi.

Rien dans cette revue ne démontre que le DMG 1.0.0 publié a subi ce contournement.

### 4 — La vérification des entitlements ne vérifie ni leur nombre réel ni la valeur du sandbox

- **Gravité : moyenne**
- **Catégorie : publication**
- **Emplacement :** `scripts/release.sh:61`.

**Constat et preuve.** Le script recherche le nom du droit sandbox, puis utilise :

```sh
grep -c "<key>"
```

Cette commande compte les **lignes** contenant une clé, pas les clés du dictionnaire. Plusieurs droits sur une seule ligne satisfont donc le contrôle. La présence du texte `com.apple.security.app-sandbox` ne prouve pas davantage que sa valeur est `true`.

**Scénario concret.** Une évolution introduit un droit réseau, ou désactive le sandbox. Un XML compact contenant plusieurs clés sur une ligne, ou le seul droit sandbox à `false`, passe ces assertions.

**Recommandation.** Analyser le plist signé et exiger l’égalité exacte avec :

```text
{"com.apple.security.app-sandbox": true}
```

Les fichiers de configuration actuels déclarent correctement le sandbox seul ; le défaut porte sur la capacité du contrôle à détecter une régression.

### 5 — Les décisions et annulations d’AppModel ne sont pas testées unitairement

- **Gravité : moyenne**
- **Catégorie : tests**
- **Emplacement :** `StudioEQ/App/AppModel.swift:152`, `:215`, `StudioEQTests/DSPTests.swift:8`, `StudioEQTests/MatcherTests.swift:12`.

**Constat et preuve.** Les 18 tests présents couvrent le DSP et la reconnaissance matérielle. Aucun ne teste `AppModel`, alors que celui-ci décide quand couper l’original, annuler une vérification, consommer une autorisation ou bloquer une nouvelle tentative.

Ses dépendances concrètes — HAL, `DeviceMonitor`, `CaptureCheck` et `TapEngine` — rendent ces parcours difficiles à tester sans matériel.

**Scénario concret à couvrir.** Une vérification démarre sur l’écran A ; l’utilisateur change de sortie ou désactive l’égalisation ; une ancienne vérification termine ensuite avec `.granted`. Une régression du contrôle de génération pourrait alors déclencher un montage obsolète. Le contrôle existe actuellement, mais aucun test ne protège cette propriété.

**Recommandation.** Introduire des dépendances injectables légères, ou extraire la décision dans une fonction pure. Prioriser :

- résultat tardif après changement de sortie, désactivation, veille ou arrêt ;
- autorisation consommée après chaque montage ;
- échec moteur sans boucle de réessai ;
- reprise sur changement de configuration et bouton Réessayer.

Ces tests peuvent fonctionner sans ouvrir de périphérique audio.

### 6 — La documentation d’architecture conserve des éléments de l’ancien DSP

- **Gravité : basse**
- **Catégorie : documentation**
- **Emplacement :** `docs/ARCHITECTURE.md:4`, `:15`.

**Constat et preuve.** Le tableau attribue encore à `EQDesign.swift` un « préampli automatique », alors que `EQDesign.preampDB` est fixe à −3 dB. Les volumes annoncés sont également anciens : environ 750 lignes applicatives et 220 lignes de tests, contre respectivement **1 429 hors SelfTest** et **323** dans les fichiers actuels.

**Scénario concret.** Un contributeur utilise ce document pour préparer une évolution DSP et part d’un mécanisme de compensation qui n’existe plus.

**Recommandation.** Corriger « préampli automatique » et actualiser ou supprimer les comptes de lignes. `docs/DSP.md` décrit correctement le mécanisme actuel.

## 3. Vérifié et jugé correct

- **Découpage :** responsabilités claires entre découverte matérielle, montage audio, DSP et interface. Il peut accueillir une 1.1 sans réécriture générale.
- **Confidentialité :** aucun chemin d’enregistrement audio ni accès réseau trouvé dans le code distribué ; préférences seules persistées. UID masqués dans les journaux. Les rapports numériques versionnés consultés anonymisent les numéros de série et chemins privés.
- **Permissions :** sandbox seul dans les configurations versionnées, Hardened Runtime activé, injection des droits de débogage désactivée en Release.
- **Cycle de vie :** nettoyage des créations partielles, démontage idempotent, vérification non muette avant montage, annulation avec numéro de génération, arrêt à la veille et à la fermeture.
- **Temps réel :** tampons préalloués, paramètres atomiques, absence d’allocation explicite, de verrou, de journalisation ou d’E/S bloquante dans le traitement. L’absence absolue de coûts runtime demanderait une inspection du binaire ou un profilage.
- **DSP et tests :** formules RBJ cohérentes, préampli fixe, limiteur lié entre canaux ; tests utiles de stabilité, réponse, correspondance des canaux, silence et récupération NaN/Inf.
- **Contribution et CI :** signature ad hoc par défaut, configuration personnelle ignorée, action checkout épinglée, permissions CI en lecture et absence de secret requis.

Le DMG publié, sa signature effective et sa notarisation n’ont pas été inspectés. Les essais matériels déjà indiqués comme restant à faire ne sont pas requalifiés ici en défauts.