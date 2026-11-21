# Publier une version

Une version = une étiquette `vX.Y.Z` poussée sur GitHub. Le workflow
[`release.yml`](../.github/workflows/release.yml) lance alors les tests, construit l'app
signée **Developer ID**, la vérifie, l'emballe dans un DMG signé, la fait **notariser** par
Apple, agrafe le ticket, contrôle le DMG avec Gatekeeper et publie la release GitHub
(DMG + somme SHA-256). Il appelle `make release`, comme on le ferait sur un Mac ; la logique est
dans [`scripts/release.sh`](../scripts/release.sh).

```bash
git tag v1.0.0 && git push origin v1.0.0
```

## Réglages à faire une fois (par le titulaire du compte développeur)

Ils sont propres au compte Apple et restent hors du dépôt. Dans GitHub : *Settings › Secrets
and variables › Actions* (ou dans l'environnement `release`, qui permet d'exiger une
approbation avant chaque publication).

| Nom | Type | Contenu |
|---|---|---|
| `APPLE_TEAM_ID` | variable | Identifiant d'équipe (10 caractères ; il figure de toute façon dans la signature). |
| `DEVELOPER_ID_P12_BASE64` | secret | Certificat « Developer ID Application » **avec sa clé privée**, exporté en `.p12` depuis Trousseaux d'accès, puis encodé : `base64 -i DeveloperID.p12 \| pbcopy`. |
| `DEVELOPER_ID_P12_PASSWORD` | secret | Mot de passe choisi à l'export du `.p12`. |
| `NOTARY_KEY_P8_BASE64` | secret | Clé d'API App Store Connect (`AuthKey_XXXX.p8`, rôle *Developer*), encodée : `base64 -i AuthKey_XXXX.p8 \| pbcopy`. Créée dans App Store Connect › Utilisateurs et accès › Intégrations › Clés d'équipe. |
| `NOTARY_KEY_ID` | secret | Identifiant de cette clé. |
| `NOTARY_ISSUER_ID` | secret | « Issuer ID » affiché sur la même page. |

Avec `gh`, depuis le dossier du dépôt (chaque commande demande la valeur, qui ne passe pas par
l'historique du shell) :

```bash
gh secret set DEVELOPER_ID_P12_BASE64 < <(base64 -i DeveloperID.p12)
gh secret set DEVELOPER_ID_P12_PASSWORD
gh secret set NOTARY_KEY_P8_BASE64 < <(base64 -i AuthKey_XXXX.p8)
gh secret set NOTARY_KEY_ID
gh secret set NOTARY_ISSUER_ID
```

Le certificat est importé dans un trousseau temporaire du runner, supprimé à la fin, même en cas
d'échec.

## Vérifications bloquantes de `make release`

- signature valide, autorité **Developer ID Application**, **horodatage sécurisé**,
  **Hardened Runtime** ;
- un seul droit : le sandbox (pas de réseau, pas de micro, **pas de `get-task-allow`**) ;
- aucun outil de validation dans le binaire (`--selftest`, `-TargetDeviceUID`) ;
- numéro de version identique à l'étiquette ;
- notarisation « Accepted » (sinon le journal d'Apple est affiché), ticket agrafé, DMG accepté
  par Gatekeeper (`spctl`).

## Essai local

`VERSION` vaut par défaut celle de `project.yml`, `TEAM_ID` celle de `Config/Local.xcconfig`.

```bash
make dmg
```

Avec notarisation, après `xcrun notarytool store-credentials studio-eq` (identifiants saisis
par vous) :

```bash
make release VERSION=1.0.0 NOTARY_PROFILE=studio-eq
```
