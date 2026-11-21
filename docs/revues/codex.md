**1. Résumé**

**Publication du DMG à différer** : un redémarrage peut réutiliser une autorisation TCC périmée et provoquer le silence que la garde devait empêcher.
La surface d’attaque est réduite ; aucun chemin d’exfiltration audio identifié dans le fonctionnement normal.
Le préampli ne garantit pas l’absence d’écrêtage annoncée.
La signature de distribution, la licence et l’anonymisation des données doivent être préparées avant publication.
Revue statique uniquement : aucun fichier modifié, aucun build ni test audio exécuté ; `docs/revues/` non consulté.

**2. Constats, par gravité décroissante**

**A. Une autorisation TCC précédemment accordée reste valable indéfiniment dans le modèle**

- **Gravité : haute — Catégorie : fiabilité**
- **Emplacement :** `StudioEQ/App/AppModel.swift:135`, `:141`, `:154`, `:191`.
- **Constat et preuve :** `stopEngine()` ne réinitialise pas `permission`. Lorsqu’on quitte la sortie cible, seules les valeurs `.denied` et `.failed` sont réarmées ; `.granted` reste inchangée. Le prochain montage franchit donc directement `case .granted: break`, sans `CaptureCheck`.
- **Scénario concret :** autoriser la capture, activer l’EQ, désactiver l’EQ, retirer l’autorisation dans Réglages Système, puis réactiver l’EQ. Le moteur muet démarre sans nouvelle vérification. Selon le comportement mesuré et documenté par le projet, il coupe alors l’original et reçoit des zéros. La même faille existe après une bascule vers une autre sortie puis un retour.
- **Recommandation :** invalider l’autorisation vérifiée dès l’arrêt du moteur et revérifier avant chaque nouveau montage susceptible de couper l’original. Ajouter un test du modèle avec moteur et vérificateur simulés.

Ce constat **conteste explicitement** l’affirmation du README selon laquelle le refus sera détecté au prochain montage. Il ne concerne pas la limitation acceptée de révocation pendant une E/S déjà active.

**B. La vérification asynchrone survit au contexte qui l’a déclenchée**

- **Gravité : moyenne — Catégorie : cycle de vie**
- **Emplacement :** `StudioEQ/App/AppModel.swift:84`, `:108`, `:162` ; `StudioEQ/Audio/CaptureCheck.swift:60`, `:69`, `:72`.
- **Constat et preuve :** la `Task` n’est ni conservée ni annulée. Désactivation, changement de sortie et veille arrêtent uniquement `engine`. La sonde conserve ses propres IOProc jusqu’à son résultat ou son délai de 120 secondes, puis écrit inconditionnellement `self.permission = result`.
- **Scénario concret :** débrancher l’écran pendant la vérification, puis le rebrancher. Si l’ancien périphérique ne fournit plus de cycles, la sonde attend son délai maximal ; son échec devient ensuite l’état de permission du périphérique revenu. Pendant cette attente, l’EQ reste bloquée en vérification. Une désactivation laisse également la source de test ouverte jusqu’à la fin de la sonde.
- **Recommandation :** conserver une tâche annulable, associer son résultat à une génération de configuration, et annuler/invalider lors des changements pertinents. Ajouter un état de veille empêchant toute réactivation avant le réveil. Les `defer` existants permettent déjà le nettoyage lors d’une annulation.

La durée exacte et le comportement HAL après débranchement restent **à vérifier sur matériel** ; l’absence d’annulation et l’acceptation des résultats obsolètes sont établies par le code.

**C. La protection annoncée contre l’écrêtage n’est pas garantie**

- **Gravité : moyenne — Catégorie : DSP**
- **Emplacement :** `StudioEQ/DSP/EQDesign.swift:110` ; `StudioEQ/DSP/EQProcessor.swift:15`, `:86`, `:116` ; `docs/DSP.md`, section « Préamplificateur automatique ».
- **Constat et preuve :** borner la réponse fréquentielle à 0 dB ne borne pas les crêtes temporelles. La sortie écrit directement `Float(y)`, sans protection supplémentaire. Un calcul numérique indépendant des formules présentes, à 48 kHz et avec les réglages par défaut, donne une somme des valeurs absolues de la réponse impulsionnelle d’environ **1,465**. Une entrée bornée à ±0,9, construite par les signes de cette réponse inversée sur 8 192 échantillons, produit ainsi une crête d’environ **1,319**, supérieure à pleine échelle. Aucun code du projet n’a été exécuté pour ce calcul.
  
  Par ailleurs, les trois gains sont publiés **avant** le calcul puis la publication du préampli. Le thread audio peut donc appliquer une augmentation avec l’ancienne atténuation ; les atomiques évitent la course mémoire, mais ne garantissent pas un ensemble cohérent.
- **Scénario concret :** un signal riche en transitoires peut dépasser ±1 après filtrage alors que son entrée restait bornée. Lors d’un changement de réglage, un entrelacement défavorable des threads peut aussi créer une amplification temporaire non compensée.
- **Recommandation :** corriger la promesse « ne peut pas saturer » et choisir une protection explicite selon le comportement recherché : marge conservatrice ou limiteur de crête. Publier gains et préampli comme une configuration cohérente ; vérifier également la marge pendant les transitions.

Les tests actuels de sinus et de réponse fréquentielle ne couvrent pas cette propriété.

**D. Les journaux et les rapports exposent des identifiants personnels**

- **Gravité : moyenne — Catégorie : sécurité**
- **Emplacement :** `StudioEQ/App/AppModel.swift:124`, `:183` ; `StudioEQ/Audio/TapEngine.swift:109` ; `StudioEQ/Audio/OutputDevice.swift:29` ; `docs/selftest-studio-display-48k.txt:2`, `:24` ; mêmes données dans le rapport 44,1 kHz.
- **Constat et preuve :** les UID sont journalisés avec `privacy: .public`. `OutputDevice.description` ajoute le nom et les identifiants matériels. Les rapports destinés au dépôt contiennent un identifiant matériel stable, le nom du compte local dans un chemin absolu et l’inventaire de plusieurs périphériques logiciels.
- **Scénario concret :** la publication GitHub expose durablement ces informations ; un diagnostic partagé par un utilisateur peut aussi révéler les identifiants de ses sorties, même lorsqu’elles ne sont pas ciblées par l’EQ.
- **Recommandation :** anonymiser les deux rapports avant le premier commit public et rendre privés les noms/UID dans les journaux. Préférer des informations techniques non identifiantes pour les messages publics.

L’identifiant d’équipe et le bundle ID sont des métadonnées publiques, **pas des secrets de signature**. Aucun certificat privé, mot de passe ou jeton n’a été identifié dans les fichiers examinés.

**E. Le script peut installer une ancienne build après un échec de compilation**

- **Gravité : moyenne — Catégorie : fiabilité**
- **Emplacement :** `scripts/install.sh:6`.
- **Constat et preuve :** `xcodebuild … | grep … || true` masque l’échec de toute la chaîne malgré `set -euo pipefail`. `codesign --verify` valide ensuite le bundle présent sur disque, sans prouver qu’il vient de la compilation demandée.
- **Scénario concret :** une ancienne Release signée existe ; une modification introduit une erreur de compilation. Le script poursuit, vérifie l’ancienne app, remplace celle de `/Applications`, la lance et annonce une installation réussie.
- **Recommandation :** propager le statut de `xcodebuild`, conserver le journal complet et ne remplacer l’application qu’après succès explicite. Préparer une copie validée avant de supprimer la version installée.

Les suppressions observées utilisent des chemins fixes ; aucune injection shell par nom de périphérique n’a été trouvée.

**F. La configuration fournie ne prépare pas encore une distribution Developer ID notarisée**

- **Gravité : moyenne — Catégorie : publication**
- **Emplacement :** `project.yml:12`, `:14`, `:15` ; `scripts/install.sh:9`.
- **Constat et preuve :** l’identité commune à toutes les configurations est `Apple Development`. Aucun workflow GitHub Actions ni chaîne de fabrication du DMG n’est présent dans l’arborescence examinée. `codesign --verify --strict` contrôle l’intégrité, pas l’éligibilité à une distribution notarisée.
- **Scénario concret :** réutiliser ce montage tel quel en CI produit une app de développement, ou échoue faute d’identité installée, sans délivrer le DMG promis.
- **Recommandation :**
  - Séparer développement et distribution ; injecter l’équipe et utiliser **Developer ID Application** pour la distribution.
  - Conserver Hardened Runtime et le sandbox ; imposer l’horodatage sécurisé et vérifier sur **l’artefact final** que `com.apple.security.get-task-allow` est absent ou faux. Ce sont des exigences Apple. [Documentation Apple](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)
  - Importer certificat et clé privée depuis les secrets CI dans un trousseau temporaire ; protéger les identifiants de notarisation et nettoyer ces ressources même en cas d’échec. [Documentation GitHub](https://docs.github.com/en/actions/how-tos/deploy/deploy-to-third-party-platforms/sign-xcode-applications)
  - Signer l’app puis le DMG, soumettre avec `notarytool`, attendre le statut accepté, agrafer le ticket et vérifier signature, ticket et Gatekeeper avant publication.
  - Exclure les outils de validation de la variante distribuée, ou les isoler dans une cible dédiée : `--permission-probe` et `--ab-test` démarrent directement `TapEngine` sans garde TCC (`SelfTest.swift:170`, `:210`). Le second commande volontairement le silence.

Aucun `get-task-allow` n’est déclaré dans les entitlements sources ; son absence dans le binaire final reste à vérifier.

**G. L’intention GPL-2.0 n’est pas matérialisée dans les fichiers fournis**

- **Gravité : basse — Catégorie : publication**
- **Emplacement :** racine : fichier `LICENSE` absent ; `README.md:1` ; `project.yml:33`.
- **Constat et preuve :** aucune licence GPL n’apparaît dans l’arborescence examinée, le README ne formule pas la concession annoncée et le champ copyright est vide.
- **Scénario concret :** un lecteur du futur dépôt ne dispose pas des conditions de réutilisation annoncées dans ce brief.
- **Recommandation :** ajouter le texte GPL-2.0 et une mention explicite du titulaire et du choix `GPL-2.0-only` ou `GPL-2.0-or-later`. Prévoir l’accès au code source correspondant aux versions binaires publiées.

**3. Points vérifiés et jugés corrects**

- **Droits et confidentialité audio :** sandbox minimal, Hardened Runtime activé, aucune exception sensible, aucun droit réseau ou microphone. Aucun enregistrement de son capté ni envoi réseau identifié ; les WAV de validation sont des signaux synthétiques.
- **Chemin normal :** tap privé ciblé par périphérique/flux, exclusion explicite du processus, refus de démarrer si cette exclusion est impossible. Aucun chemin de double lecture établi dans ce fonctionnement.
- **Ressources :** nettoyage des échecs partiels du moteur ; ordre arrêt → destruction IOProc → agrégat → tap ; capture forte du processeur par le bloc. Les sondes utilisent correctement des `defer`.
- **Concurrence :** décisions sur le MainActor ; fermetures audio créées hors de son isolation ; compteurs atomiques ; publication acquisition/libération correcte des échantillons de mesure.
- **Pointeurs et DSP :** allocations principales hors traitement, parcours bornés par les tailles de tampons, état limité à 16 canaux ; disposition de `IOProcStreamUsage` cohérente avec arm64. Formules RBJ et tests de stabilité pertinents ; réglages décodés bornés, reconnaissance indépendante du nom affiché.
- **Temps réel — limite de conclusion :** aucun verrou, journal, accès fichier ou allocation explicite trouvé dans `process`. L’absence absolue d’ARC, d’allocation implicite et de contrôle d’exclusivité **n’est pas prouvée** par la lecture Swift : elle exige inspection du code optimisé ou instrumentation. Les mutations de propriétés de classe méritent cette vérification. [Explication Apple sur l’exclusivité](https://developer.apple.com/videos/play/wwdc2025/312/)

Les essais matériels déjà indiqués « à faire » ne sont pas comptés comme défauts. L’historique Git et les artefacts signés n’étaient pas disponibles dans le dossier examiné.