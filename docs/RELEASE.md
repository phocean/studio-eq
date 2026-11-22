# Publier une version

Le DMG est construit, signé et notarisé **sur le Mac du titulaire du compte développeur**, puis
déposé dans une release GitHub. La clé privée Developer ID ne quitte jamais son trousseau : rien
n'est confié à GitHub, qui ne reçoit que le DMG final et sa somme SHA-256.

```bash
make publish
```

Dans l'ordre, `make publish` :

1. refuse de continuer si des modifications ne sont pas validées (commit) ou pas poussées : le
   binaire publié doit correspondre exactement au code source publié (GPL) ;
2. refuse si l'étiquette `vX.Y.Z` existe déjà sur GitHub ;
3. lance les tests unitaires ;
4. lance `make release` : build Release signé Developer ID, vérifications bloquantes (ci-dessous),
   DMG signé, notarisation par Apple, agrafage du ticket, contrôle Gatekeeper ;
5. seulement alors, crée et pousse l'étiquette `vX.Y.Z` ;
6. crée la release GitHub avec le DMG et son `.sha256`, et affiche son adresse.

Un échec aux étapes 1 à 4 ne laisse aucune trace sur GitHub.

## Nouvelle version

1. Changer `MARKETING_VERSION` dans `project.yml` (par exemple `"1.1.0"`).
2. Valider (commit) et pousser.
3. `make publish`.

Le numéro de build (`CFBundleVersion`) est le nombre de commits : il augmente toujours.

## Réglage à faire une fois : les identifiants de notarisation

La notarisation envoie le DMG à Apple, qui doit savoir qui l'envoie. `notarytool` enregistre ces
identifiants dans le trousseau de session, sous un nom (« profil ») que `make` utilise ensuite :
`studio-eq` par défaut.

1. Créer un **mot de passe pour app** : [account.apple.com](https://account.apple.com) ›
   *Connexion et sécurité* › *Mots de passe pour app* › *+*, nom « notarytool ». Apple l'affiche
   une seule fois ; il sert uniquement à cet usage et se révoque au même endroit.
2. L'enregistrer dans le trousseau. La commande demande ensuite ce mot de passe, sans l'afficher :

   ```bash
   xcrun notarytool store-credentials studio-eq --apple-id <votre Apple ID> --team-id <Team ID>
   ```

   Le Team ID figure dans `Config/Local.xcconfig` (`DEVELOPMENT_TEAM`).
3. Vérifier (affiche l'historique des envois, vide la première fois) :

   ```bash
   xcrun notarytool history --keychain-profile studio-eq
   ```

Une clé d'API App Store Connect (`.p8`) fonctionne aussi : `scripts/release.sh` accepte
`NOTARY_KEY_PATH`, `NOTARY_KEY_ID` et `NOTARY_ISSUER` à la place du profil.

## Vérifications bloquantes de `make release`

- signature valide, autorité **Developer ID Application**, **horodatage sécurisé**,
  **Hardened Runtime** ;
- un seul droit : le sandbox (pas de réseau, pas de micro, **pas de `get-task-allow`**) ;
- aucun outil de validation dans le binaire (`--selftest`, `-TargetDeviceUID`) ;
- numéro de version identique à celui demandé ;
- notarisation « Accepted » (sinon le journal d'Apple est affiché), ticket agrafé, DMG accepté
  par Gatekeeper (`spctl`).

## Essais sans publier

```bash
make dmg
```

DMG signé et vérifié, **non notarisé** (aucun identifiant requis) ; Gatekeeper le refuserait
sur un autre Mac.

```bash
make release
```

DMG notarisé et agrafé dans `build/release/`, sans étiquette ni release GitHub.

## Pourquoi pas GitHub Actions

Un workflow pourrait construire le DMG sur une machine de GitHub, mais il faudrait y déposer, en
secrets, le certificat Developer ID **avec sa clé privée** et une clé de notarisation. Choix
retenu : la clé ne quitte pas le Mac du développeur. GitHub Actions ne sert qu'à l'intégration
continue (`ci.yml` : build et tests à chaque poussée, sans aucun secret).
