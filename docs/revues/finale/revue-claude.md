# Revue finale de Studio EQ 1.0.0 : Claude

## 1. Résumé

**Verdict : la version 1.0.0 est saine et publiable telle quelle. Je n'ai trouvé aucun défaut critique ni de gravité haute prouvé.** Les points forts :
- le chemin temps réel est propre ;
- le cycle de vie du tap et de l'agrégat est correct ;
- les droits sont réduits au minimum (sandbox seul) ;
- la vérification TCC est faite avant chaque montage.

Les deux constats les plus sérieux :
- la détection d'une seconde instance ne voit que la session courante et n'est pas atomique (risque de silence ou de boucle à vérifier en changement rapide d'utilisateur) ;
- le limiteur, sans maintien, déforme les graves dès qu'il travaille : environ 3 % de distorsion harmonique à 40 Hz, contre une « légère compression » annoncée.

Le reste porte sur la robustesse de la publication, la CI et l'exactitude de la documentation.

## 2. Constats (du plus grave au moins grave)

### 1. Seconde instance : détection limitée à la session et non atomique, aucune gestion du changement d'utilisateur
- **Gravité** : moyenne (comportement audible **à vérifier**).
- **Catégorie** : fiabilité / cycle de vie.
- **Emplacement** : `StudioEQ/App/StudioEQApp.swift:43-58` ; `StudioEQ/Audio/TapEngine.swift:62-64` ; `StudioEQ/App/AppModel.swift:93-110`.
- **Constat** : la seule garde contre deux moteurs est `NSRunningApplication.runningApplications(withBundleIdentifier:)`.
  - Cette API ne liste que les apps de la **session de connexion courante**.
  - Le contrôle se fait une seule fois, au lancement.
  - Le tap n'exclut que le propre objet processus de l'app : `excludingProcesses: [own]`.
  - `AppModel` n'observe ni `sessionDidResignActiveNotification` ni `sessionDidBecomeActiveNotification`.
- **Preuve** : la doc d'architecture reconnaît elle-même que deux moteurs « captureraient chacune la sortie de l'autre, donc silence ou boucle ». Or `coreaudiod` est commun à toutes les sessions : un tap « tous les processus sauf moi » peut donc voir les processus d'une autre session. C'est ce point qu'il faut vérifier.
- **Scénarios** :
  - Mac partagé, deux comptes avec Studio EQ à l'ouverture de session. A est actif sur l'écran, B se connecte par changement rapide d'utilisateur. L'instance de B ne voit pas celle de A et démarre son moteur. Chaque tap capte, et coupe, la sortie traitée de l'autre : silence ou réinjection.
  - Plus simplement : l'instance de A, en arrière-plan, continue de couper (`mutedWhenTapped`) les apps de B. Elle les rejoue depuis une session inactive dont l'E/S peut être suspendue, ce qui donnerait du silence.
  - Dans une même session, deux lancements simultanés (élément d'ouverture et réouverture des fenêtres au login, ou double-clic) se voient mutuellement et **quittent tous les deux**. On perd alors l'égalisation, mais sans silence.
- **Recommandation** :
  - Arrêter le moteur (et annuler la vérification) sur `sessionDidResignActive`, puis remonter avec une nouvelle vérification sur `sessionDidBecomeActive`, comme pour la veille (drapeau du même type que `isAsleep`).
  - En défense en profondeur, exclure du tap tous les objets processus dont `kAudioProcessPropertyBundleID` vaut `com.jcbaptiste.StudioEQ` (liste `kAudioHardwarePropertyProcessObjectList`).
  - Pour rendre la garde atomique, prendre un `flock` non bloquant sur un fichier du conteneur au lancement plutôt que la liste des apps.
  - Faire le test manuel en changement rapide d'utilisateur.

### 2. Le limiteur sans maintien écrête la crête de chaque période dans les graves
- **Gravité** : moyenne.
- **Catégorie** : DSP.
- **Emplacement** : `StudioEQ/DSP/EQProcessor.swift:158-171` ; `README.md:76,107` ; `README.fr.md:113` ; `docs/DSP.md:34-38`.
- **Constat** : l'enveloppe vaut `env = max(peak, env * release)`, avec une attaque instantanée et **aucun maintien**. Entre deux crêtes d'un signal grave, l'enveloppe redescend de façon notable :
  - −5 % en 240 échantillons (demi-période d'un 100 Hz) ;
  - −12 % pour un 40 Hz à 44,1 kHz.

  À chaque nouvelle crête, l'enveloppe suit donc l'échantillon et la sortie reste collée au plafond : le sommet de chaque alternance est **aplati**. Ce n'est pas de la compression, c'est un écrêtage dur de la partie haute.
- **Preuve** : j'ai simulé hors du dépôt le même algorithme (plafond 0,977, relâchement 100 ms, 48 kHz) sur un sinus qui dépasse le plafond. Le taux de distorsion harmonique (DHT) en régime établi ne dépend pas du dépassement (×1,2 ou ×2) :

  | Fréquence | Sans maintien | Avec 25 ms de maintien |
  |---|---|---|
  | 40 Hz | 3,2 % | 0,000 % |
  | 50 Hz | 2,65 % | 0,000 % |
  | 100 Hz | 1,4 % | 0,000 % |
  | 1 kHz | 0,15 % | non simulé |

  Les tests ne vérifient que la crête (`testOutputNeverExceedsCeilingOnFullScaleSquareWaves`) et la transparence sous le plafond. Ils ne regardent jamais la qualité du signal pendant la limitation.
- **Scénario** : l'utilisateur monte les graves à +6 dB, soit +3 dB nets après le préampli. Sur un morceau masterisé près de 0 dBFS, les graves dépassent le plafond en continu. Le limiteur travaille alors en permanence et ajoute 2 à 3 % de distorsion sur la basse. Le README parle de « slight peak compression ».
- **Recommandation** :
  - Ajouter un maintien de l'enveloppe d'au moins une demi-période de la plus basse fréquence utile (20 à 25 ms) avant le relâchement. C'est un compteur, sans allocation.
  - Mieux encore : une anticipation courte (1 à 2 ms) avec un gain lissé.
  - Ajouter un test de DHT sur un sinus de 50 Hz limité.
  - Corriger la phrase du README.

### 3. Les échecs transitoires deviennent un état d'erreur permanent jusqu'au clic sur Réessayer
- **Gravité** : basse.
- **Catégorie** : fiabilité / cycle de vie.
- **Emplacement** : `StudioEQ/App/AppModel.swift:181-191` ; `StudioEQ/Audio/CaptureCheck.swift:88-89`.
- **Constat** : `permission = .failed` et `failedConfiguration` ne sont effacés qu'en quittant l'écran, en changeant de configuration ou par `retry()`.
  - La sonde échoue désormais en 2 s si la source ne progresse plus.
  - Un `TapEngine` qui échoue (par exemple `'!dev'`) bloque cette configuration.

  Un incident passager (écran en cours de réinitialisation au réveil, périphérique pris en mode exclusif un instant) laisse donc « Erreur » affiché et l'égalisation coupée sans limite de durée. Le son reste intact, donc ce n'est pas un silence.
- **Scénario** : réveil de veille, l'écran garde le même `AudioObjectID` mais son E/S met plus de 2 s à repartir. La vérification échoue (« the output stopped… »). Le menu reste sur l'erreur jusqu'au clic ou à un changement de sortie. Le test veille/réveil figure encore « À FAIRE » dans TESTS.md §8.
- **Recommandation** : prévoir un réessai automatique borné (par exemple un seul après 3 s, puis un délai croissant plafonné) pour les échecs de vérification et de montage. Garder l'absence de boucle au-delà.

### 4. Le contrôle « pas d'outils de validation » de `release.sh` ne marche qu'à moitié
- **Gravité** : basse.
- **Catégorie** : publication.
- **Emplacement** : `scripts/release.sh:66-67`.
- **Constat** : `strings … | grep -E -- "--selftest|TargetDeviceUID"`. En Swift, les littéraux de 15 octets UTF-8 ou moins sont des *small strings* encodées en valeurs immédiates. Ils n'apparaissent pas dans `strings`.
- **Preuve** : sur `build/Validation/…/StudioEQ` (Release + `VALIDATION`), `strings` affiche :
  - `--selftest`, `--list-devices`, `--ab-test`, `--permission-probe` ;
  - `SimulateEngineFailure` ;
  - mais **pas** `TargetDeviceUID` (15 octets), pourtant compilé (`AppModel.swift:274`).

  `--selftest` n'est trouvé que parce qu'il figure dans un littéral de tableau (`StudioEQApp.swift:32`), stocké en données. Un simple remaniement de ce code rendrait le contrôle silencieusement inopérant.
- **Recommandation** : chercher des marqueurs longs et stables (`SimulateEngineFailure`, `RESULT: `, `afplay process object`), ou le symbole du type `SelfTest` via `nm`.

### 5. La CI ne compile jamais la configuration distribuée
- **Gravité** : basse.
- **Catégorie** : tests / publication.
- **Emplacement** : `.github/workflows/ci.yml:23-24` ; `Makefile:48-53`.
- **Constat** : `make test` compile en Debug, où `VALIDATION` est actif. Les branches `#else` (`AppModel.swift:276-278`, `StudioEQApp.swift:33-34`) et la Release optimisée ne sont compilées que par `make build` ou `make publish`, sur le Mac du développeur. Une régression propre à la Release passe la CI et n'apparaît qu'à la publication.
- **Recommandation** : ajouter `make build` (Release, signature ad hoc) à la CI. On peut y ajouter le contrôle de l'absence des outils (constat 4) et l'épinglage de la version de XcodeGen (`brew install` n'est pas épinglé).

### 6. `make publish` : la correspondance entre binaire et source n'est pas garantie, et contrôles incomplets
- **Gravité** : basse.
- **Catégorie** : publication.
- **Emplacement** : `Config/Signing.xcconfig:13` ; `Makefile:99-107` ; `scripts/release.sh:44-50,58,77`.
- **Constats** :
  - **Réglages locaux** : `#include? "Local.xcconfig"` (fichier ignoré par git, invisible pour `git status --porcelain`) s'applique au build de publication. `release.sh` ne force que la signature et la version : tout autre réglage local (drapeaux Swift, conditions) entre dans le DMG. L'affirmation « le binaire publié doit correspondre exactement au code source publié » (RELEASE.md) n'est donc pas vérifiée. Le Team ID n'est pas vérifié non plus : `TeamIdentifier=` n'est comparé à `$TEAM_ID` ni pour l'app ni pour le DMG. Ce dernier est signé avec le nom générique `"Developer ID Application"` (`release.sh:77`).
  - **Étiquette distante** : `! git ls-remote --exit-code --tags …`. Une erreur réseau (code 128) est interprétée comme « étiquette absente ». C'est sans gravité, puisque le `git push` échouerait plus tard, mais seulement après un build et une notarisation complets.
  - **Version** : `make publish VERSION=x` publie une version qui diffère de `project.yml`, à l'étiquette près.
- **Recommandation** :
  - Faire passer `release.sh` sans `Local.xcconfig`, par exemple avec une variable qui court-circuite l'inclusion, ou refuser la publication si ce fichier contient autre chose que `DEVELOPMENT_TEAM` et `CODE_SIGN_IDENTITY`.
  - Comparer `TeamIdentifier` à `TEAM_ID` sur l'app et sur le DMG.
  - Distinguer le code 2 (« absente ») des autres codes de `ls-remote`.

### 7. Robustesse des scripts et portabilité
- **Gravité** : basse.
- **Catégorie** : qualité.
- **Emplacements et constats** :
  - `Makefile:77` : `--stdout $(CURDIR)/build/selftest.txt` n'est pas entre guillemets. Cela casse si le clone est dans un chemin avec une espace (la ligne 84 met bien des guillemets).
  - `scripts/release.sh:49` : `--keychain $KEYCHAIN` dans `OTHER_CODE_SIGN_FLAGS` est découpé en mots par xcodebuild, donc un chemin de trousseau avec une espace casse.
  - `scripts/release.sh:91` : si `notarytool submit` sort en erreur, `set -e` interrompt le script avant que le journal Apple soit récupéré.
  - `scripts/release.sh:93-95` : `/usr/bin/python3` déclenche l'installation des outils en ligne de commande sur un Mac neuf. `plutil -extract` ou `notarytool --output-format plist` suffisent.
  - `scenario.sh` et `audioctl.swift` : outils de test sans `-e` (choix assumé). Les déballages forcés (`v!`, `floatChannelData!`) n'ont pas d'impact en production.
- **Recommandation** : mettre les guillemets, passer le trousseau par `KEYCHAIN_FLAGS` comme à la ligne 77, et capturer le statut de `notarytool` (`|| true`, puis lire le JSON).

### 8. Code et travail réservés à la validation qui tournent dans l'IOProc de production ; commentaire temps réel inexact
- **Gravité** : info.
- **Catégorie** : temps réel / qualité.
- **Emplacement** : `StudioEQ/DSP/EQProcessor.swift:36-38,71-81,211-217` ; `StudioEQ/Audio/TapEngine.swift:28-30,149-155` ; `StudioEQ/Audio/CoreAudioHelpers.swift:40` ; `StudioEQ/DSP/EQDesign.swift:114`.
- **Constats** :
  - À chaque cycle, l'app distribuée balaie tout le buffer d'entrée (`anySignal`), incrémente `cycles` et `cyclesWithSignal`, et lit `silenceOutput`. Rien de cela n'est lu hors de `SelfTest` ou des tests. Le coût est faible mais inutile.
  - `filterResets` n'est jamais journalisé en production : une app qui envoie des `NaN` passerait inaperçue.
  - Code mort en production : `latencyDescription`, `processStereo` et `peakBoostDB` (tests seulement), le paramètre `qualifier` jamais utilisé, `TapEngine.processor` exposé pour `SelfTest`.
  - Le commentaire « no Objective-C/Swift runtime call » est inexact. `limiterEnvelope` est une propriété `var` de classe, d'où des appels `swift_beginAccess`/`swift_endAccess` (contrôle d'exclusivité, actif en Release). L'appel à `parameters.load()` peut aussi entraîner des retain/release atomiques. Ces appels ne verrouillent ni n'allouent : ce n'est pas bloquant.
- **Recommandation** :
  - Mettre les compteurs et `silenceOutput` sous `#if VALIDATION`, ou les exploiter : un chien de garde « tap muet » à partir de `cyclesWithSignal`, et un journal de `filterResets` côté thread principal.
  - Corriger le commentaire, ou garder l'enveloppe dans un pointeur alloué comme `gains`.

### 9. Écarts entre la documentation et le code
- **Gravité** : info.
- **Catégorie** : documentation.
- **Constats** :
  - `docs/ARCHITECTURE.md:4` annonce « ≈ 750 lignes de code applicatif, ≈ 380 de validation, ≈ 220 de tests ». Mesuré : environ 1 076 lignes de code applicatif hors commentaires et lignes vides (1 429 brutes), 335 pour `SelfTest`, 261 pour les tests.
  - `StudioEQTests/MatcherTests.swift:8-11` dit que le format d'UID doit « être revérifié sur le vrai matériel ». C'est fait (TESTS.md, rapports d'auto-test), donc le commentaire est périmé. Les tests utilisent aussi le model UID `Studio Display:05AC:1114`, et non la valeur réelle relevée, `Studio Display Audio Control:05AC:1114`. Il faudrait l'ajouter comme cas de référence.
  - `AppModel.swift:160` : pendant la veille, `status` n'est pas mis à jour (« Actif » reste affiché). C'est sans effet pratique, mais l'état est faux.
  - Les messages d'erreur montrés à l'utilisateur sont des descriptions techniques non traduites (`"create process tap failed ('who?')"`), via `Text("Error: \(message)")`.

### 10. Tests manquants qui auraient le plus de valeur
- **Gravité** : info.
- **Catégorie** : tests / architecture.
- **Constat** : `AppModel.update()` lit le HAL directement (`HAL.allDevices`, `HAL.defaultOutputDevice`) et monte le moteur lui-même. La machine à états est donc **intestable**, alors que c'est elle qui protège du silence : permission consommée, `failedConfiguration`, veille, annulation par génération.
- **Recommandation, par ordre de valeur** :
  1. Extraire une fonction pure `decide(état, sortie, événement) -> (action, nouvel état)` et la tester : sortie changée pendant la vérification, accord puis échec du montage, veille pendant la vérification, refus puis Réessayer.
  2. DHT du limiteur (constat 2).
  3. `process()` avec `tapBufferIndex > 0`, plusieurs buffers en entrée, une sortie plus large que l'entrée (canaux en trop silencieux) et `outFrames < frames` du tap.
  4. Disposition de `AudioHardwareIOProcStreamUsage` (décalages 0, 8 et 12).
- **Fragilité** : aucun test fragile repéré. Les tolérances sont raisonnables et le décompte des remises à zéro (`== 2`) est déterministe.

### 11. Préparer la version 1.1
- **Gravité** : info.
- **Catégorie** : architecture.
- **Constat** : le découpage détection / traitement / interface est net et tiendra. Trois points gêneront une 1.1 (autre écran, nouvelles fonctions) :
  - `AppModel` mêle lecture du HAL, décision, permission et préférences ;
  - `StudioDisplayMatcher` et la courbe `BandDesign` sont globaux et codés en dur ;
  - `EQSettings` n'a qu'un jeu de réglages.
- **Recommandation** : introduire un protocole « système audio » injectable (pour les tests du constat 10) et un « profil de périphérique » {critère de reconnaissance, bandes, réglages par défaut} plutôt qu'un booléen « Studio Display ».

### 12. Méthode de revue : `docs/revues/claude.md` est chargé automatiquement comme `CLAUDE.md`
- **Gravité** : info.
- **Catégorie** : publication / qualité.
- **Constat** : le système de fichiers macOS est insensible à la casse. Le fichier versionné `docs/revues/claude.md` est donc chargé par Claude Code comme mémoire de dossier (`CLAUDE.md`) dès qu'un agent lit un fichier de `docs/revues/`, y compris ce `BRIEF.md`.

  Son contenu (la revue précédente) a été injecté dans mon contexte sans que je l'ouvre. Cela contredit l'objectif d'un « regard neuf ». Je n'en ai repris aucun constat sans l'avoir revérifié moi-même sur le code ou les binaires.

  Ce fichier publié cite aussi le Team ID en clair. Ce n'est pas un secret (il figure dans toute signature), mais il ne figure nulle part ailleurs dans les fichiers suivis.
- **Recommandation** :
  - Renommer les rapports (par exemple `revue-claude.md`) ou placer le brief hors de `docs/revues/` pour les prochaines séries.
  - Je n'ai pas lu les autres fichiers de `docs/revues/` (consigne du brief) : il faut y vérifier l'absence d'identifiants personnels.

## 3. Vérifié et jugé correct

- **Droits** :
  - sandbox seul, Hardened Runtime ;
  - `CODE_SIGN_INJECT_BASE_ENTITLEMENTS: NO` en Release ;
  - aucun droit réseau ni micro ;
  - `NSAudioCaptureUsageDescription` présent ;
  - aucun processus auxiliaire ; `SMAppService.mainApp`.
  - `release.sh` vérifie l'autorité Developer ID, l'horodatage, le Hardened Runtime, un droit unique, l'absence de `get-task-allow`, la notarisation « Accepted », l'agrafage et `spctl`.
- **Confidentialité** :
  - aucun son écrit ni transmis ; taps et agrégats privés ;
  - journaux : UID et descriptions en `.private(mask: .hash)`, et seulement des états, codes et compteurs en `.public` ;
  - historique git (5 commits) sans chemin `/Users`, numéro de série ni Team ID hors `docs/revues` ;
  - rapports d'auto-test anonymisés (`<série>`, `<conteneur…>`) ; `Local.xcconfig` ignoré par git.
- **CI** : `permissions: contents: read`, `actions/checkout` épinglé par SHA, aucun secret. Le déclenchement sur `pull_request` est sans risque.
- **Code non sûr** :
  - disposition de `IOProcStreamUsage` (8 + 4 + 4n, alignement 8) ;
  - `HAL.array` (capacité, initialisation partielle) et `HAL.string` (`takeRetainedValue`) ;
  - bornes de `process()`, dérivées de `mDataByteSize` (`frames` ≤ min de l'entrée et de la sortie, au plus 16 canaux), et de `channel()` ;
  - motif de la sonde désormais par trame (commentaire juste).
- **Entrées non fiables** :
  - format du tap validé avant l'agrégat (LPCM, Float32, entrelacé, 32 bits, 1 à 16 canaux) ;
  - nombre de canaux inclus dans la clé « moteur à jour » et surveillé par `StreamConfiguration` ;
  - préférences JSON bornées ;
  - forçages lus seulement dans `NSArgumentDomain`, et seulement en `VALIDATION`.
- **Temps réel** : `process`, `filter`, `glide` et `limit` sont sans allocation, verrou, E/S ni journal. Les coefficients sont recalculés seulement pendant un glissement. Les états en `Double` sont vidés sous 1e-20.
- **`NaN`/`Inf`** : propagation garantie dans l'état (même avec des coefficients identité, `0 × NaN = NaN`) ; détection en fin de cycle, remise à zéro et cycle rendu muet avant le limiteur.
- **Limiteur** : la crête de sortie reste toujours sous le plafond (`env ≥ peak`).
- **Concurrence** :
  - blocs IOProc construits dans des méthodes non isolées ;
  - `EQParameters` et `Probe` sur des atomiques ;
  - écouteurs HAL et `NSWorkspace` sur la file principale avec `assumeIsolated` ;
  - modèle unique dans `AppInstance` (hors de la `struct App`) ;
  - vérification annulable avec numéro de génération, et `Task.sleep` qui lève l'annulation, de sorte que les `defer` nettoient.
- **Cycle de vie** :
  - ordre Stop → DestroyIOProc → agrégat → tap ;
  - nettoyage après un échec partiel ; `teardown` idempotent ;
  - le bloc retient `EQProcessor`, donc pas d'utilisation après libération ;
  - refus de démarrer si l'objet processus est inconnu ;
  - entrées autres que le tap désactivées (le micro n'est jamais ouvert) ;
  - `SleepingIsAllowed` ;
  - veille : arrêt et blocage des montages jusqu'au réveil, puis nouvelle vérification ;
  - accord TCC consommé à chaque montage, ce qui est cohérent avec le README.
- **Silence et double lecture** : en cas d'arrêt ou de plantage, `mutedWhenTapped` rend l'original. Aucun montage n'a lieu sans accord vérifié, et Studio EQ est exclu de son propre tap.
- **DSP** :
  - formules RBJ exactes ;
  - stabilité testée sur ±12 dB et de 44,1 à 192 kHz ;
  - préampli fixe de −3 dB cohérent avec la courbe par défaut ;
  - glissement sans clic.
- **Reconnaissance** : critères conjoints (transport, fabricant Apple, chaîne produit, canaux de sortie) ; les cas négatifs sont pertinents.
- **Contribution** : signature ad hoc par défaut, `#include?` optionnel, `make build` et `make test` sans compte développeur, projet généré non versionné. Chaînes FR et EN complètes, licence et en-têtes SPDX présents.
- **Documentation** : README, DSP.md et TESTS.md sont cohérents avec le code sur les comportements (préampli fixe, limiteur, `NaN`, une instance, revérification, nouvel essai quand la configuration change, 18 tests). Seules exceptions : les écarts listés aux constats 2 et 9.
