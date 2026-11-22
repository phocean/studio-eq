# Synthèse de la revue finale de Studio EQ 1.0.0 (22 novembre 2026)

Trois relecteurs indépendants (Claude, Codex, Grok) ont reçu la même consigne
([BRIEF.md](BRIEF.md)) : qualité, sécurité et architecture de la version publiée. Ils ont
travaillé en lecture seule, sans lancer l'app et sans lire les revues précédentes. Rapports :
[revue-claude.md](revue-claude.md) · [revue-codex.md](revue-codex.md) ·
[revue-grok.md](revue-grok.md).

## Verdict

Les trois rapports concluent à une version **saine et publiable** : **aucun constat critique ni
de gravité haute**. Ils jugent corrects :

- les droits : sandbox seul, Hardened Runtime ;
- la confidentialité : aucun son écrit ni transmis, identifiants masqués dans les journaux ;
- le chemin temps réel ;
- le cycle de vie du tap et de l'agrégat ;
- la vérification de l'autorisation avant chaque montage ;
- la chaîne de signature ;
- l'absence de données personnelles dans le dépôt.

Les constats restants sont :

- des **garde-fous à compléter** : entrées extrêmes, taux d'échantillonnage nul, lancements
  simultanés ;
- une **qualité de limitation à améliorer** dans les graves ;
- des **contrôles de publication** contournables ou trop faibles ;
- des **tests et une documentation** à remettre à niveau.

J'ai vérifié dans le code les constats 1, 3, 4, 5 et 6. Le comportement audible des constats
marqués « à vérifier » n'a pas été reproduit.

## Constats regroupés

Gravité : celle retenue après recoupement. ● signalé, — non signalé.

| # | Constat | Gravité | Claude | Codex | Grok | Correction |
|---|---|---|---|---|---|---|
| 1 | Deux lancements simultanés passent tous deux le contrôle d'instance. Le changement rapide d'utilisateur n'est pas géré. Risque de silence ou de boucle (à vérifier). | moyenne | ● | — | ● | Verrou `flock` dans le conteneur ; arrêt du moteur quand la session devient inactive. |
| 2 | Le limiteur n'a pas de maintien : il aplatit chaque crête dans les graves. Simulation : environ 3 % de distorsion à 40 Hz quand il travaille. Le README parle de « légère compression ». | moyenne | ● | — | — | Maintien de l'enveloppe de 25 ms (un compteur), test de distorsion, phrase du README corrigée. |
| 3 | Un échantillon fini mais énorme déborde à la conversion en `Float` : l'enveloppe du limiteur devient infinie et **toute la sortie reste muette** jusqu'à la reconstruction du moteur. | moyenne | — | ● | — | Contrôler la sortie et l'enveloppe, les remettre à zéro si elles ne sont pas finies ; test « valeur extrême puis signal normal ». |
| 4 | Un taux d'échantillonnage nul ou non fini lu sur l'agrégat démarre un moteur qui ne peut produire que du silence, alors que l'original est coupé (à vérifier sur matériel). | moyenne | — | — | ● | Refuser le montage hors de 8 à 384 kHz. |
| 5 | `make publish` saute la notarisation si `SKIP_NOTARIZATION=1` traîne dans l'environnement. | moyenne | — | ● | ● | Forcer `SKIP_NOTARIZATION=0` pour `release` et `publish`. |
| 6 | L'étiquette est poussée avant la création de la release : un échec de `gh` laisse une étiquette sans DMG et bloque l'essai suivant. | moyenne | — | — | ● | Retirer l'étiquette, sur le dépôt et en local, si la release échoue. |
| 7 | Le contrôle « pas d'outils de validation » est fragile. `grep -q` avec `pipefail` peut manquer une correspondance (Codex). Les chaînes Swift courtes, comme `TargetDeviceUID`, n'apparaissent pas dans `strings` (Claude, mesuré). | moyenne | ● | ● | — | Chercher le symbole `SelfTest` avec `nm` et des marqueurs longs, sans `grep -q`. |
| 8 | Le contrôle des droits compte des lignes et non des clés, et ne vérifie pas que le sandbox vaut `true`. | moyenne | — | ● | — | Lire le plist signé et exiger exactement `{app-sandbox: true}`. |
| 9 | Aucun test de la machine à états d'`AppModel` : permission consommée, échec, veille, annulation. | moyenne | ● | ● | ● | Extraire la décision en fonction pure et la tester (plus gros chantier, prévu pour la 1.1). |
| 10 | Un échec passager de la vérification reste affiché comme une erreur jusqu'au clic sur Réessayer, même si la configuration change. Le son reste intact. | basse | ● | — | ● | Remettre `.failed` à zéro quand la configuration change, plus un nouvel essai automatique borné. |
| 11 | `ARCHITECTURE.md` parle encore d'un « préampli automatique », et ses nombres de lignes sont périmés. Le tableau de mesures de `DSP.md` n'est pas recalculable depuis le rapport joint. | basse | ● | ● | ● | Corriger, et régénérer le tableau à partir d'un auto-test. |
| 12 | Les tests de reconnaissance utilisent `Studio Display:05AC:1114` au lieu de l'identifiant réel `Studio Display Audio Control:05AC:1114`. | basse | ● | — | ● | Ajouter la valeur réelle comme cas de référence. |
| 13 | La CI ne compile jamais la Release, seulement le Debug avec `VALIDATION`. | basse | ● | — | — | Ajouter `make build` à la CI. |
| 14 | `make publish` ne vérifie pas le Team ID signé. `Local.xcconfig` peut modifier le build publié. Une erreur réseau de `ls-remote` est prise pour « étiquette absente ». | basse | ● | — | — | Comparer `TeamIdentifier`, distinguer le code 2 de `ls-remote`, limiter `Local.xcconfig` à la signature. |
| 15 | Robustesse des scripts : chemins avec espaces, trousseau, journal de notarisation perdu en cas d'erreur, `python3` absent d'un Mac neuf. | basse | ● | — | — | Guillemets, `KEYCHAIN_FLAGS`, statut de `notarytool` capturé, `plutil` au lieu de `python3`. |
| 16 | La sonde de permission écrit du Float32 sans lire le format de sortie. | basse | — | — | ● | Vérifier le format avant de démarrer la sonde. |
| 17 | `kAudioDevicePropertyDeviceHasChanged` n'est pas écouté : un changement de format à fréquence égale passe inaperçu (à vérifier). | basse | — | — | ● | Ajouter l'écouteur. |
| 18 | Des compteurs réservés à la validation tournent dans l'IOProc de production. Le commentaire « aucun appel au runtime » est inexact. `filterResets` n'est jamais journalisé. | info | ● | — | — | Les passer sous `#if VALIDATION` ou les exploiter ; corriger le commentaire. |
| 19 | Pistes pour la 1.1 : profil de périphérique plutôt qu'un booléen, bandes générées depuis `BandDesign.all`, préférences tolérantes aux nouveaux champs. Messages d'erreur techniques non traduits. | info | ● | — | ● | À intégrer à la 1.1. |
| 20 | `docs/revues/claude.md` était chargé automatiquement comme `CLAUDE.md` (système de fichiers insensible à la casse) : le rapport précédent est entré dans le contexte du relecteur Claude. | info | ● | — | — | **Corrigé** : les rapports s'appellent maintenant `revue-*.md`. |

## Points de désaccord

- **Gravité des contrôles de publication (5 à 8).** Codex et Grok les classent en gravité
  moyenne, Claude en basse. Rien ne montre que le DMG 1.0.0 en a souffert : sa notarisation et
  sa signature ont été vérifiées après publication. Mais ces contrôles sont la dernière barrière
  avant une version suivante, d'où la gravité moyenne retenue.
- **Constats d'un seul relecteur.** Le limiteur (2) et le débordement en `Float` (3) n'ont été
  vus que par un relecteur. Ils sont vérifiables dans le code, et la simulation de Claude est
  reproductible.

## Proposition

- **Avant toute 1.0.1 : constats 1 à 8, 10 à 13 et 18.** Ce sont des corrections locales et
  testables : garde-fous du DSP et du moteur, contrôles de publication, docs, CI.
- **Pour la 1.1 : constats 9, 14 à 17 et 19.** La machine à états testable est le plus gros
  chantier.

## Suite donnée (22 novembre 2026)

Constats 1 à 8, 10 à 13 et 18 corrigés dans la version 1.1.0, qui ajoute aussi l'option « Masquer l'icône sans Studio Display » :

- **1** : verrou `flock` dans le conteneur ; moteur arrêté tant que la session est en
  arrière-plan.
- **2** : maintien de 25 ms dans le limiteur ; test de distorsion (< 0,1 % de 40 à 100 Hz).
- **3** : échantillons filtrés bornés à ±16 avant le limiteur ; test de rafale à ±3,4·10³⁸.
- **4** : montage refusé hors de 8 à 384 kHz.
- **5 à 8** : `SKIP_NOTARIZATION=0` forcé, étiquette retirée si la release échoue, recherche de
  `SelfTest` avec `nm` et de marqueurs longs, droits lus comme un plist.
- **10** : un échec de vérification est traité comme un échec de montage, avec un seul nouvel
  essai automatique après 3 s ; réveil et retour de session oublient les échecs passés.
- **11 à 13** : documentation, identité réelle dans les tests, build Release dans la CI.
- **18** : compteurs et `silenceOutput` sous `#if VALIDATION`, remises à zéro journalisées à
  l'arrêt du moteur, état du limiteur hors des propriétés de classe.

Les deux tests DSP échouent sur le code 1.0.0 et réussissent sur le code corrigé : détail dans
[TESTS.md §9](../../TESTS.md).
