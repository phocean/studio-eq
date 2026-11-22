# Revue de code : sécurité et architecture, Studio EQ

## 1. Résumé (verdict pour la publication)

**Pas prêt à publier en l'état.** Le cœur de l'app est sain : surface d'attaque minimale, IOProc propre, cycle de vie du tap et de l'agrégat correct. En revanche :
- **la chaîne de signature actuelle ne passera pas la notarisation** (`get-task-allow`, certificat « Apple Development », pas d'horodatage, vérifié sur `dist/`) ;
- **le dépôt contient des identifiants personnels** : numéro de série de l'écran, chemin `/Users/…`, logiciels installés. Il n'y a pas de fichier de licence ;
- **trois chemins mènent encore au silence** : autorisation mise en cache pour toute la session, deux instances simultanées, `NaN` qui empoisonne les filtres ;
- **le préampli n'empêche pas l'écrêtage**, contrairement à ce qu'affirme la doc.

Il faut corriger les points 1 à 6 avant la publication. Le reste peut suivre.

## 2. Constats (du plus grave au moins grave)

### 1. La signature Release n'est pas notarisable
- **Gravité** : haute. **Catégorie** : publication.
- **Emplacement** : `project.yml:12-15`, `StudioEQ.xcodeproj/project.pbxproj:358-363,421-426`, `scripts/install.sh:6-9`.
- **Constat et preuve** : `codesign -d --entitlements - dist/StudioEQ.app` (le build Release produit par `install.sh`) renvoie `com.apple.security.get-task-allow = true`. `codesign -dvv` affiche `Authority=Apple Development: contact@…`, et aucune ligne `Timestamp=`. Le notary service rejette un binaire qui a `get-task-allow`, qui n'est pas signé « Developer ID Application » ou qui n'a pas d'horodatage sécurisé. Le Hardened Runtime est bien actif (`flags=0x10000(runtime)`).
- **Scénario** : la GitHub Action fait `xcodebuild build` avec ce `project.yml`, puis `notarytool submit`. La soumission est refusée (« The executable requests the com.apple.security.get-task-allow entitlement », « not signed with a valid Developer ID certificate », « does not include a secure timestamp »).
- **Recommandation** :
  - Pour Release : `CODE_SIGN_IDENTITY = "Developer ID Application"`, `CODE_SIGN_INJECT_BASE_ENTITLEMENTS = NO`, `OTHER_CODE_SIGN_FLAGS = --timestamp`. Ou mieux : `xcodebuild archive` puis `-exportArchive` avec `method = developer-id`.
  - Ne pas coder `DEVELOPMENT_TEAM` en dur. Le passer par un xcconfig non versionné ou par une variable d'environnement CI. Garder la Debug en « Apple Development ».
  - En CI : importer le .p12 dans un trousseau temporaire (secrets GitHub), utiliser une clé API App Store Connect pour `notarytool`, signer aussi le DMG, puis `stapler staple` sur le DMG.
  - Vérifications bloquantes : `codesign --verify --strict --deep`, `codesign -d --entitlements -` (refuser si `get-task-allow` apparaît), `spctl -a -t exec -vv` sur l'app et `spctl -a -t open --context context:primary-signature` sur le DMG.

### 2. L'autorisation est mise en cache pour toute la session : un retrait peut produire un silence total au montage suivant
- **Gravité** : haute. **Catégorie** : fiabilité / cycle de vie.
- **Emplacement** : `StudioEQ/App/AppModel.swift:65-67`, `:139-143`, `:154-156` ; `README.md:69-71`.
- **Constat et preuve** : `permission` ne revient à `.unknown` que s'il vaut `.denied` ou `.failed` (lignes 141-142), ou via `retry()`. Une fois `.granted`, il le reste jusqu'à la fin du processus. Ensuite, `case .granted: break` monte directement un `TapEngine` en `mutedWhenTapped`, sans nouvelle vérification. Le README affirme pourtant que le refus « n'est pris en compte qu'au prochain montage du moteur, où il est détecté sans couper le son ». Le code ne fait pas cette détection. TESTS.md:70 parle seulement du « prochain démarrage », ce qui correspond à la relance de l'app. Je conteste donc l'analyse du README. Enfin, les compteurs `cycles` et `cyclesWithSignal` de `EQProcessor`, qui permettraient de voir un tap qui ne livre que des zéros, ne sont lus nulle part en production (seulement dans `SelfTest.swift:176`).
- **Scénario** :
  1. Autorisation accordée, égalisation active.
  2. L'utilisateur retire l'autorisation dans Réglages Système. Le son continue, comme documenté.
  3. Il passe sur les AirPods puis revient au Studio Display. Une mise en veille suivie d'un réveil, ou un changement de fréquence, produisent le même effet.
  4. Un nouveau tap est créé sans vérification. Si macOS applique le refus aux nouveaux taps du processus (**à vérifier**, c'est exactement le comportement mesuré dans FAISABILITE.md §1), l'original est coupé, le tap ne livre que des zéros, et l'écran reste muet sans aucune indication dans le menu.
- **Recommandation** :
  - Repasser `permission` à `.unknown` à chaque sortie du Studio Display et à chaque réveil, ou au minimum avant chaque montage qui suit un démontage.
  - Ajouter un chien de garde : si `cycles` progresse pendant environ 1 s alors que `cyclesWithSignal` reste à 0 depuis le montage, arrêter le moteur, repasser `permission` à `.unknown` et relancer `CaptureCheck`. Le seul faux positif possible (une app qui joue du silence numérique) aboutit à une simple revérification.
  - Corriger le README.

### 3. Aucune garde contre deux instances : les taps se capturent mutuellement (silence ou boucle de réinjection)
- **Gravité** : haute (le comportement audible exact est **à vérifier**). **Catégorie** : fiabilité / concurrence.
- **Emplacement** : `StudioEQ/Audio/TapEngine.swift:59-61` ; `StudioEQ/App/StudioEQApp.swift:15`. `grep` ne trouve ni `runningApplications` ni `LSMultipleInstancesProhibited`.
- **Constat et preuve** : chaque instance exclut **seulement son propre** objet processus (`excludingProcesses: [own]`). Avec deux instances A et B sur l'écran :
  - le tap de A capte les apps **et la sortie de B**, et la coupe ; le tap de B fait la même chose avec la sortie de A ;
  - les deux sorties traitées sont donc coupées : on obtient le silence ;
  - en parallèle, A rejoue `EQ(apps + sortie de B)` et B rejoue `EQ(apps + sortie de A)`. C'est une boucle dont le gain vaut 0 dB autour de 1,5 kHz (préampli compris), donc le signal s'accumule.
  
  ARCHITECTURE.md reconnaît le chaînage pour `--selftest`, mais pas pour deux instances normales.
- **Scénario** : avec un DMG, c'est classique. L'utilisateur lance l'app depuis le volume monté pendant que la copie de `/Applications` tourne déjà (ouverture de session). Autre cas : `open -n`, utilisé dans `scenario.sh`. Résultat : écran muet, et probablement une bouffée forte quand l'une des deux instances quitte (**à vérifier**).
- **Recommandation** :
  - Ajouter `LSMultipleInstancesProhibited = YES` dans `Info.plist`.
  - Au lancement, détecter une autre instance (`NSRunningApplication.runningApplications(withBundleIdentifier:)`, en excluant son propre PID) et quitter.
  - En défense en profondeur, exclure du tap tous les objets processus dont `kAudioProcessPropertyBundleID` vaut le bundle ID de l'app (liste `kAudioHardwarePropertyProcessObjectList`).

### 4. Un seul `NaN` ou `Inf` en entrée empoisonne définitivement l'état des filtres
- **Gravité** : moyenne (haute si le HAL ne nettoie pas les `NaN` du mixage, **à vérifier**). **Catégorie** : DSP / fiabilité.
- **Emplacement** : `StudioEQ/DSP/EQProcessor.swift:111-121`.
- **Constat et preuve** : `flush` ne teste que `abs(v) < 1e-20`. Comme `abs(NaN) < 1e-20` est faux, un `NaN` est conservé (vérifié). `Inf` produit des `NaN` via `Inf − Inf` dans la forme directe transposée. Une fois dans `z0…z5`, le `NaN` se propage à chaque échantillon suivant, sur le canal concerné et pour toujours. Il n'y a aucun contrôle `isFinite` et aucun test qui couvre ce cas.
- **Scénario** : une app boguée (moteur Web Audio, plugin) émet un seul échantillon `NaN` vers l'écran. Sans Studio EQ, on entend un clic. Avec Studio EQ, le canal reste muet ou bruité (selon la conversion du `NaN` par le HAL) tant que le moteur n'est pas reconstruit, c'est-à-dire jusqu'à un changement de sortie ou de fréquence. L'original reste coupé pendant tout ce temps.
- **Recommandation** : en fin de cycle, si un état n'est pas fini, remettre l'état du canal à zéro. C'est un test bon marché, une fois par buffer. Ajouter un test unitaire avec un `NaN` puis un sinus.

### 5. Le préampli automatique n'empêche pas l'écrêtage, contrairement à la doc
- **Gravité** : moyenne. **Catégorie** : DSP.
- **Emplacement** : `StudioEQ/DSP/EQDesign.swift:110-122` ; `docs/DSP.md:22-24`.
- **Constat et preuve** : une courbe d'amplitude ≤ 0 dB ne borne pas la valeur crête. Les filtres à phase minimale déplacent les harmoniques en phase. J'ai simulé en Python les mêmes formules RBJ que le code, avec les réglages par défaut et un préampli de −3,01 dB :
  - carré pleine échelle à 50, 100 et 200 Hz : crête de sortie 1,39 / 1,39 / 1,43, soit environ +3 dBFS ;
  - bruit grave limité à 0 dBFS : crête 1,25 ;
  - graves −12 dB (préampli 0 dB) sur un carré à 100 Hz : crête 1,73.
  
  La sortie `Float32` est écrêtée à la conversion vers le périphérique. La phrase « un signal qui ne saturait pas ne peut pas être poussé en saturation par l'EQ » est fausse.
- **Scénario** : un morceau masterisé au plafond (la plupart des sorties actuelles) avec les réglages par défaut. Les transitoires graves dépassent 0 dBFS, ce qui produit une distorsion audible sur les passages forts.
- **Recommandation** : ajouter une marge fixe (−2 à −3 dB) ou, mieux, un écrêteur doux ou un limiteur simple en fin de chaîne, sans allocation. Corriger DSP.md et le commentaire de `autoPreampDB`. Ajouter un test sur la crête avec un signal carré.

### 6. Identifiants personnels et données locales dans le dépôt ; licence absente
- **Gravité** : moyenne. **Catégorie** : publication.
- **Emplacement** :
  - `docs/selftest-studio-display-48k.txt:2,7,24` et `docs/selftest-studio-display-44k1.txt:2,7,24` ;
  - `project.yml:3,12,40` ; `README.md:35` ; `StudioEQ.xcodeproj/project.pbxproj:362,425` ;
  - `StudioEQTests/MatcherTests.swift:18` ;
  - `.gitignore`.
- **Constat et preuve** :
  - Les rapports d'auto-test contiennent le **numéro de série de l'écran de l'auteur** (`…Studio Display:<série>:8,9`), le chemin `~/Library/Containers/…` et l'inventaire des pilotes audio installés (eqMac, Microsoft Teams Audio).
  - L'identifiant d'équipe `<équipe>` est en dur à trois endroits. Ce n'est pas un secret, puisqu'il figure dans toute signature, mais c'est un identifiant personnel, et il casse le build de quiconque fait un fork.
  - `MatcherTests` contient un autre numéro de série, présenté comme tiré d'un rapport public (**à vérifier**).
  - `StudioEQ.xcodeproj`, qui est un fichier généré, n'est pas ignoré.
  - Il n'y a aucun fichier `LICENSE`/`COPYING`, aucun en-tête SPDX, et `NSHumanReadableCopyright` est vide.
  - Le dossier n'est pas encore un dépôt git : rien n'a fuité dans l'historique pour l'instant.
- **Scénario** : la publication sur GitHub expose le numéro de série de l'écran (traçable jusqu'à l'achat ou la garantie) et le nom du compte local.
- **Recommandation** :
  - Remplacer le numéro de série et le chemin par `<série>` et `~` dans les deux rapports, et retirer les lignes eqMac et Teams.
  - Utiliser un numéro de série fictif dans les tests.
  - Sortir `DEVELOPMENT_TEAM` dans un xcconfig local.
  - Décider si l'on versionne `.xcodeproj` ou si l'on lance `xcodegen` en CI (et l'ignorer dans ce cas).
  - Ajouter `LICENSE` (GPL-2.0-only ou GPL-2.0-or-later : à choisir explicitement), des en-têtes SPDX et le copyright dans l'`Info.plist`.
  - Faire paramétrer la version (`CFBundleShortVersionString` et `CFBundleVersion`, codés en dur à 1.0/1) par la CI.

### 7. `CaptureCheck` ne peut pas être annulé et dépend du périphérique de départ
- **Gravité** : basse. **Catégorie** : cycle de vie / concurrence.
- **Emplacement** : `StudioEQ/App/AppModel.swift:158-171`, `StudioEQ/Audio/CaptureCheck.swift:72-83`.
- **Constat et preuve** : la `Task` n'est jamais annulée et reste liée à `output.id`. Si l'écran est débranché pendant la vérification, les IOProcs de la sonde s'arrêtent, `cycles` ne progresse plus, et la boucle attend le délai de 120 s avant de lever une erreur, qui aboutit à `.failed`. Pendant tout ce temps, `permission == .checking` bloque tout nouveau montage (ligne 158). Ensuite, `.failed` reste affiché tant que l'utilisateur ne quitte pas l'écran ou ne clique pas sur Réessayer. Le résultat est global à l'app, ce qui est correct puisque l'autorisation porte sur le processus, mais une erreur matérielle sur l'ancien périphérique est mal interprétée.
- **Scénario** : vérification en cours, câble débranché puis rebranché. On reste jusqu'à 2 minutes sur « Vérification… » sans égalisation, puis on voit « Erreur : … timed out ».
- **Recommandation** : garder un handle sur la `Task`, l'annuler dans `update()` quand la sortie change (comparer l'UID), et repasser à `.unknown`. Arrêter aussi la sonde si `sourceCycles` n'avance plus.

### 8. Journaux : identifiants matériels en `privacy: .public`
- **Gravité** : basse. **Catégorie** : sécurité (confidentialité).
- **Emplacement** : `StudioEQ/App/AppModel.swift:124`, `:183` ; `StudioEQ/Audio/TapEngine.swift:109`.
- **Constat et preuve** : `output=\(…uid, privacy: .public)` est journalisé à chaque changement d'état, quelle que soit la sortie. L'UID d'un périphérique Bluetooth contient son **adresse MAC** (forme `AA-BB-CC-DD-EE-FF:output`, cf. les tests). `device.description` contient le numéro de série de l'écran. Ces messages sont de niveau `.info`, donc non persistés par défaut, mais ils sont lisibles en clair via `log stream` et dans les captures que les utilisateurs joignent aux tickets. Aucun contenu audio n'est journalisé.
- **Recommandation** : utiliser `privacy: .private(mask: .hash)` pour les UID, ou ne journaliser que le type de transport et un booléen « cible ».

### 9. Modes de test et préférences de forçage livrés dans l'app de production
- **Gravité** : basse. **Catégorie** : sécurité / fiabilité.
- **Emplacement** : `StudioEQ/App/StudioEQApp.swift:8-9`, `StudioEQ/App/SelfTest.swift` (388 lignes), `StudioEQ/App/AppModel.swift:113-118,215-220`.
- **Constat et preuve** :
  - Tout processus local peut lancer l'app avec `--ab-test`, ce qui coupe le son de l'écran une période de 2 s sur deux, ou avec `--selftest`, qui exécute `afplay`, écrit des WAV de 3 à 8 Mo jamais supprimés dans le `tmp` du conteneur et démarre un second moteur.
  - `TargetDeviceUID` et `SimulateEngineFailure` sont lus dans `UserDefaults.standard`. Un `defaults write` oublié (persistant, contrairement à l'argument de lancement) détourne en silence la reconnaissance de l'écran ou bloque le moteur, sans rien afficher dans le menu.
  - Aucune fuite de données : le test ne capte que `afplay` et sa propre sortie, et le rapport ne contient que des niveaux en dB. Le risque reste au niveau de l'utilisateur local.
- **Recommandation** : compiler `SelfTest` et les deux forçages sous `#if DEBUG`, ou derrière un réglage de build `VALIDATION`. À défaut, ne lire les forçages que dans `NSArgumentDomain` (`UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)`), et supprimer les WAV en fin de test.

### 10. `install.sh` masque un échec de compilation et installe l'ancien build
- **Gravité** : basse. **Catégorie** : qualité / publication.
- **Emplacement** : `scripts/install.sh:6-9`.
- **Constat et preuve** : avec `set -o pipefail`, le statut de `xcodebuild … | grep … || true` est celui de `xcodebuild`, et `|| true` l'efface. Si un build précédent existe dans `build/DerivedData`, `codesign --verify` réussit sur cet ancien produit, qui est alors copié dans `dist/` et `/Applications`, puis le script affiche « Installed ».
- **Recommandation** : supprimer `|| true` (ou tester `${pipestatus[1]}`) et effacer `$APP` avant de compiler. Ne pas réutiliser ce script en CI.
- **À noter aussi** :
  - `scenario.sh` tue l'instance de l'utilisateur, laisse la sortie par défaut sur les haut-parleurs du Mac sans restaurer l'originale, et suppose que `build/audioctl` existe sans dire comment le compiler.
  - `audioctl.swift` fait des déballages forcés (`!`) sur les arguments.
  - Aucun `sudo` dans les scripts. Les `rm -rf` portent sur des chemins fixes : il n'y a pas de risque d'injection.

### 11. Changement de format de flux surveillé mais ignoré ; format du tap incomplètement validé
- **Gravité** : basse. **Catégorie** : cycle de vie.
- **Emplacement** : `StudioEQ/Audio/DeviceMonitor.swift:43`, `StudioEQ/App/AppModel.swift:146-150`, `StudioEQ/Audio/TapEngine.swift:69-73,105`, `StudioEQ/DSP/EQProcessor.swift:151`.
- **Constat et preuve** :
  - L'écouteur `kAudioDevicePropertyStreamConfiguration` déclenche `reconcile()`, mais le test « moteur à jour » ne compare que l'ID, l'UID, la fréquence et `isAlive`. Un changement de format ne reconstruit donc rien.
  - `tapIndex = inputStreams.count - 1` suppose que chaque flux correspond à un seul buffer, donc un format entrelacé. Le drapeau `kAudioFormatFlagIsNonInterleaved` n'est pas vérifié, et le nombre de canaux du tap n'est pas comparé à celui de la sortie.
  - Dans tous ces cas, `process()` sort du silence (garde ligne 151) ou ne traite que certains canaux, alors que l'original est coupé.
- **Recommandation** : refuser au montage un tap non entrelacé ou dont le nombre de canaux diffère de la sortie. Inclure le nombre de canaux dans la clé « moteur à jour ». Le chien de garde du constat 2 couvre aussi ces cas.

### 12. Temps réel : propre, sans preuve outillée
- **Gravité** : info. **Catégorie** : temps réel.
- **Emplacement** : `StudioEQ/DSP/EQProcessor.swift:86-98,138-170` ; `StudioEQ/Audio/TapEngine.swift:114-116`.
- **Constat et preuve** :
  - Je n'ai trouvé ni allocation, ni verrou, ni appel système, ni journal dans le chemin.
  - Restent deux coûts possibles. D'abord, `preampLinear` est une propriété `var` de classe : sans optimisation sur tout le module, Swift insère `swift_beginAccess` (contrôle d'exclusivité, sans verrou ni allocation). Ensuite, en Debug, l'appel `proc.process` et l'accès à `parameters` peuvent provoquer des retain/release atomiques. Rien de bloquant.
  - La fonction locale `step` capture `changed`. Elle ne s'échappe pas, donc la promotion sur la pile s'applique (**à vérifier** en -Onone).
  - Le balayage `anySignal` (ligne 161) parcourt tout le buffer à chaque cycle, uniquement pour des compteurs que l'app n'exploite pas.
- **Recommandation** : annoter `process` et `filter` avec `@_noLocks` ou `@_noAllocation` pour une vérification statique par le compilateur, ou passer RTSan une fois. Soit exploiter les compteurs (constat 2), soit retirer le balayage.

### 13. Veille : état affiché périmé et course possible
- **Gravité** : info. **Catégorie** : cycle de vie.
- **Emplacement** : `StudioEQ/App/AppModel.swift:84-89`.
- **Constat** : `willSleep` arrête le moteur sans mettre `status` à jour (« Actif » reste affiché). Un événement matériel entre `willSleep` et la mise en veille effective reconstruit le moteur. Au réveil, `reconcile()` le juge alors « à jour » s'il est encore vivant, contrairement au commentaire « rebuild from scratch ».
- **Recommandation** : ajouter un drapeau `isAsleep` qui court-circuite `update()` entre `willSleep` et `didWake`, et forcer la reconstruction au réveil.

### 14. Qualité, code mort, doc inexacte, tests manquants
- **Gravité** : info. **Catégorie** : qualité.
- **Code mort ou inutilisé en production** : le paramètre `qualifier` jamais utilisé dans `HAL.value` (`CoreAudioHelpers.swift:37`) ; `latencyDescription`, `processStereo`, `silenceOutput`, `cycles` et `cyclesWithSignal` ne servent qu'aux tests et outils.
- **Commentaire inexact** : le motif de la sonde (`CaptureCheck.swift:115`) alterne le signe par indice d'échantillon *entrelacé*. Sur 8 canaux, chaque canal reçoit donc une composante continue de ±1e-6, et non un signal à la fréquence de Nyquist. C'est inoffensif (−120 dBFS), mais le commentaire est faux.
- **Doc inexacte** : TESTS.md:71 annonce un « nouvel essai automatique dès que le matériel change ». En réalité, `failedConfiguration` n'est effacé qu'en quittant l'écran, en changeant de fréquence ou par Réessayer.
- **À vérifier** : `@State private var model = AppModel()` dans la `struct App` (`StudioEQApp.swift:15`). Si SwiftUI réinitialisait la structure, deux `AppModel` coexisteraient, avec deux taps dans le même processus et une double lecture. Créer le modèle dans l'`AppDelegate` ou en statique éliminerait le doute.
- **Tests manquants qui comptent** :
  - la machine à états de `reconcile` (permission, échec, changement de sortie pendant la vérification), à extraire en fonction pure ;
  - une entrée `NaN` ;
  - la crête de sortie ;
  - `process()` avec un tap à 8 canaux et plusieurs buffers en entrée ;
  - la disposition de `AudioHardwareIOProcStreamUsage`.

## 3. Vérifié et jugé correct

- **Droits** : sandbox seul, Hardened Runtime sans exception, aucun droit réseau ni micro, `NSAudioCaptureUsageDescription` présent. Le minimum est respecté. Pas de processus auxiliaire. `SMAppService.mainApp` est utilisé correctement.
- **Confidentialité audio** : rien n'est écrit sur disque, rien ne sort du processus. Taps et agrégats sont privés. `MeasurementTap` ne garde les échantillons qu'en mémoire.
- **Code non sûr** :
  - la structure `AudioHardwareIOProcStreamUsage` est correcte sur arm64 (pointeur 8 octets, `UInt32` à 8, tableau à 12) ;
  - `unsafeBitCast` d'un pointeur de fonction vers un pointeur brut : tailles identiques ;
  - `HAL.string` libère correctement la valeur retournée (`takeRetainedValue`) ;
  - `HAL.array` : l'initialisation partielle est correcte même en cas d'erreur ;
  - les bornes de lecture et d'écriture de `process()` découlent de `mDataByteSize`, et `z` est dimensionné pour 16 canaux.
- **Durées de vie** : les blocs IOProc retiennent fortement `EQProcessor`, `Probe` et `MeasurementTap`. Le démontage suit l'ordre Stop → DestroyIOProc → agrégat → tap. `TapEngine.init` nettoie après un échec partiel, et `teardown` est idempotent. Les `defer` de `CaptureCheck` s'exécutent dans le bon ordre.
- **Concurrence** : les blocs IOProc sont construits hors acteur. `EQParameters` utilise des atomiques relaxés, et un mélange transitoire de champs anciens et nouveaux est sans conséquence. L'état de `EQProcessor` n'est touché que par le thread d'E/S après sa publication par `AudioDeviceStart`. Les écouteurs HAL et `NSWorkspace` sont sur la file principale.
- **Reconnaissance du Studio Display** : critères conjoints (transport, VID/fabricant, chaîne produit, canaux de sortie). Je n'ai pas trouvé de faux positif réaliste (agrégats, AirPlay et eqMac sont rejetés). Le risque de faux négatif sur un futur modèle est documenté.
- **DSP** :
  - formules RBJ exactes ;
  - stabilité testée sur toute la plage et de 44,1 à 192 kHz ;
  - le préampli calculé à 48 kHz reste valable à 44,1 kHz (écart < 0,01 dB, recalculé, y compris au-dessus de 20 kHz pour les plateaux à +12 dB) ;
  - pas de dénormaux (états en `Double` vidés en dessous de 1e-20, et Apple Silicon ne ralentit pas sur les dénormaux) ;
  - glissement des paramètres sans clic ;
  - `NaN` impossible depuis les préférences (JSON + bornage).
- **Exclusion de Studio EQ du tap** : le moteur refuse de démarrer si l'objet processus est inconnu.
- **Scripts** : pas de `sudo`, chemins fixes, arguments entre guillemets là où c'est nécessaire.
