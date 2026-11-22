## Résumé

La publication n’est pas bloquée par un secret, un droit de bac à sable en trop, ni une fuite du son capté. Elle l’est par trois choses à corriger avant le DMG : le binaire Release actuel est signé « Apple Development » et porte `get-task-allow` (le notaire le refuse) ; les outils de test qui coupent une sortie arbitraire sont dans l’app de production ; deux chemins de `reconcile()` laissent l’égalisation dans un état faux, dont un peut recréer le silence total que `CaptureCheck` devait empêcher. Le numéro de série du Studio Display et le chemin `~/...` sont déjà dans `docs/`.

## Constats

### 1. Autorisation mémorisée : un remontage peut couper le son

- **Gravité** : haute
- **Catégorie** : fiabilité
- **Emplacement** : `StudioEQ/App/AppModel.swift:141-143` et `154-172` ; affirmation contestée dans `README.md:69-71`

**Constat.** `CaptureCheck` ne tourne que lorsque `permission == .unknown`. Un résultat `.granted` reste vrai jusqu’à la fin du processus. Quitter le Studio Display ne l’efface pas (seuls `.denied` et `.failed` le sont). Changement de fréquence, interrupteur, veille puis réveil : le moteur est détruit puis recréé sans nouvelle vérification.

```141:143:StudioEQ/App/AppModel.swift
            if permission == .denied { permission = .unknown }
            if case .failed = permission { permission = .unknown }
            failedConfiguration = nil
```

```154:156:StudioEQ/App/AppModel.swift
        switch permission {
        case .granted: break
        case .denied: status = .permissionDenied; return
```

Le README dit que le refus est détecté au prochain montage du moteur, sans couper le son. Ce n’est pas ce que fait le code. `docs/TESTS.md:70` parle du prochain démarrage de l’app, ce qui, lui, correspond au code (`permission` repart de `.unknown`). Les deux textes ne disent pas la même chose, et le README est faux.

**Scénario.** L’autorisation a déjà été accordée pendant cette session. L’utilisateur la retire dans Réglages Système, puis change la fréquence, bascule vers les haut-parleurs du Mac et revient, ou referme le portable. Au premier lancement sans droit, le comportement mesuré est : le tap coupe l’original et ne livre que des zéros. Rien dans le code n’évite cela au second montage.

**À vérifier** sur la machine, sans que je l’aie exécuté : macOS réévalue-t-il le TCC à la création d’un nouveau tap dans un processus déjà autorisé ? Si oui, le scénario ci-dessus est un silence total. Si le système cache l’accord pour tout le processus, il n’y a pas de silence, mais le refus n’est toujours pas détecté avant de quitter l’app.

**Recommandation.** Relancer `CaptureCheck` à chaque montage, pas seulement au premier. Ne passer en `.granted` qu’après ce contrôle. Aligner le README sur ce comportement.

### 2. Une fréquence déjà en échec n’est plus réessayée, et le menu peut rester « Actif »

- **Gravité** : haute
- **Catégorie** : fiabilité
- **Emplacement** : `StudioEQ/App/AppModel.swift:146-151` et `174-188`

**Constat.** `failedConfiguration` est posé dans le `catch`, et n’est effacé qu’en quittant la sortie cible ou par « Réessayer ». Un démarrage réussi ne le remet pas à `nil`. Le retour anticipé est après `stopEngine()`, et il ne réécrit pas `status`. Le commentaire dit de conserver l’état d’erreur, mais rien ne garantit que l’état courant est encore l’erreur.

```174:188:StudioEQ/App/AppModel.swift
        let configuration = "\(output.uid)@\(output.nominalSampleRate)"
        if configuration == failedConfiguration { return }  // keep the error status shown
        do {
            // ...
            let e = try TapEngine(device: output, parameters: parameters)
            engine = e
            status = .active
        } catch {
            failedConfiguration = configuration
            status = .error(String(describing: error))
        }
```

**Scénario.** Le montage échoue une fois à 48 kHz (écran pas prêt au réveil, échec transitoire de l’agrégat). L’utilisateur ou une app passe à 44,1 kHz : ça démarre, le menu affiche « Actif », et `failedConfiguration` vaut encore `uid@48000`. Le retour à 48 kHz arrête le moteur puis sort de la fonction. Le son d’origine revient, non traité, et le menu reste « Actif ». Le bouton « Réessayer » n’existe que pour `.error`. Ça reste ainsi jusqu’à ce qu’on coupe l’égalisation ou qu’on change de sortie.

**Recommandation.** Effacer `failedConfiguration` dès qu’un montage réussit. Au retour anticipé, forcer `status = .error(...)`. Mieux : n’interdire qu’une nouvelle tentative immédiate sur la même configuration, et réarmer dès que la fréquence est réellement sortie puis revenue.

### 3. La configuration signée ne peut pas être notarisée telle quelle

- **Gravité** : haute
- **Catégorie** : publication
- **Emplacement** : `project.yml:12-15` ; droit injecté dans `build/DerivedData/Build/Intermediates.noindex/StudioEQ.build/Release/StudioEQ.build/DerivedSources/Entitlements.plist:7` ; absent de `StudioEQ/StudioEQ.entitlements`

**Constat.** Toutes les configurations signent en « Apple Development », équipe `<équipe>`, style manuel. Le bac à sable source ne contient que `com.apple.security.app-sandbox`. Le plist d’entitlements produit pour Release ajoute `com.apple.security.get-task-allow`. C’est l’injection par défaut de Xcode pour un certificat de développement. Le service de notarisation refuse ce droit. Hardened Runtime est bien activé, sans exception (`disable-library-validation`, `allow-dyld-environment-variables`, etc.). Aucun certificat, profil ni mot de passe n’est dans le dépôt. L’identifiant d’équipe n’est pas un secret : il sera de toute façon dans la signature. Il ne doit simplement pas rester la seule identité, y compris pour Release.

**Scénario.** L’action GitHub reprend `project.yml` sans le redéfinir. Le DMG est signé avec le certificat de développement, ou avec Developer ID mais en réutilisant un entitlements qui contient encore `get-task-allow`. La notarisation échoue, ou un binaire débogable est publié.

**Recommandation.** Release : identité `Developer ID Application`, `CODE_SIGN_INJECT_BASE_ENTITLEMENTS = NO`, horodatage laissé par défaut (ne pas passer `--timestamp=none`). Certificat, mot de passe et clé `notarytool` uniquement dans les secrets du dépôt. Après signature, refuser le produit si `codesign -d --entitlements :-` montre `get-task-allow`. Conserver le bac à sable sans droit supplémentaire et Hardened Runtime sans exception. Ne pas faire tourner `scripts/install.sh` sur le runner : il copie dans `/Applications` et lance l’app. Ajouter un fichier `LICENSE` GPL-2.0 : il n’y en a pas, GitHub ne détectera pas la licence.

### 4. Les modes de test qui coupent le son sont dans l’app publiée

- **Gravité** : moyenne
- **Catégorie** : sécurité
- **Emplacement** : `StudioEQ/App/StudioEQApp.swift:6-9`, `StudioEQ/App/SelfTest.swift:22-47` et `185-218`, `StudioEQ/App/AppModel.swift:113-118` et `215-220`

**Constat.** `--selftest`, `--ab-test`, `--permission-probe` et `--list-devices` sont compilés dans la cible application, sans `#if DEBUG`. Ils lancent `/usr/bin/afplay` et le vrai `TapEngine` (`mutedWhenTapped`). `--device` vise n’importe quel UID, pourvu qu’il soit la sortie par défaut. `-TargetDeviceUID` et `-SimulateEngineFailure` sont lus par `UserDefaults` : le domaine des arguments s’applique à l’app normale, pas seulement au mode sans interface. `scripts/scenario.sh:12` s’en sert. Les arguments ne sont pas écrits sur disque ; une clé du même nom dans le conteneur sandbox, elle, le serait.

**Scénario.** `open -n /Applications/StudioEQ.app --args -TargetDeviceUID BuiltInSpeakerDevice` fait traiter et couper les haut-parleurs du Mac par l’app de barre des menus, aussi longtemps qu’elle reste lancée. `--ab-test` alterne en plus des silences volontaires de 2 s. Ce n’est pas une attaque distante : il faut pouvoir lancer l’app. C’est un interrupteur caché dans le binaire notarisé, qui retire la garantie « uniquement le Studio Display ».

**Recommandation.** Sortir `SelfTest.swift` et ces clés de la configuration Release (cible ou outil séparé). L’app publiée ne doit pas honorer `-TargetDeviceUID` ni `-SimulateEngineFailure`.

### 5. Numéro de série et chemin personnel déjà publiables

- **Gravité** : moyenne
- **Catégorie** : sécurité
- **Emplacement** : `StudioEQ/App/AppModel.swift:124` et `183`, `StudioEQ/Audio/TapEngine.swift:109`, `docs/selftest-studio-display-48k.txt:2` et `:24` (identique dans le rapport 44,1 kHz)

**Constat.** L’UID réel est `AppleUSBAudioEngine:Apple Inc.:Studio Display:<série>:8,9`. Il est journalisé avec `privacy: .public`, donc non caviardé dans le journal unifié, à chaque changement d’état et à chaque montage. `OutputDevice.description` ajoute le nom affiché. Le son, lui, n’est ni journalisé ni écrit : les seuls fichiers audio sont les WAV temporaires de l’auto-test.

Les deux comptes rendus dans `docs/` contiennent ce numéro de série et `report: ~/Library/Containers/com.jcbaptiste.StudioEQ/Data/tmp/StudioEQ-selftest.txt`. `build/` et `dist/` sont dans `.gitignore` ; ces textes, non.

**Scénario.** Le dépôt public et un `log show --predicate 'subsystem == "com.jcbaptiste.StudioEQ"'` (la commande est dans `docs/TESTS.md`) exposent l’identifiant matériel de l’écran et le nom du compte.

**Recommandation.** Passer ces champs en `.private`, ou ne journaliser que le modèle et la fréquence. Remplacer dans `docs/` le numéro de série par `<série>` et supprimer la ligne `report:`.

### 6. `install.sh` ignore un échec de compilation ; `scenario.sh` ne restaure pas la sortie

- **Gravité** : moyenne
- **Catégorie** : qualité
- **Emplacement** : `scripts/install.sh:3-13`, `scripts/scenario.sh:12-32`, `scripts/audioctl.swift:46-54`

**Constat.** `set -euo pipefail` est annulé par `xcodebuild … | grep … || true`. Le script enchaîne sur l’app déjà présente dans DerivedData, la revérifie avec `codesign`, remplace `/Applications/StudioEQ.app` et la lance. Pas de `sudo`. Les chemins supprimés sont fixes (`dist/StudioEQ.app`, `/Applications/StudioEQ.app`). Les arguments de `afplay` et de `open` sont entre guillemets : pas d’injection shell.

`scenario.sh` n’a pas de `trap`. Il tue `StudioEQ`, lance l’app avec `-TargetDeviceUID`, et `audioctl fake` publie un agrégat non privé (`kAudioAggregateDeviceIsPrivateKey` absent) comme sortie système. Un Ctrl-C laisse l’app de test en marche sur les haut-parleurs du Mac, et la sortie par défaut sur un agrégat qui meurt avec `audioctl`.

**Scénario.** Une erreur Swift pendant `scripts/install.sh` réinstalle l’ancien Release et affiche « Installed ». Un scénario interrompu laisse la sortie système sur `test.fake.output` jusqu’à ce que le processus meure, puis macOS rebascule tout seul.

**Recommandation.** Faire échouer `install.sh` sur le code de sortie de `xcodebuild`, avant `codesign`. Dans `scenario.sh`, un `trap EXIT` qui tue l’app lancée pour le test et rappelle `audioctl default BuiltInSpeakerDevice`. Marquer l’agrégat de test privé.

### 7. Une réconciliation déjà programmée peut relancer le moteur après « Quitter »

- **Gravité** : basse
- **Catégorie** : cycle de vie
- **Emplacement** : `StudioEQ/Audio/DeviceMonitor.swift:56-69`, `StudioEQ/App/MenuContent.swift:36`

**Constat.** `stop()` retire les écouteurs HAL et ne fait pas `pending?.cancel()`. Le bouton Quitter appelle `shutdown()` puis `terminate`. `shutdown()` arrête le moteur et le moniteur. L’item déjà déposé sur la file principale (délai 150 ms) appelle encore `reconcile()`.

**Scénario.** Un changement de périphérique est coalescé, l’utilisateur quitte dans la foulée. Jusqu’à 150 ms plus tard, `reconcile()` peut recréer le tap alors que l’app s’en va. La fenêtre est courte ; à la mort du processus, macOS retire le tap privé. Les observateurs de veille ne sont pas retirés non plus (`AppModel.swift:81-89`) : sans effet pratique, le modèle vit autant que le processus.

**Recommandation.** Annuler `pending` dans `stop()`, et ignorer `onChange` après l’arrêt.

## Ce qui a été vérifié et jugé correct

Bac à sable limité au droit `app-sandbox`, sans réseau, sans groupe d’apps, sans exception Hardened Runtime dans la source. `NSAudioCaptureUsageDescription` correspond au comportement. Aucun `URLSession`, aucun envoi. Le chemin de production n’écrit pas d’audio ; les réglages passent par `UserDefaults` dans le conteneur, et un JSON illisible retombe sur les valeurs par défaut, après `clamped`.

Le tap exclut le processus, refuse de démarrer si l’objet processus est introuvable, et ne coupe l’original que pendant qu’il est lu. L’échec du montage passe par `teardown()` (stop, destruction de l’IOProc, de l’agrégat, puis du tap). L’ordre des `defer` de `CaptureCheck` est le même. Pas de second `CaptureCheck` concurrent : tant que l’état est `.checking`, un nouveau contrôle n’est pas lancé, et le résultat est appliqué à la sortie courante, pas à l’appareil capturé au début. Je n’ai pas trouvé de double lecture dans le chemin normal ; le test A/B décrit dans `docs/TESTS.md` reste la preuve d’écoute, je ne l’ai pas refait.

L’IOProc de production est une fermeture non isolée qui ne capture que `EQProcessor` et l’index. `process` ne journalise pas, ne prend pas de verrou et n’alloue pas de tampon. Les gains passent par `Atomic<UInt64>` relâchés ; un mélange transitoire de bandes est assumé par le glissement. `AudioDeviceStop` est synchrone et précède la libération du processeur : pas d’usage du tampon après démontage, sous le contrat habituel de Core Audio. Les coefficients ne sont recalculés que pendant le glissement ; `pow` / `sin` / `cos` restent du temps de calcul, pas une allocation. Les pôles sont bornés par les tests sur ±12 dB et 44,1–192 kHz. Le préampli est calculé à 48 kHz même à une autre fréquence ; les mesures à 44,1 kHz (écart de forme 0,07 dB) ne montrent pas de dépassement utile. Le préampli fréquentiel ne borne pas strictement la crête temporelle d’un IIR ; avec −3 dB de marge par défaut, je n’en fais pas un défaut.

`StudioDisplayMatcher` ne regarde pas le nom affiché. Le modèle réel relevé dans le compte rendu (`Studio Display Audio Control:05AC:1114`, transport USB, 8 canaux) passe les critères ; le micro sans canal de sortie, AirPlay, l’agrégat et eqMac sont rejetés par les tests. L’index « le tap est le dernier flux d’entrée » n’est pas revérifié par UID. L’auto-test sur cet écran a réussi ; je ne peux pas dire depuis le code combien de flux d’entrée l’agrégat avait. La structure `IOProcStreamUsage` (pointeur, puis `UInt32`, puis le tableau) est cohérente sur arm64, et ce chemin n’est pris que s’il y a plus d’un flux.

Les tests encore ouverts dans `docs/TESTS.md` (câble réel, AirPods, veille, ouverture de session, lecture d’une heure) ne sont pas des défauts nouveaux. Je n’ai pas lancé l’app, les auto-tests, ni de compilation.
