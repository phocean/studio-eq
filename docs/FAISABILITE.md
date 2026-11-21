# Phase 1 — Faisabilité du traitement du son système

Objectif : égaliser **le son de toutes les apps** lorsqu'il sort par les haut-parleurs du Studio
Display, et seulement à ce moment-là, sans casser le reste du système audio.

Plateforme cible vérifiée : MacBook Pro M4, macOS 27.3, Xcode 27.2, Swift 6.4.

## Candidats étudiés

| # | Mécanisme | Fonctionnement réel | Permissions | Stabilité / maintenance | Latence | Ressources | Verdict |
|---|---|---|---|---|---|---|---|
| A | **Process tap Core Audio + agrégat privé** (macOS 14.2+) : tap sur le flux du Studio Display, en sourdine pendant la lecture, relu par un agrégat privé qui joue le son corrigé sur le même écran | **Démontré de bout en bout** (voir TESTS.md) : son d'un autre processus capté, filtré, restitué ; original réellement coupé | « Enregistrement de l'écran et de l'audio du système » (TCC, audio système seul). Sandbox et Hardened Runtime compatibles, aucun droit administrateur | API publique Apple, aucun composant système installé ; si l'app meurt, macOS rétablit le son d'origine | **4,2 ms ajoutées** (mesurées, 48 kHz) | ≈ 0,2–0,3 % d'un cœur en lecture, ≈ 0 sans lecture | **Retenu** |
| B | Pilote audio virtuel (AudioServerPlugIn : BlackHole, pilote eqMac, ACE de Rogue Amoeba) | Fonctionne, éprouvé | Installation dans `/Library/Audio/Plug-Ins/HAL` (admin), redémarrage de `coreaudiod` | Composant système à maintenir à chaque version de macOS ; la sortie système devient le périphérique virtuel, donc « Studio Display sélectionné » perd son sens, touches de volume à re-router, risque de silence si le pilote casse | 1–2 tampons | Faible | Écarté : impose un pilote et change le modèle de sortie de l'utilisateur |
| C | ScreenCaptureKit (capture audio système, macOS 13+) | Capte, mais **ne peut pas couper l'original** | Enregistrement d'écran | Stable | — | Moyenne | Écarté : double lecture garantie |
| D | AVAudioEngine / AUGraph / Audio Units seuls | Ne traitent que le son **de l'app elle-même** | — | — | — | — | Écarté : pas d'accès au son des autres apps |
| E | Réglages intégrés de macOS (EQ de Musique, Accommodations audio) | EQ de Musique limité à Musique ; accommodations réservées à certains casques | — | — | — | — | Écarté : pas d'EQ système |
| F | Open source existant (eqMac, BlackHole, FineTune…) | eqMac/BlackHole = variante B ; FineTune = variante A (EQ par app) | selon variante | Dépendance externe à auditer | — | — | Pas de dépendance ; A est implémenté directement en ~400 lignes |

## Point de vigilance du cahier des charges : « un tap n'est pas un remplacement transparent »

Exact : un tap ne fait que **copier** un flux. Le chemin complet retenu est :

```
apps ──► flux 0 du Studio Display ──► process tap  (muteBehavior = mutedWhenTapped,
                                         │           exclut le processus Studio EQ)
                                         ▼
                 agrégat privé { entrée : le tap ; sortie : le Studio Display }
                                         │  IOProc temps réel : EQProcessor
                                         ▼
                              haut-parleurs du Studio Display
```

- `mutedWhenTapped` : l'original n'est coupé **que pendant que le tap est lu**. Si Studio EQ
  s'arrête ou plante, macOS remet immédiatement le son d'origine (échec = son normal).
- Tap **par périphérique et par flux** (`CATapDescription(excludingProcesses:deviceUID:stream:)`) :
  seul le son destiné au Studio Display est capté et coupé ; un son envoyé aux AirPods ou aux
  haut-parleurs du Mac n'est jamais touché, même par une app qui choisit sa sortie elle-même.
- Le processus Studio EQ est **exclu** du tap : sa propre sortie ne peut pas reboucler.
- Tap et agrégat sont **privés** (invisibles des autres apps et du menu Son) et disparaissent
  avec le processus.
- Le tap a le format du flux du périphérique : **8 canaux 5.1.2 à 48 kHz** sur le Studio
  Display (L R C LFE Ls Rs Ltm Rtm) ; chaque canal est filtré vers le même canal de sortie,
  le contenu spatial n'est donc pas perdu.

## Découvertes faites pendant la validation (elles ont changé la conception)

1. **Refus de la permission = silence total.** Mesuré : si l'utilisateur refuse « Enregistrement
   audio du système », le tap continue de tourner, **coupe toujours l'original**, mais ne livre que
   des zéros. Il n'existe pas d'API publique pour lire cette permission. Parade : `CaptureCheck`
   vérifie la capture **avant de couper quoi que ce soit** (tap non muet sur Studio EQ lui-même
   + motif inaudible à −120 dBFS). Si la capture échoue, le moteur ne démarre pas, le son reste
   intact et le menu propose d'ouvrir les réglages de confidentialité.
2. **Veille.** Core Audio pose une assertion `PreventUserIdleSystemSleep` pour toute E/S active.
   Studio EQ déclare `kAudioHardwarePropertySleepingIsAllowed = 1` : seules les apps qui jouent
   réellement empêchent la veille, comme sans Studio EQ.
3. **Coût au repos.** Un tap ne tourne que lorsque sa source joue : sans lecture, l'IOProc n'est
   pas appelée (≈ 0 % CPU). Après une lecture, l'E/S reste active (≈ 0,3 % d'un cœur en
   Release). Un « déclenchement à l'activité » a été écarté : plus de code et un début de son non
   traité à chaque lecture, pour un gain marginal.

## Choix

**Variante A**, la plus simple qui satisfait réellement les exigences : API publique, aucun pilote,
aucune dépendance, sandbox actif, une seule permission (audio système).
