# Paramètres DSP et justification

## Point de départ

Le fil r/mac « Studio Display equalizer » propose **graves −6 dB, médiums +3 dB, aigus +2 dB**
avec un égaliseur trois bandes grand public. Ces chiffres sont un réglage d'écoute subjectif,
pas une calibration, et le fil ne précise ni fréquences ni largeurs. Les trois gains ne suffisent
donc pas comme spécification : il faut fixer la forme de chaque filtre. Choix retenus :

| Réglage | Filtre | Fréquence | Q | Plage | Défaut | Raison |
|---|---|---|---|---|---|---|
| Graves | Plateau bas (low shelf) | 150 Hz (point à mi-gain) | 0,707 | ±12 dB | −6 dB | Atténue l'excès de grave/bas-médium que l'on reproche à l'enceinte compacte de l'écran ; plein effet sous ~70 Hz, quasi nul au-dessus de 400 Hz, donc le corps des voix est préservé. Q 0,707 : pente sans bosse ni creux (Butterworth). |
| Médiums | Cloche (peaking) | 1,5 kHz | 0,7 (≈ 1,9 octave) | ±12 dB | +3 dB | Présence des voix et des instruments. Une cloche large reste un « tilt » tonal et non une résonance audible. |
| Aigus | Plateau haut (high shelf) | 6 kHz (point à mi-gain) | 0,707 | ±12 dB | +2 dB | « Air » et détail ; la zone de sifflantes (5–8 kHz) ne reçoit que la moitié du gain. |

Formules : Robert Bristow-Johnson, *Audio EQ Cookbook* (biquads RBJ), coefficients normalisés
`a0 = 1`, calculés à la fréquence d'échantillonnage réelle du périphérique (44,1 / 48 / 88,2 /
96 kHz sur le Studio Display). Le code est dans `StudioEQ/DSP/EQDesign.swift`.

## Préampli fixe et limiteur (anti-écrêtage)

**Préampli fixe : −3 dB**, quels que soient les réglages. Il couvre exactement la courbe par
défaut, dont la bosse maximale vaut +3,0 dB à 1,5 kHz : avec les réglages par défaut, aucune
fréquence n'est rendue plus forte que l'original.

Première version écartée : un préampli **automatique** qui compensait toute la bosse de la
courbe (`−max H(f)`). Défaut constaté à l'écoute : une accentuation se transformait en baisse
de tout le reste (aigus +12 dB → tout le son 12 dB plus bas), si bien que baisser les aigus
rendait la musique plus forte. Avec un préampli fixe, chaque curseur ne bouge que sa bande
(test `testEachSliderRaisesItsOwnBandAndBarelyMovesTheRest`).

**Limiteur de crête en sortie.** Une courbe ≤ 0 dB ne borne pas les crêtes : les filtres à
phase minimale décalent les harmoniques. Mesuré (revues de code, simulation) : +3 dBFS en
crête sur un signal carré pleine échelle à 100 Hz avec les réglages par défaut. Le limiteur
est commun à tous les canaux (l'image stéréo et spatiale ne bouge pas), à attaque instantanée,
**maintien de 25 ms** puis relâchement de 100 ms, plafond −0,2 dBFS. Il ne fait rien tant
qu'aucune crête ne dépasse le plafond ; il prend aussi en charge les accentuations au-delà de
+3 dB.

Le maintien est ce qui en fait un limiteur et non un écrêteur. Sans lui (version 1.0.0),
l'enveloppe redescendait entre deux crêtes d'une note grave : chaque crête était aplatie sur le
plafond, soit 3,2 % de distorsion harmonique à 40 Hz, 2,6 % à 50 Hz et 1,4 % à 100 Hz (revue
finale, mesuré par le test ci-dessous sur l'ancien code). 25 ms couvrent une demi-période
jusqu'à 20 Hz : sur une note tenue, le gain reste constant et la note est seulement baissée.

Tests : sortie ≤ plafond sur des carrés pleine échelle avec quatre réglages extrêmes ; sinus à
0,9 inchangé (±0,05 dB) ; sinus de 40, 50 et 100 Hz à 3,2 dB au-dessus du plafond ramené au
plafond avec moins de 0,1 % de distorsion.

**Échantillons invalides.** Un `NaN` ou un `Inf` envoyé par une app défaillante resterait pour
toujours dans l'état récursif du filtre. L'état de chaque canal est contrôlé une fois par cycle
d'E/S ; s'il n'est plus fini, il est remis à zéro et ce cycle (≈ 5 ms) est rendu silencieux
sur ce canal seulement. Le nombre de remises à zéro est journalisé à l'arrêt du moteur. Test :
un `NaN` et un `Inf` injectés, puis retour au niveau attendu.

**Échantillons finis mais démesurés.** Une valeur comme 10³⁸, amplifiée par un filtre,
dépassait la plage d'un `Float` et devenait infinie : l'enveloppe du limiteur devenait infinie
à son tour et **toute la sortie restait muette** jusqu'au prochain montage du moteur (revue
finale). Chaque échantillon filtré est désormais borné à ±16 (+24 dBFS) avant le limiteur ; le
pire cas est le retour normal de l'enveloppe, en ≈ 0,3 s. Test : une rafale de ±3,4·10³⁸ avec
les aigus à +12 dB, puis retour au niveau attendu.

Réponse totale avec les réglages par défaut (préampli inclus), mesurée en numérique sur le
Studio Display par l'auto-test : rapport [48 kHz](selftest-studio-display-48k.txt), colonne
`measured`, dont on a retiré le décalage global de +0,29 dB que le rapport indique (il vient de
la capture de référence, voir TESTS.md §2) :

| Hz | 40 | 80 | 150 | 300 | 700 | 1 500 | 3 000 | 6 000 | 10 000 | 16 000 |
|---|---|---|---|---|---|---|---|---|---|---|
| Théorie (dB) | −8,97 | −8,51 | −5,94 | −3,14 | −1,76 | 0,00 | −1,50 | −1,66 | −1,06 | −0,99 |
| Mesure (dB) | −8,96 | −8,50 | −5,93 | −3,13 | −1,76 | 0,00 | −1,51 | −1,66 | −1,07 | −1,00 |

## Mise en œuvre temps réel (`EQProcessor`)

- Trois biquads en cascade, **forme directe transposée II**, état et calcul en `Double`
  (précision des graves à 150 Hz/96 kHz), entrées/sorties `Float32`.
- **Même courbe sur tous les canaux** (jusqu'à 16 ; le Studio Display en expose 8 en 5.1.2).
  Le LFE est filtré comme les autres : le plateau bas agit donc aussi sur lui, ce qui est
  cohérent avec l'intention « moins de grave ».
- **Lissage** : les gains glissent vers leur cible avec une constante de
  30 ms ; les coefficients ne sont recalculés qu'en cours de glissement, une fois par cycle
  d'E/S. Test unitaire : un saut demandé de 12 dB ne produit aucune discontinuité.
- **Contraintes temps réel** : aucune allocation, aucun verrou, aucun appel bloquant ni
  journalisation dans l'IOProc. Les réglages passent de l'interface au thread audio par des
  atomiques sans verrou (`Synchronization.Atomic`, ordre relâché).
- États sous 1e-20 remis à zéro après chaque cycle (pas de nombres dénormaux en silence).
- Réglages à plat → filtres identité exacts (seul reste le préampli fixe de −3 dB).
