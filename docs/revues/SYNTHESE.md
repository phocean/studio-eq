# Synthèse des trois revues de code — 21 novembre 2026

Revue finale de la version 1.0.0 publiée : [finale/SYNTHESE.md](finale/SYNTHESE.md).

Trois relecteurs indépendants (Claude, Codex, Grok), même consigne ([BRIEF.md](BRIEF.md)),
lecture seule, sans accès aux rapports des autres : [revue-claude.md](revue-claude.md) ·
[revue-codex.md](revue-codex.md) · [revue-grok.md](revue-grok.md).

Verdict commun : cœur sain (droits minimaux, aucune fuite du son capté, chemin temps réel
propre, démontage correct), mais **pas publiable en l'état**. Tous les constats ci-dessous ont
été relus dans le code avant d'être retenus.

| # | Constat | Gravité | Claude | Codex | Grok | Suite donnée |
|---|---|---|:-:|:-:|:-:|---|
| 1 | Autorisation mémorisée pour toute la session : après un retrait, le montage suivant pouvait couper le son (silence total) | haute | ✓ | ✓ | ✓ | **Corrigé** : vérification avant chaque montage ; README rectifié. |
| 2 | Signature non notarisable (`Apple Development`, `get-task-allow`, pas d'horodatage) ; identifiant d'équipe en dur | haute | ✓ | ✓ | ✓ | **Étape publication** : Developer ID + workflow GitHub. |
| 3 | Deux instances se captent l'une l'autre (silence ou boucle) | haute | ✓ | | | **Corrigé** : contrôle au lancement (la clé `LSMultipleInstancesProhibited` bloquait aussi les tests) ; vérifié. |
| 4 | Échec mémorisé jamais effacé après un succès ; menu « Actif » alors que le moteur est arrêté | haute | | | ✓ | **Corrigé** : nouvel essai dès que la configuration change, état « Erreur » toujours réaffiché. |
| 5 | Le préampli n'empêche pas l'écrêtage (crêtes à +3 dBFS mesurées en simulation) ; préampli publié après les gains | moyenne | ✓ | ✓ | (info) | **Corrigé** : limiteur de crête en sortie ; préampli fixe −3 dB (voir aussi l'écoute du client). |
| 6 | Un `NaN`/`Inf` d'une app empoisonne le filtre jusqu'au remontage | moyenne | ✓ | | | **Corrigé** : état contrôlé et remis à zéro ; test. |
| 7 | Numéro de série de l'écran, chemin du compte, logiciels installés dans `docs/` ; numéro de série dans un test | moyenne | ✓ | ✓ | ✓ | **Corrigé** : rapports anonymisés, numéro fictif. |
| 8 | Modes de test et forçages (`-TargetDeviceUID`…) livrés dans l'app de production | moyenne | ✓ | ✓ | ✓ | **Corrigé** : compilés seulement en validation, lus seulement sur la ligne de commande. |
| 9 | `install.sh` installe l'ancien build si la compilation échoue | moyenne | ✓ | ✓ | ✓ | **Corrigé**. |
| 10 | Vérification d'autorisation non annulable ; résultat obsolète appliqué ; attente de 120 s si l'écran disparaît | moyenne | ✓ | ✓ | | **Corrigé** : tâche annulable, numéro de génération, échec en 2 s si le périphérique ne répond plus. |
| 11 | UID (numéro de série, adresse Bluetooth) en clair dans les journaux | basse | ✓ | ✓ | ✓ | **Corrigé** : empreinte `private(mask: .hash)`. |
| 12 | Licence GPL absente, copyright vide | basse | ✓ | ✓ | ✓ | **Étape publication**. |
| 13 | Format du tap partiellement vérifié ; changement de format ignoré | basse | ✓ | | | **Corrigé** : format contrôlé au montage ; nombre de canaux dans la clé du moteur. |
| 14 | Veille : un événement entre veille et réveil pouvait remonter le moteur | info | ✓ | ✓ | | **Corrigé** : état « en veille ». |
| 15 | Rappel déjà programmé exécuté après « Quitter » | basse | | | ✓ | **Corrigé** : annulé à l'arrêt. |
| 16 | `scenario.sh` sans nettoyage ; sortie non restaurée | basse | ✓ | | ✓ | **Corrigé** : `trap` qui restaure la sortie d'origine. |
| 17 | `@State` du modèle dans la structure `App` (deux modèles possibles) | à vérifier | ✓ | | | **Corrigé par précaution** : modèle créé une seule fois, hors de la structure. |
| 18 | Motif de la vérification : continu par canal, pas alterné (commentaire faux) | info | ✓ | | | **Corrigé**. |
| 19 | Absence d'ARC/allocation implicite dans l'IOProc non prouvée par outil | info | ✓ | ✓ | | **Reporté** : passer RTSan ou `@_noAllocation` plus tard. |
| 20 | Agrégat de `audioctl fake` public | basse | | | ✓ | **Non retenu** : il doit être public pour pouvoir être choisi comme sortie système. |

Constat apporté par l'écoute du client, et non par les revues : avec le préampli automatique,
baisser les aigus rendait la musique plus forte. Corrigé par le préampli fixe (voir
[DSP.md](../DSP.md)).

Validation après correction : [TESTS.md §7](../TESTS.md).
