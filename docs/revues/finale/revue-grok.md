# Revue finale de Studio EQ 1.0.0 : Grok

## Résumé

La version 1.0.0 publiée est saine pour l’usage prévu. Le chemin audio est cohérent : on ne coupe l’original qu’après un tap dont le format est accepté, le processus s’exclut lui-même, et un échec de montage laisse le son intact. Le bac à sable, la chaîne de signature et le DSP tiennent ensemble. Je n’ai pas trouvé de défaut critique. Les points qui restent sont des garde-fous manquants (taux nul, deux lancements simultanés), une publication contournable par une variable d’environnement, et des tests qui ne couvrent pas la machine à états.

Je n’ai ni lancé l’app, ni exécuté `make`, ni ouvert `docs/revues/`.

## Constats

### 1. Un taux d’échantillonnage nul ou non fini démarre un moteur qui ne peut produire que du silence

- **Gravité** : moyenne
- **Catégorie** : fiabilité
- **Emplacement** : `StudioEQ/Audio/TapEngine.swift:105`, `StudioEQ/DSP/EQDesign.swift:58`, `StudioEQ/DSP/EQProcessor.swift:144`

Le format du tap est refusé avant `AudioDeviceStart` si ce n’est pas du Float32 entrelacé, 1 à 16 canaux. Le taux nominal de l’agrégat est ensuite pris tel quel :

```105:115:StudioEQ/Audio/TapEngine.swift
        sampleRate = try HAL.value(aggregateID, kAudioDevicePropertyNominalSampleRate, initial: Float64(0))
        tapFormat = (try? HAL.value(tapID, kAudioTapPropertyFormat, initial: AudioStreamBasicDescription())) ?? tapFormat
        // ...
        let proc = EQProcessor(sampleRate: sampleRate, parameters: parameters)
```

`BiquadCoefficients.make` calcule `w0 = 2π f / sampleRate`. À 0, `cos` vaut `NaN`, les coefficients aussi. Chaque cycle, l’état n’est plus fini, le canal est remis à zéro et le tampon de sortie est effacé (`EQProcessor.swift:144-149`). Le tap est déjà en `mutedWhenTapped` : l’original est coupé, la copie égalisée est silencieuse.

`SelfTest` traite déjà un taux nul comme inutilisable (`nominalSampleRate > 0 ? … : 48_000`, `SelfTest.swift:105`). Le moteur de production ne le fait pas.

**Scénario** : l’agrégat répond `noErr` avec un taux nominal 0 (ou `NaN`) au moment du montage. À vérifier sur le matériel : je n’ai pas la preuve que le Studio Display le fait. Le trou est le même que celui que le contrôle de format est censé fermer.

**Recommandation** : refuser le démarrage si le taux n’est pas fini ou hors d’une plage réelle (par exemple 44,1–192 kHz), avec le même démontage que pour un format refusé.

### 2. Deux lancements dans la même fenêtre passent tous les deux le contrôle d’instance

- **Gravité** : moyenne
- **Catégorie** : fiabilité
- **Emplacement** : `StudioEQ/App/StudioEQApp.swift:43-57`

Le contrôle lit `NSRunningApplication` une fois, puis construit `AppModel` :

```50:57:StudioEQ/App/StudioEQApp.swift
    static let model: AppModel? = {
        if isCommandLineMode || isTesting { return nil }
        if otherInstanceRunning {
            DispatchQueue.main.async { NSApp.terminate(nil) }
            return nil
        }
        return AppModel()
    }()
```

Aucune des deux processus n’est encore dans la liste pendant que l’autre fait le test. Chacune crée un tap qui exclut seulement son propre PID (`TapEngine.swift:62-64`). Le commentaire du code décrit le résultat : silence ou boucle, parce que chaque tap entend la sortie de l’autre.

Le cas « une seconde copie alors que la première tourne déjà » est couvert et décrit dans le README. La course ne l’est pas.

**Scénario** : deux `open` presque simultanés au login, ou un double lancement pendant que la première instance n’est pas encore enregistrée comme application en cours.

**Recommandation** : un verrou exclusif (`flock` sur un fichier du conteneur) pris avant `AppModel()`, relâché à la fin du processus. Le garder inactif quand `XCTestCase` est chargé, pour la raison déjà documentée.

### 3. `make publish` peut sauter la notarisation si `SKIP_NOTARIZATION` est dans l’environnement

- **Gravité** : moyenne
- **Catégorie** : publication
- **Emplacement** : `Makefile:91-93`, `Makefile:98-105`, `scripts/release.sh:80-81`

`make dmg` pose `SKIP_NOTARIZATION=1` sur une seule commande. `make release` et `make publish` ne le remettent pas à 0. Make transmet l’environnement au script, et le script honore la variable :

```80:81:scripts/release.sh
if [[ ${SKIP_NOTARIZATION:-0} == 1 ]]; then
  echo "\nSKIP_NOTARIZATION=1: $DMG is signed but NOT notarized (Gatekeeper will refuse it on another Mac)."
```

Dans cette branche, il n’y a ni `notarytool`, ni agrafage, ni `spctl`. `make publish` enchaîne quand même l’étiquette et `gh release create`.

**Scénario** : un `export SKIP_NOTARIZATION=1` laissé après un essai de DMG, puis `make publish` sur un arbre propre. Le DMG signé Developer ID part sur GitHub sans ticket de notarisation. Gatekeeper le refuse sur un autre Mac. Les autres contrôles (autorité, horodatage, Hardened Runtime, sandbox seul, absence de `--selftest`) restent exécutés.

**Recommandation** : dans les recettes `release` et `publish`, fixer `SKIP_NOTARIZATION=0`, ou refuser cette variable dans `release.sh` sauf cible `dmg`.

### 4. L’étiquette Git est poussée avant que la release GitHub existe

- **Gravité** : moyenne
- **Catégorie** : publication
- **Emplacement** : `Makefile:106-108`

```106:108:Makefile
	@git tag -a $(TAG) -m "Studio EQ $(VERSION)" && git push --quiet origin $(TAG)
	@gh release create $(TAG) $(DMG) $(DMG).sha256 --verify-tag --title "Studio EQ $(VERSION)" --generate-notes
	@echo "Published $$(gh release view $(TAG) --json url -q .url)"
```

`gh` absent, un jeton expiré, ou un échec d’envoi du DMG laissent `vX.Y.Z` sur `origin`. L’essai suivant s’arrête au contrôle `git ls-remote` (« tag already exists ») alors que la page Releases n’a pas le DMG. Le document dit qu’un échec des étapes 1 à 4 ne laisse rien sur GitHub ; l’étape 5 n’est pas atomique avec l’étape 6.

**Scénario** : notarisation réussie, `git push` de l’étiquette réussi, `gh release create` qui échoue.

**Recommandation** : créer la release, et ne pousser l’étiquette qu’ensuite ; ou supprimer l’étiquette distante si `gh release create` échoue.

### 5. Les tests ne voient ni les décisions de `AppModel`, ni l’identifiant mesuré sur l’écran

- **Gravité** : moyenne
- **Catégorie** : tests
- **Emplacement** : `StudioEQTests/` (deux fichiers, 18 tests), `StudioEQTests/MatcherTests.swift:20-22`

Les 18 tests couvrent bien le DSP (gains, pôles, préampli fixe, sens des curseurs, limiteur, `NaN`, 8 canaux, entrelacé et non entrelacé) et les leurres du matcher (Mac, AirPods, eqMac, micro, adaptateur USB-C, LG, AirPlay, agrégat). Rien n’appelle `reconcile`, `CaptureCheck`, ni le cycle permission → montage → `failedConfiguration`.

La fixture de reconnaissance est `Studio Display:05AC:1114`. L’écran mesuré, dans `docs/selftest-studio-display-48k.txt` et `docs/ARCHITECTURE.md`, est `Studio Display Audio Control:05AC:1114`. Le matcher actuel accepte les deux via `contains("studio display")`. Un resserrement qui exigerait la chaîne de test passerait au vert et ignorerait l’appareil réel.

`scripts/scenario.sh` n’a que `set -u`. Les attentes lisent le journal unifié après un `sleep` fixe. Un `audioctl default` sans effet peut laisser l’état précédent et produire un faux succès quand l’état attendu est celui d’avant (retour vers la cible, déjà « active »).

**Scénario** : une régression de `AppModel` qui ne revérifie plus la permission avant un changement de fréquence, ou qui reconnaît seulement le model UID du test. Aucun test unitaire ne devient rouge.

**Recommandation** : extraire les transitions (permission, configuration en échec, veille, génération de la tâche) dans une fonction pure testée sans HAL. Ajouter une fixture avec `Studio Display Audio Control:05AC:1114` et le transport Thunderbolt. Pour le scénario, échouer si `audioctl` ne change pas la sortie lue par `out()`.

### 6. L’architecture décrit encore un préampli automatique, et les chiffres ne collent plus au code

- **Gravité** : moyenne
- **Catégorie** : documentation
- **Emplacement** : `docs/ARCHITECTURE.md:4`, `docs/ARCHITECTURE.md:15`, `docs/DSP.md:45-51`, `docs/selftest-studio-display-48k.txt:7`

`EQDesign.preampDB` vaut exactement −3 (`headroomDB = 3.0`). `docs/DSP.md` le dit. La table d’architecture dit encore « préampli automatique » pour `EQDesign.swift`.

Le même fichier d’architecture annonce environ 750 lignes de code applicatif, 380 pour `SelfTest.swift` et 220 de tests. Le dépôt contient 1 429 lignes Swift hors `SelfTest` (environ 1 080 hors commentaires et lignes vides), 410 pour `SelfTest.swift`, 323 pour les tests.

Le rapport 48 kHz versionné affiche `preamp -3.01 dB`. Le format actuel `%+.2f` de −3,0 écrit `-3.00`. La colonne « Mesure » de `docs/DSP.md` (par exemple −3,05 dB à 300 Hz) n’est ni la colonne brute du fichier (−2,84 dB), ni cette colonne après retrait du décalage de +0,29 dB (−3,13 dB). `docs/TESTS.md` explique le décalage de référence ; le tableau DSP n’est pas recalculable depuis le rapport joint.

**Scénario** : un contributeur « rétablit » le préampli automatique décrit comme le comportement actuel, ou juge la courbe mesurée à partir d’un tableau qui ne correspond pas au fichier.

**Recommandation** : aligner la phrase de l’architecture sur le préampli fixe, corriger les volumes, et régénérer le tableau DSP depuis un auto-test de cette révision, en disant si le décalage global a été retiré.

### 7. La sonde de permission écrit des motifs Float32 sans lire le format du périphérique

- **Gravité** : basse
- **Catégorie** : fiabilité
- **Emplacement** : `StudioEQ/Audio/CaptureCheck.swift:122-135`

Le tap de production refuse un format non Float32. La sonde, elle, écrit `±1e-6` en interprétant chaque tampon de sortie comme du Float32 entrelacé, sur le périphérique lui-même, avant ce contrôle. L’en-tête Core Audio indique que le HAL mélange les IOProc après avoir fourni à chacune un tampon mis à zéro : sur un flux Float32, le motif reste à −120 dBFS et le son des autres applications continue. C’est conforme aux essais déjà rapportés sur le Studio Display.

**Scénario** : un flux d’E/S entier (validation avec `-TargetDeviceUID`, ou un futur écran). Les mêmes bits deviennent de grands échantillons. La sonde peut rester active jusqu’à 120 s tant que le dialogue système n’a pas répondu (`timeout` par défaut, `CaptureCheck.swift:29`).

**Recommandation** : lire le format de sortie avant `AudioDeviceStart` et abandonner la vérification (échec, moteur non monté) si ce n’est pas du PCM Float32.

### 8. Une vérification de permission en échec ne se relance pas quand la configuration change

- **Gravité** : basse
- **Catégorie** : fiabilité
- **Emplacement** : `StudioEQ/App/AppModel.swift:180-193`

Un échec de `TapEngine` est retenu dans `failedConfiguration` et oublié dès que l’UID, le taux ou le nombre de canaux change. Un échec de `CaptureCheck` (délai, sortie muette pendant 2 s) est stocké dans `permission = .failed` et relu avant cette logique :

```188:193:StudioEQ/App/AppModel.swift
        switch permission {
        case .granted: break
        case .denied: status = .permissionDenied; return
        case .failed(let message): status = .error(message); return
        case .checking: status = .checkingPermission; return
```

**Scénario** : la sonde lève « the output stopped during the permission check » pendant un à-coup de 2 s, l’écran reste la sortie, puis la fréquence change. Le menu reste sur l’erreur. « Réessayer », ou un détour par une autre sortie, débloque. Le son n’est pas coupé : le moteur n’a pas démarré.

**Recommandation** : traiter `.failed` comme `failedConfiguration`, ou le remettre à `.unknown` quand la configuration change.

### 9. Le réveil matériel qui ne change ni le taux, ni la topologie des flux, ne reconstruit pas le moteur

- **Gravité** : basse
- **Catégorie** : cycle de vie
- **Emplacement** : `StudioEQ/Audio/DeviceMonitor.swift:43-47`

Les écouteurs de périphérique sont le taux nominal, `DeviceIsAlive` et la configuration de flux en sortie (nombre de canaux). `kAudioDevicePropertyDeviceHasChanged` et le format de flux (Float32 ou entier, à taux et nombre de canaux identiques) ne sont pas écoutés. Apple documente `DeviceHasChanged` justement pour les changements qui n’ont pas d’autre notification. Tant que `isAlive` et le taux nominal restent égaux, `AppModel` considère le moteur à jour (`AppModel.swift:172-176`).

**Scénario** : à vérifier. Un changement de format physique dans Configuration audio MIDI, sans changer 48 kHz ni les 8 canaux. Si le tap reste Float32, l’égaliseur continue correctement. S’il devient entier, l’IOProc lit ces mots comme des flottants pendant que l’original est coupé.

**Recommandation** : écouter `DeviceHasChanged` (et le format du flux de sortie) avec la même coalescence de 150 ms, et refuser un tap qui n’est plus Float32.

## Ce qui a été vérifié et jugé correct

**Sécurité et publication.** Un seul droit, `com.apple.security.app-sandbox` (`StudioEQ.entitlements`). Hardened Runtime activé, `CODE_SIGN_INJECT_BASE_ENTITLEMENTS` désactivé en Release. Aucun `URLSession` ni autre client réseau dans le code de l’app. `NSAudioCaptureUsageDescription` existe en anglais et en français et correspond au comportement. Les outils `--selftest`, `-TargetDeviceUID` et `-SimulateEngineFailure` sont sous `#if VALIDATION` ; `project.yml` ne pose cette condition qu’en Debug. `scripts/release.sh` est en `set -euo pipefail`, vérifie l’autorité Developer ID, l’horodatage, le runtime, l’absence de `get-task-allow`, un seul `<key>`, la version, puis notarisation, agrafe et `spctl`. La CI n’a que `contents: read`, épingle `actions/checkout` par empreinte, et ne reçoit pas de secret. `Config/Local.xcconfig` est ignoré et n’est pas versionné. Les rapports d’auto-test écrivent `<série>` à la place du numéro de série. Les UID journalisés passent par `privacy: .private(mask: .hash)`. Le chemin de production n’écrit pas d’audio ; les réglages sont un JSON dans `UserDefaults`, relu via `clamped`.

**Chemin audio.** Le tap est privé, par périphérique et par flux 0, `mutedWhenTapped`, et le montage est refusé si l’objet processus est inconnu. Échec partiel : `TapEngine.init` démonte tap et agrégat. L’IOProc est créée dans `TapEngine.start`, hors acteur. Les tampons de `EQProcessor` sont alloués dans `init`. Les gains passent par `Atomic` relâché. `AudioDeviceStop` précède la destruction de l’IOProc. `CaptureCheck` utilise un tap `unmuted` limité au processus lui-même, et une annulation ignore le résultat grâce au numéro de génération. La veille pose `isAsleep` et bloque tout montage jusqu’au réveil. Quitter passe par `shutdown()` avant `terminate`. Le débranchement réel, la veille et les AirPods restent les essais « à faire » déjà listés dans `docs/TESTS.md` ; le code de ces chemins est présent, je ne les ai pas rejoués.

**DSP.** Formules RBJ habituelles, préampli fixe −3 dB, limiteur lié entre canaux à −0,2 dBFS (`0,977`), identité exacte à gain nul, remise à zéro de l’état non fini. Les tests de pôles couvrent ±12 dB par pas de 0,5 dB de 44,1 à 192 kHz.

**Contribution.** Signature ad hoc par défaut, projet généré par XcodeGen, `make test` ne demande pas de compte développeur. Cible `arm64`, macOS 15. Je n’ai pas exécuté la compilation.

**Tenue pour une 1.1.** Un autre écran se branche dans `StudioDisplayMatcher` et `isTarget` sans toucher au moteur. En revanche, `EQProcessor.filter` déroule trois biquads à la main : une quatrième bande ne suit pas `BandDesign.all`. `Preferences.settings` rejette tout le JSON si le décodage échoue ; un champ obligatoire ajouté à `EQSettings` ramènerait graves, médiums et aigus aux valeurs d’usine.
