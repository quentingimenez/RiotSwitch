# RiotSwitch — mesures de performance (campagne 2026-11-11)

Mesures demandées : coût réel du **veilleur** et de l'**overlay** (replié/déplié, ouvert/fermé,
interactions, suivi de fenêtre), comparées aux chiffres annoncés dans la documentation du projet.

- Machine : Windows 11 Professionnel 10.0.26200, 16 processeurs logiques, 2 560×1 440, échelle DPI 1,0.
- Binaire mesuré : `dist/RiotSwitch.exe` v1.1.17 (`RiotSwitch.exe` 207 360 o, dll du 2026-11-10 22:44 UTC),
  framework-dependent (.NET 8).
- Sessions : campagne `official-01` (2026-11-11 01:52→02:03 UTC) + compléments `official-02`
  (02:15→02:20 UTC). Toutes les mesures officielles ont été faites **machine inactive**
  (dernière entrée utilisateur vérifiée : 01:54:06 UTC, avant la session A ; aucune entrée pendant
  A→E2 ni pendant official-02).
- Rôle de l'overlay : panneau 380 DIP × 305 DIP (3 comptes), bouton replié 40 × 40 DIP ; offsets
  settings right=30 / top=105 DIP ; `overlayPinned=true`.

## 1. Résumé exécutif

| Situation | CPU moyen (1 cœur) | Working set | Commentaire |
|---|---|---:|---|
| Veilleur `--watch` sans overlay (W) | **0,10 %** (0,006 % machine) | 10,4→15,8 Mo (méd. 11,5) | après trim, croît de ~35 Ko/s |
| Overlay replié visible (A) | **0,02 %** (0,0007 % machine) | 31,3→33,7 Mo | |
| Panneau déplié visible (B) | **0,01 %** (< résolution) | 39,0→39,9 Mo | |
| Survol + molette (C, 60 s) | **0,49 %** (pic 14,1 % sur 1 s) | 45,5→50,9 Mo | ~0,20 s CPU pour 40 survols + 20 molettes |
| Déplacements de la fenêtre Riot (D) | **0,11 %** (57 s) | 48,7→49,5 Mo | latence 1,5–3,4 ms, 10/10 changements |
| Cycle déplier/replier (E, 30×) | **9,4 ms CPU / cycle** | +1,6 Mo WS / +1,4 Mo commit | latence rect < 0,2 ms |
| Cycle détruire/recréer l'overlay (E2) | **32–34 ms CPU / cycle** | +0,5–0,7 Mo WS / cycle | disparition 3,7–4,1 s ; retour 65–81 ms |
| Démarrage à froid `--watch` (F) | 0,33 s CPU cumulés en 25 s | pic 64,2 Mo → 10,4 Mo au trim | trim à ~2,0–2,2 s |

En une phrase : **le veilleur caché coûte environ 0,1 % d'un cœur** (≈0,006 % de la machine, invisible
dans le Gestionnaire des tâches) et **l'overlay visible ~0,02 % d'un cœur** ; les coûts visibles sont
les interactions (~7 % d'un cœur pendant une manipulation active), l'ouverture/fermeture (≈10–34 ms
CPU) et la mémoire de travail qui accompagne l'overlay (10→40 Mo selon l'état et l'historique).

Ces chiffres ont été recoupés par un **harnais de vérification indépendant** (autre code, `Get-Counter`
+ `Get-Process`/P/Invoke, exécuté après la campagne) : CPU, ressources structurelles et latences du log
concordent ; les valeurs mémoire (WS/commit) dépendent de l'historique de la session et ne sont
comparables qu'en deltas — détails et tableau d'écarts au §9.

## 2. Méthode (et ses limites)

Instruments, tous en lecture seule côté cible :

- **`tools/perf/sampler/ProcessSampler.ps1`** (sampler développé pour la campagne) : `GetProcessTimes`
  (user+noyau, 100 ns), `GetProcessMemoryInfo` (WS, WS privé, commit=`PagefileUsage`, pic WS),
  `QueryWorkingSet` (WS privé), `GetProcessHandleCount`, `GetGuiResources` (GDI/USER),
  `GetProcessIoCounters`, `GetThreadTimes`. Échantillon 1 Hz, décimales invariantes.
  *Surcoût propre mesuré : 0,58–0,81 % d'un cœur* (processus PowerShell hôte, hors cible).
- **`tools/perf/probe/EventProbe.ps1`** : compte les WinEvents délivrés (hook out-of-context),
  coût propre GROSS ≤ 0,052 % d'un cœur.
- **`tools/perf/run/OverlayCtl.ps1`** : pilotage UI synthétique (clics `WM_LBUTTONDOWN/UP`, survol,
  molette, `SetWindowPos`, `ShowWindow`) et mesure des latences (Stopwatch) ; latence de suivi =
  premier changement de rect de l'overlay après déplacement de Riot.
- **Checks indépendants** : analyse des logs (`%LOCALAPPDATA%\RiotSwitch\logs\app.log`, 171 créations
  d'overlay horodatées à 0,1 µs), snapshots JSON avant/après de chaque phase, et vérificateur
  indépendant (`tools/perf/verify/`, `Get-Counter`/`Get-Process`) — voir `docs/perf/verification.fr.md`.

Limites à garder en tête :

- Résolution CPU Windows : quantum ~15,6 ms → à 1 Hz un échantillon vaut 1,56 % d'un cœur ; les
  valeurs très basses (A/B) sont donc **quantifiées** (46,9 ms / 150 s = 0,031 %) et sont des bornes
  hautes. Le débit CPU total (Δtemps processus / Δtemps réel) reste exact sur la fenêtre.
- Les entrées (clics, survol, molette) sont **synthétiques** (SendMessage) : elles mesurent le coût
  de traitement UI de RiotSwitch, pas le coût du pilote souris ni du compositeur Windows.
- Machine partagée avec l'utilisateur : une entrée utilisateur pendant le 1er passage W a doublé son
  CPU (0,24 % au lieu de 0,10 %). Les états A/B/C/D/E/E2 ont tous été mesurés sans activité.
- Une seule machine, une seule version ; pas de mesure GPU (l'overlay est rendu GDI+ côté CPU).

## 3. Coût par état (fenêtres de 150 s)

Sources : `tools/perf/results/campaign-official-01/{W-watch,A-watch,B-watch-expanded}` et
`campaign-official-02-wclean/W-watch`. Chiffres = agrégat sur la fenêtre, 2 premiers échantillons exclus.

| Métrique | W (`--watch`, sans overlay) | A (overlay replié) | B (panneau déplié) |
|---|---:|---:|---:|
| CPU moyen (% d'un cœur) | 0,223 % (2ᵉ passe propre : 0,106 %) | 0,021 % | 0,011 % |
| CPU (% machine) | 0,014 % / 0,0066 % | 0,0013 % | 0,0007 % |
| CPU total sur la fenêtre | 0,328 s / 0,156 s | 0,0312 s | 0,0156 s |
| WS min–méd–max (Mo) | 15,4–18,8–21,1 (propre : 10,4–11,5–15,8) | 31,3–31,6–33,7 | 39,0–39,7–39,9 |
| WS privé (Mo) | 3,6–7,1 (propre : 3,4–5,9) | 8,7–9,4 | 9,9–10,2 |
| Commit / « privé » (Mo) | 17,3–18,5 (propre : 32,7–33,3) | 18,5–19,0 | 19,2–19,5 |
| Handles | 430–445 (propre : 437–440) | 430–435 | 437–444 |
| GDI / USER | 15 / 21–22 | 21 / 29 | 21 / 31–32 |
| Threads | 8–16 | 8–11 | 8–11 |
| Page faults / s | 19 (propre : 12) | 4,3 | ~0 |

Lecture :

- La CPU du veilleur **sans overlay** est dominée par le timer de secours 1 Hz : quand `Find()` ne
  trouve pas la fenêtre Riot, `Check()` enchaîne `RestoreMinimizedOnce` + `Find` + `RaiseCoveredOnce`
  + `FindPresent` + `Find`, soit jusqu'à 4–5 énumérations `EnumWindows` par seconde (c'est aussi
  pourquoi W coûte 10× plus que A/B). En machine inactive, la sonde n'a compté que **4 événements
  WinEvent en 60 s** : le hook n'est pas la source du coût.
- Avec l'overlay visible, le suivi est un `Find()` réussi + timers 500 ms/120 ms : **0,01–0,02 % de
  cœur**, soit moins que la précision d'un échantillon 1 Hz.
- La mémoire de travail dépend de l'état : ~10–21 Mo (W), ~31–34 Mo (A), ~39–40 Mo (B). Le commit
  (« privé » au sens des docs) est **14,5–16,3 Mo au démarrage** puis **monte à ~33 Mo** après usage
  de l'overlay et n'est pas rendu par le trim (le trim ne réduit que le working set).

## 4. Interactions (survol, molette) — 60 s

`C-interactions`, panneau déplié, sampler concurrent.

- 40 survols espacés de 40 ms : envoi moyen 1,29 ms/survol (max 2,12).
- 20 molettes (±120) espacées de 40 ms : envoi moyen 0,11 ms (max 0,56).
- CPU : **0,297 s sur 60 s = 0,49 % d'un cœur** en moyenne ; le CPU est concentré sur les ~3 s
  d'interaction : ligne à **14,1 %** puis 3,1 % ×2 (≈0,20 s CPU pour la rafale, soit ~7 % d'un cœur
  pendant la manipulation).
- Mémoire : WS 45,5→50,9 Mo, WS privé 13,3→18,6 Mo, commit 21,8→27,0 Mo, page faults +24 216
  (403/s) : le rendu layered (bitmap ARGB + `UpdateLayeredWindow` à chaque changement de survol)
  alloue/touche de la mémoire, ce qui explique le coût.

## 5. Suivi de la fenêtre Riot (déplacement) — D

3 motifs de 10 pas (`SetWindowPos` toutes les 60 ms), mêmes offsets que l'usage réel :

| Motif | latence min / moy / max | changements |
|---|---:|---:|
| +120 px en X | 1,53 / **1,93** / 3,15 ms | 10/10 |
| (−60, +40) px | 1,51 / 2,19 / 3,02 ms | 10/10 |
| (0, −80) px | 1,93 / 2,88 / 3,40 ms | 10/10 |

Le claim « overlay à jour en 1–2 ms » est **confirmé en horizontal** (moy. 1,93 ms, max 3,15) et
**légèrement optimiste** en diagonale/vertical (moy. 2,2–2,9 ms, max 3,4 ms). CPU total du run :
0,0625 s / 57 s = 0,11 % d'un cœur. Conformément au code (`EVENT_OBJECT_LOCATIONCHANGE` filtré, timer
500 ms + hook ciblé), aucun changement n'a été manqué.

## 6. Cycles ouvert/fermé

### 6.1 Déplier/replier par clic (E, 30 cycles)

- Durée d'un cycle complet : ~153 ms (dont 2 × 60 ms de maintien synthétique du bouton).
- **Latence après relâchement : 6,5 ms au 1er dépliage (première construction du layout), puis
  0,05–0,14 ms** ; repli idem 0,05–0,09 ms. L'interface est mise à jour de façon synchrone
  (`UpdateLayeredWindow` dans le gestionnaire de clic).
- Coût CPU : **0,2812 s pour 30 cycles = 9,375 ms/cycle** (deux rendus complets).
- Mémoire sur 30 cycles : WS +1,62 Mo, WS privé +1,19 Mo, commit +1,39 Mo ; handles +3, GDI et USER
  inchangés (21 / 29) — **pas de fuite de ressources GDI/USER**, croissance mémoire modérée liée au
  rendu (le trim est volontairement sauté tant que l'overlay est affiché).

### 6.2 Détruire/recréer l'overlay (E2 — 5 et 15 cycles)

Riot minimisé puis ramené au premier plan, grâce de disparition 3 500 ms.

- **Disparition** de l'overlay : 3 680–4 125 ms (grâce 3 500 ms + timer de secours ≤ 1 s).
- **Réapparition** : 65–81 ms au total (premier plan 26–53 ms + détection + création + affichage) ;
  dans les logs, détection→affichage = p50 16,7 ms / p90 51,7 ms / max 88 ms sur 171 créations
  (sous-ensemble campagne : p50 14,2 ms, p90 18,1 ms).
- CPU : **32,2–34,4 ms/cycle** (création, rendu, attente, destruction).
- Mémoire : sur 15 cycles, WS **+10,5 Mo (≈0,70 Mo/cycle)**, WS privé +3,4 Mo (≈0,23 Mo/cycle),
  commit +0,2 Mo seulement (≈13 Ko/cycle, plateau), handles +3, GDI/USER/threads stables.
  Sur 5 cycles : +2,45 Mo WS, +1,0 Mo commit. Le working set gagne donc ~0,5–0,7 Mo **par
  destruction/recréation**, mais il est récupéré par le trim suivant (retour à 10–16 Mo une fois
  l'overlay absent, voir §7) : ce n'est pas une fuite non bornée.
- Cause probable : allocations du formulaire + rendu GDI+ à chaque construction, non collectées tant
  que l'overlay est présent (trim explicitement sauté quand `_overlay` existe).

## 7. Démarrage à froid du veilleur (F) et trim mémoire

`--watch` lancé sans overlay (Riot caché), PID neuf.

| Instant | WS | WS privé | Commit (« privé ») | CPU cumulé | Threads |
|---|---:|---:|---:|---:|---:|
| t ≈ 2,07 s | 62,05 Mo | 10,52 Mo | 14,47 Mo | 0,188 s | 15 |
| t ≈ 3,35 s (post-trim) | 10,42 Mo | 2,12 Mo | 15,40 Mo | 0,234 s | 15 |
| t ≈ 13,35 s | 15,48 Mo | 4,17 Mo | 16,31 Mo | 0,281 s | 15 |
| t ≈ 25,35 s | 17,54 Mo | 3,93 Mo | 14,48 Mo | 0,328 s | 13 |

- Séquence log : `Démarrage` → `WatchContext : initialisation` (+143 ms) → tracker démarré
  (+1,4 ms) → trim à **+2,017 s** : « mémoire de travail compactée (working set=4 Mo, privée=16 Mo) ».
- Pic de working set **64,2 Mo** au démarrage, conforme au « ≈ 62,6 Mo avant compactage » des docs ;
  le WS retombe à ~10,4 Mo puis remonte de ~35 Ko/s (jusqu'au seuil de 32 Mo qui déclenche un trim
  silencieux suivant).
- Le trim `GC.Collect` ×2 + `EmptyWorkingSet` réduit le **working set**, pas le commit : sur un
  processus ayant déjà servi (nombreux cycles E2), le commit reste ~33 Mo après trim (observé en W
  propre) alors qu'il est ~15 Mo sur un processus neuf.

## 8. Comparaison avec les chiffres annoncés

Claims recopiés des sources (dist/README.md:94 et :239, docs/validation.fr.md:17, item 23, item 28).

| Claim | Mesure | Verdict |
|---|---|---|
| WS ≈ 10–16 Mo au repos après compactage | 10,4–15,8 Mo immédiatement après trim ; mais remonte ensuite (≈15,4–21,1 Mo à 150 s, seuil de re-trim 32 Mo, max observé 33,4 Mo) | **Confirmé juste après trim, nuancé en usage continu** (fourchette réelle 10–33 Mo ; médiane typique ~12–19 Mo) |
| « privé » ≈ 14–16 Mo | Commit 14,5–16,3 Mo au démarrage/après trim ; ~33 Mo après usage prolongé (cycles overlay) | **Confirmé au démarrage, faux après usage** (le trim ne rend pas le commit) |
| CPU quasi nul ≈ 0,3 % d'un cœur en mesure précise, 0 % dans le Gestionnaire | 0,10–0,24 % d'un cœur en `--watch` (0,007–0,014 % machine) ; 0 % affiché par le Gestionnaire (16 cœurs) | **Confirmé** (même plutôt 0,1–0,2 %) |
| CPU post-compactage ≈ 0,28 % | Voir ci-dessus | Confirmé |
| Trim au-delà de 32 Mo, uniquement sans overlay, première passe à ~2 s puis toutes les 10 s, log unique | Trim mesuré à +2,02 s, log unique, intervalle 10 s, garde `_overlay` ; WS a atteint 33,4 Mo avant re-trim | **Confirmé** |
| Démarrage ≈ 62,6 Mo avant compactage | Pic 64,2 Mo ; à t=2,07 s WS=62,05 Mo | **Confirmé** |
| Suivi de fenêtre 1–2 ms | 1,5–3,4 ms (moy. 1,93 ms horizontal, 2,19–2,88 ms diagonal/vertical) | **Confirmé (horizontal), légèrement optimiste ailleurs** |
| CPU 0 % sur 4 s (validation item 28) | Quantum 15,6 ms : 0,39 %/4 s ; nos fenêtres 150 s donnent 0,01–0,02 % en A/B | **Non probant comme formulation** ; cohérent en ordre de grandeur |
| Overlay à jour / rendu 0,8–4 ms (audit) | 0,05–0,14 ms pour le changement de rect ; rafale interactive ≈7 % cœur | Cohérent |
| Z-order réassertion ≤ 700 ms (mesuré 122 ms), rétention statuts ~5 s | **Non mesurés** dans cette campagne (hors périmètre demandé) | à mesurer si besoin |

Nuance importante : le mode **launcher** (`--launch-riot --ephemeral`, PID trouvé au début de session)
consommait **1,24 % d'un cœur en moyenne sur ~90 min** (76,75 s CPU / 5 400 s) parce qu'il paie en plus
le timer de sortie 1 Hz ; ce mode est transitoire (il se ferme avec le client Riot). Le claim 0,3 %
concerne le mode veilleur `--watch`, qui est bien le mode d'autostart (raccourci Démarrage = `--watch`,
`ShortcutService.cs:26`).

## 9. Vérification indépendante (phase B)

Un second harnais, développé et exécuté **indépendamment** (`tools/perf/verify/IndependentMeasure.ps1`,
`Verify-Probe.ps1` : `Get-Counter` français découverts dynamiquement + `Get-Process`/P/Invoke, aucun
emprunt aux outils du Lead sauf le changement d'état) a re-mesuré W, A et B (120 s chacun, PID 32420)
et ré-analysé le log complet. Détails, protocole et formules : `docs/perf/verification.fr.md`.

| Métrique | Campagne Lead | Vérification indépendante | Verdict |
|---|---:|---:|---|
| CPU W (% cœur) | 0,104 (0,10–0,24) | 0,052 et 0,273 (2 passes) | même ordre de grandeur, **non stationnaire** (4 à 21 quanta) |
| CPU A | 0,031 | 0,052 | concordant à ≈1 quantum près |
| CPU B | 0,021 | 0,052 | ordre de grandeur (écart ≈2 quanta) |
| WS médian W (Mo) | 11,5 | 7,8–9,2 | écart −20/−33 % (WS dérive au fil des trims) |
| WS médian A (Mo) | 31,3–33,7 | 26,1 | écart −16/−22 % (même cause) |
| WS médian B (Mo) | 39,0–39,9 | 29,4 | écart −25 % (même cause) |
| Commit W (Mo) | 32,7–33,3 | 32,7 | concordant |
| Commit A / B (Mo) | 18,5–19,5 | 32,5 | voir explication ci-dessous |
| Handles / GDI / USER | 437–444 / 15-21-21 / 21-29-31 | 437 / 15-21-21 / 21-29-31 | **identiques** |
| Latence log p50 / max (ms) | 17,6 / 88,0 | **16,689 / 88,026** (n=173) | concordant (p50 −5 %) |
| Destruction après minimise | 3,7–4,1 s | 3,57–3,62 s | concordant |
| Création après premier plan | 60–114 ms | 69–70 ms | concordant |
| Expand / collapse (1er cycle) | ≈6,5 ms | 6,49 / 6,56 ms | concordant |

Ce que les écarts enseignent :

- **CPU : quantification.** Le processus ne consomme que des quanta de 15,625 ms ; une moyenne de
  0,02–0,05 % sur 120–150 s représente 2 à 4 quanta. Les écarts relatifs de ±50 % entre passes sont
  attendus et sans signification physique : les valeurs à retenir sont **0,1–0,3 % d'un cœur en W** et
  **≤0,05 % en A/B**, l'ordre de grandeur est confirmé.
- **WS : non stationnarité.** Un même état W mesuré à 12 min d'écart vaut 9,77 Mo puis 8,05 Mo (les
  trims silencieuses toutes les 10 s et la résidence mémoire font dériver la valeur). Les fenêtres de
  la campagne (plus tôt dans la vie du processus, WS plus haut) et celles du vérificateur (plus tard,
  après plusieurs trims) ne sont pas comparables point par point ; les deltas entre états, eux, sont
  cohérents (+~18–21 Mo WS en A et B par rapport à W, dans les deux campagnes).
- **Commit A/B : dérive chronologique, pas divergence de métrique.** Le processus suivi est le même
  (PID 32420) : commit = 14,5 Mo (t+25 s) → 17,3–18,5 (W) → 18,5–19,5 (A/B pendant la campagne) →
  21,8–27,0 (C) → 28,1 (E) → 29–30,4 (E2) → **32,7–33,3 (W propre, +25 min)** → 33,5–33,7 (E2 ×15) →
  32,5 (vérification, +55 min). La mémoire privée validée croît avec l'usage de l'overlay et ne
  redescend jamais (le trim ne libère que le working set) : la valeur de la table A/B correspond au
  début de vie du processus, celle du vérificateur au plateau (~33 Mo). Les deux méthodes concordent
  par ailleurs (≤0,04 % d'écart).
- **Latences : concordance forte** sur la chaîne objectivement mesurable détection → affichage
  (p50 16,7 vs 17,6 ms, max identique, 173 cycles, 0 orphelin). Les latences de déplacement mesurées
  par l'outil du Lead ne sont pas vérifiables indépendamment à la ms (Stopwatch in-process) ; la
  géométrie, elle, est vérifiée : offset overlay−Riot constant (1 482 / 105) sur 30/30 pas, rect
  restauré.

**Ce qui reste non vérifié** : private WS (le harnais indépendant ne fait pas `QueryWorkingSet`) et
démarrage à froid (pas de redémarrage pendant la vérification). Tous les cross-checks du harnais
(cible non instrumentée) sont PASS : WS ≤ 0,11 %, CPU ≤ 1,55 % (hors cas sous le plancher de bruit).

## 10. Répartition interne (pour comprendre le coût)

- En W, ~91–100 % du CPU est porté par le thread UI (tid du message loop) ; CPU surtout **noyau**
  (kernel 0,297 s vs user 0,0625 s en W) : énumérations `EnumWindows`, appels DWM/process.
- 6 timers : tracker 1 Hz (secours), trim 2 s→10 s, exit 1 Hz (launcher seulement), position overlay
  500 ms, outside 120 ms (seulement déplié), statut one-shot. Hooks : tracker (création→position,
  position filtrée) + overlay (position cible + premier plan). Rien de tout cela n'est perceptible
  hors interactions, sauf le timer 1 Hz quand aucune fenêtre Riot n'est trouvée.
- 4 hooks `SetWinEventHook` actifs : coût de livraison négligeable mesuré (≤0,052 % cœur pour la
  sonde elle-même ; 0,07 événement/s machine idle).

## 11. Fichiers de données

- `tools/perf/results/campaign-official-01/` : phases F, W, A, B, C, D, E, E2
  (`*.csv` 1 Hz, `*.json` synthèses, snapshots avant/après, `campaign-summary.json`, `campaign.log`).
- `tools/perf/results/campaign-official-02-wclean/` : W propre (150 s) + sonde.
- `tools/perf/results/campaign-official-02-e2-leak/` : 15 cycles destruction/recréation + snapshots.
- `tools/perf/results/log-overlay-creation-stats-full.json` : 171 créations issues du log (latences).
- `tools/perf/results/campaign-official-01/analysis-official-01.json`, `analyze.py` : agrégats.
- `docs/perf/audit-statique.fr.md` : audit statique du code (timers, hooks, rendu, coûts attendus).
- `docs/perf/verification.fr.md` : vérification indépendante (harnais séparé, `Get-Counter`).

## 12. Reproduire

```powershell
# Campagne complète (états F, W, A, B, C, D, E, E2) — veilleur déjà lancé ou non
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\perf\run\Campaign.ps1 `
  -Phases F,W_watch,A_watch,B_watch,C,D,E,E2 -Probe -Tag ma-campagne

# W propre seul (Riot minimisé, attente trim)
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\perf\run\Campaign.ps1 `
  -Phases W_watch -Probe -Tag w-clean

# 15 cycles destruction/recréation (pente mémoire)
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\perf\run\Campaign.ps1 `
  -Phases E2 -E2Cycles 15 -Tag e2-leak
```

Prérequis : Riot Client présent (ou utilisable via `tools/perf/run/Start-RiotClient.ps1`), machine
inactive, aucune autre mesure en parallèle, écrire dans `tools/perf/results/` (untracked).

## 13. Optimisation « ÷2 » (v1.1.18, 2026-11-11 après-midi)

Objectif : diviser par deux la consommation du veilleur et de l'overlay sans dégrader les latences.
Build mesuré : `src/RiotSwitcher.App/bin/Release/net8.0-windows/RiotSwitch.exe` (version 1.1.18, avant
publication), campagne `official-06` (13:16–13:32 UTC) + comparaisons A/B sous
activité utilisateur réelle (`abactive-new1` / `abactive-old` / `abactive-new2`, 180 s chacun).

### Changements

- **Tracker** : timer de secours 1 s → 2 s ; hooks WinEvent restreints à `EVENT_OBJECT_CREATE..HIDE`
  (au lieu de `CREATE..LOCATIONCHANGE`) + nouveau hook `MINIMIZESTART..MINIMIZEEND` ; filtrage par
  handle connu puis par titre avant tout travail ; coalescence des `Check` ; chemin rapide
  `Inspect(hwnd)` (fenêtre connue = 0 énumération) ; un seul `Scan()` d'`EnumWindows` au lieu de 3
  `Find()` en cascade quand la fenêtre est introuvable.
- **RiotClientWindow** : `Scan()` en une passe (filtre titre bon marché d'abord) + `Inspect()` sans
  énumération ; API `Find`/`FindMinimized`/`FindPresent` conservée.
- **WatchContext** : réutilisation de l'instance d'overlay (`HideOverlay`/`HideAttached` au lieu de
  `Dispose` + recréation) ; `IsRiotClientAlive` en une énumération de process au lieu de deux ;
  trim/exit basés sur `Visible`.
- **OverlayForm** : timer de position 500 ms → 1 s ; tampon de rendu persistant (Bitmap + Graphics
  réutilisés, plus d'allocation par rendu) ; `HideAttached()` ; affichage seulement si masqué.

### Résultats (machine quasi inactive, fenêtres de 147 s, `official-06`)

| État | v1.1.17 (référence) | v1.1.18 (optimisé) | Ratio |
|---|---:|---:|---:|
| W — veilleur `--watch`, sans overlay | 0,106 % d'un cœur (passe propre ; 0,224 % avec activité) | **0,0425 %** | ÷2,5 (÷5,3 vs passe active) |
| A — overlay replié visible | 0,031 % | **0,0106 %** | ÷2,9 |
| B — panneau déplié | 0,021 % (2 quanta) | 0,0425 % (4 quanta) | non significatif (bruit) |
| C — survol + molette (60 s) | 0,495 % (rafale 14,1 % sur 1 s) | **0,247 %** (max 6,3 %) | ÷2,0 |
| D — suivi de la fenêtre Riot | 0,110 % (57 s) | **0,055 %** | ÷2,0 |
| E — déplier/replier (30×) | 9,4 ms CPU/cycle | 13,5 ms/cycle mesuré sous activité utilisateur ; latences identiques (76–77 ms dont 60 ms de maintien de l'outil, rect < 0,4 ms) | non concluant (contamination activité) |
| E2 — disparition/réapparition | destruction/recréation : 3,7–4,1 s, 32–34 ms CPU/cycle, +0,5–0,7 Mo WS/cycle | fenêtre réutilisée : disparition ≈30 ms, retour 73–99 ms, 6,25 ms/cycle, croissance ≈0 | gain majeur |
| Mémoire A / B / C (WS) | 31–34 / 39–40 / 45,5–50,9 Mo | 21–23 / 30,6–31,3 / 39,4–39,9 Mo | −30 % / −20 % / −20 % |
| Démarrage à froid | pic 64,2 Mo, WS 10,4 Mo après trim, commit 15,4 Mo | pic 63,6 Mo, WS 8,8 Mo, commit 15,3 Mo | WS −15 % |
| Latence overlay (à chaud) | 70,8 ms | 67,2 ms | stable |
| Suivi des déplacements | 1,5–3,4 ms | 1,5–3,4 ms | stable |
| Création de l'overlay à froid | ≈50–65 ms | ≈64–68 ms | stable |
| Stimulus extrême (24 fenêtres Bloc-notes en 120 s) | 2,078 % | 0,234 % | ÷8,9 |

### Utilisation réelle (utilisateur actif, A/B alterné 180 s, même activité)

| Métrique | v1.1.17 | v1.1.18 |
|---|---:|---:|
| CPU moyen | 1,89 % d'un cœur (0,118 % machine, max 9,4) | **0,56–0,69 %** (0,035–0,043 %, max 7,8–23) |
| WS médian | 26,4 Mo | 15,9–30,9 Mo |
| Commit médian | 18,7 Mo | 16,9–24,5 Mo |

Soit **÷2,7 à ÷3,4 en usage réel** (le pire cas 0,69 % correspond au processus le plus ancien,
0,56 % à un veilleur fraîchement démarré).

### Limites

- B et E restent sous le bruit de quantification Windows (quantum 15,6 ms) et ont été mesurés pendant
  une session avec fenêtres utilisateur actives ; la mémoire et les latences, elles, ne régressent pas.
- La vérification indépendante du §9 porte sur la v1.1.17 ; la v1.1.18 n'a pas été re-vérifiée
  par ce second harnais.
- Chiffres `abactive-*` : nouvelle machine Windows redémarrée entre les deux campagnes, 16 cœurs, DPI 1.

### Fichiers

- `tools/perf/results/campaign-official-06/` : phases F, W, A, B, C, D, E, E2, `analyze-summary.json`,
  `campaign-summary.json`, CSV/JSON par phase.
- `tools/perf/results/compare/abactive-{new1,old,new2}.{csv,json}` : comparaison A/B sous activité
  réelle (new1 = processus ancien, old = `dist` v1.1.17, new2 = v1.1.18 frais).
- `tools/perf/results/compare/` : mesures préliminaires (`old-noRiot*`, `new-noRiot*`, `ab-*`,
  `diag-v2/v3`).
