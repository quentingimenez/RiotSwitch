# Vérification indépendante — campagne de performance RiotSwitch (phase B)

- **Date** : 2026-11-11, 02:36–02:55 UTC.
- **Rédacteur** : `verifier` (teammate de vérification indépendante), tâches partagées task-6 (harnais, terminée) et task-7 (phase B).
- **Harnais** : `tools/perf/verify/IndependentMeasure.ps1` et `tools/perf/verify/Verify-Probe.ps1`, version 1.0.0, auto-testés en phase A (voir `tools/perf/verify/README.md`).
- **Environnement** : Windows NT 10.0.26200.0, PowerShell 5.1.26100.9711 Desktop, culture fr-FR, 16 cœurs logiques, machine `SUPERKNACKY`, session silencieuse (aucune autre mesure en parallèle, comme demandé).
- **Cible** : `RiotSwitch.exe` PID **32420**, lancé en `--watch` (démarrage 2026-11-11T02:52:13+01:00), overlay replié visible en 1475,105 (40×40), fenêtre « Riot Client » au premier plan au moment du GO.
- **Indépendance** : CPU/WS/privé/handles via `Get-Counter` (compteurs français découverts dynamiquement) **et** échantillonnage direct `Get-Process`/P/Invoke (`GetGuiResources`), en parallèle, avec cross-check ; latences via le log applicatif et par `EnumWindows` (P/Invoke propre). Aucune métrique n'est reprise des outils du Lead ; `tools/perf/run/OverlayCtl.ps1` n'a servi qu'à **changer d'état** (minimiser / remettre au premier plan / cliquer / déplacer), jamais à mesurer, sauf mention explicite ci-dessous.

> Périmètre strictement respecté : aucune modification de `src/`, `dist/`, `tools/perf/sampler|driver|probe|results|run`, `settings` ; aucun processus Riot/RiotSwitch tué ou redémarré ; une seule mesure à la fois ; état final restitué à l'identique.

---

## 1. Définition des métriques et des formules

| Métrique | Définition utilisée | Formule |
|---|---|---|
| CPU (% d'un cœur) | part d'un cœur logique consommée par le processus cible | `ΔTotalProcessorTime / Δtemps_mural × 100` (direct) ; moyenne des compteurs `\Processus(<inst>)\% temps processeur` / 16 pour l'affichage machine |
| % machine | CPU ramené aux 16 cœurs logiques | `CPU_cœur / logicalCores` |
| WS | working set du processus | `Get-Process.WorkingSet64` ; compteur `Plage de travail` |
| Privé / commit | mémoire privée validée (commit privé) | `Get-Process.PrivateMemorySize64` ; compteur `Octets privés` |
| Private WS | pages résidentes privées (QueryWorkingSet) | **non mesuré par ce harnais** (limite, cf. §8) |
| Handles | handles du processus | `Get-Process.HandleCount` / compteur `Nombre de handles` |
| GDI / USER | objets GDI / USER du processus | `GetGuiResources(OpenProcess)` (GR_GDIOBJECTS=0, GR_USEROBJECTS=1) |
| Statistiques | min / moyenne / médiane / p95 / max / écart-type | sur la série d'échantillons de la fenêtre (1 Hz) |
| Latence « détection → overlay affiché » | délai entre la ligne `Tracker : fenêtre Riot Client détectée …` et la ligne `WatchContext : overlay affiché …` du log | `ShownTs − DetectTs` (horodatages UTC ISO, ticks 100 ns) |

Résolution intrinsèque : la cible ne consomme du CPU que par quanta de planification (15,625 ms) ; sur une fenêtre de 120 s, **1 quantum = 0,013 % d'un cœur** (150 s : 0,0104 %). Les écarts de moyenne inférieurs à ~2 quanta ne sont pas interprétables (cf. §7).

## 2. Protocole effectivement exécuté

1. `Verify-Probe -Mode Analyze` sur `%LOCALAPPDATA%\RiotSwitch\logs\app.log` (dernières 24 h) : 173 cycles complets sur la période 2026-11-10T13:26:55Z → 2026-11-11T02:54:29Z.
2. **W** : `OverlayCtl -Action minimize-riot -TimeoutMs 10000` (changement d'état uniquement) → attente 12 s → `IndependentMeasure -ProcessId 32420 -AllowAppProcess -DurationSec 120 -Tag phaseB-W`. Deuxième passe W2 identique à 02:51 pour tester la reproductibilité.
3. **A** : `OverlayCtl -Action foreground-riot-wait` (déclenchement seulement) → attente 2 s → 120 s de mesure `-Tag phaseB-A`.
4. **B** : `OverlayCtl -Action expand` → 120 s de mesure `-Tag phaseB-B` → `-Action collapse`.
5. **Déplacements** : 3 séries `OverlayCtl -Action move-riot` (10 pas chacune) ; les latences produites par le helper du Lead sont notées mais **classées non indépendantes** ; la géométrie, elle, est vérifiée indépendamment (offset overlay/Riot constant, restauration du rect).
6. Restauration finale de l'état A (overlay replié visible, Riot au premier plan) puis snapshot de contrôle et analyse finale du log.

Les mesures sont sérialisées (aucun `Get-Counter` concurrent, aucun autre script de mesure pendant les fenêtres). Le harnais tourne dans un processus PowerShell distinct de la cible.

## 3. Mesures indépendantes CPU / mémoire / handles / GDI / USER

Séries de 120 échantillons à 1 Hz (120 s), dynamique directe `Get-Process` + compteurs `Get-Counter` collectés en parallèle dans un runspace dédié. `n=120/120` pour chaque état, gigue d'échantillonnage moyenne 0,007 ms (max 0,023 ms). Cross-check direct↔compteurs : premier échantillon exclu (chauffe des compteurs de type taux), 119 échantillons comparés.

| État | CPU min / moy / méd / p95 / max (% cœur) | CPU machine | WS min / moy / méd / max (Mo) | Privé moy (Mo) | Handles | GDI | USER | Threads (moy, min–max) |
|---|---|---|---|---|---|---|---|---|
| **W1** (overlay absent) | 0 / **0,273** / 0 / 1,570 / 7,839 | 0,017 % | 8,09 / 9,77 / 9,20 / 11,44 | 32,68 | 437 | 15 | 21 | 8,08 (8–9) |
| **W2** (overlay absent) | 0 / **0,052** / 0 / 0 / 1,571 | 0,003 % | 7,06 / 8,05 / 7,77 / 9,05 | 31,44 | 437 | 15 | 21 | 8,44 (8–9) |
| **A** (replié visible) | 0 / **0,052** / 0 / 0 / 1,569 | 0,003 % | 25,80 / 26,10 / 26,13 / 26,48 | 32,46 | 437 | 21 | 29 | 8,14 (8–9) |
| **B** (déplié 380×305) | 0 / **0,052** / 0 / 0 / 1,570 | 0,003 % | 29,20 / 29,37 / 29,38 / 29,52 | 32,48 | 437 | 21 | 31 | 8,71 (8–9) |

Cross-check de chaque mesure (moyennes, échantillons 2..120, seuil 5 %) :

| Mesure | Cross-check CPU (direct / compteur, écart) | Cross-check WS (direct / compteur, écart) | Statut |
|---|---|---|---|
| W1 | 0,276 / 0,273 % → 1,21 % | 9,784 / 9,794 Mo → 0,11 % | PASS |
| W2 | — / — (1,49 %) | — (0,05 %) | PASS |
| A | 0,052 / 0,065 % → 19,40 % accepté **plancher de bruit** (0,5 pp) | 26,10 / 26,11 Mo → 0,02 % | PASS |
| B | 0,052 / 0,051 % → 1,55 % | 29,38 / 29,37 Mo → 0,01 % | PASS |

Le cross-check WS est excellent partout (≤ 0,11 %) ; le cross-check CPU est excellent sauf en A où les deux séries valent respectivement 4 et 3 quanta : l'écart relatif est élevé mais l'écart absolu (0,013 pp) est sous le plancher de bruit prévu par le harnais.

Surcoût propre du harnais : 1,03–1,33 % d'un cœur (contre 0,58–0,81 % annoncé pour le sampler du Lead ; notre surcoût est plus élevé car `Get-Counter` est collecté en parallèle). Impact machine : ≤ 0,08 % des 16 cœurs. Le CPU de la cible étant lu par compteurs externes, le harnais ne s'auto-attribue pas de CPU.

## 4. Latences indépendantes mesurées dans le log applicatif

Analyse finale (02:54:32 UTC) : `app.log` 504 382 o, **5 441 lignes, 0 ligne non parsée**, 173 détections / 173 créations / 173 constructions / 173 affichages, **173 cycles complets, 0 orphelin**, 0 abandon.

| Statistique | Valeur (ms) |
|---|---|
| n | 173 |
| min | 7,236 |
| moyenne | 23,865 |
| médiane (p50) | **16,689** |
| p90 | **51,697** |
| p95 | 62,014 |
| max | 88,026 |
| écart-type | 16,788 |

Décomposition moyenne (médiane) : détection → création 1,067 (0,909) ; création → construction 0,950 (0,610) ; construction → affichage **21,848 (15,072)**. Le délai est donc dominé par l'affichage de l'overlay (peinture/mise en place WinForms), la réaction du veilleur (détection → création) étant ~1 ms.

Cycles de la session de vérification : #172 (restauration A à 02:43:56) = **21,131 ms** ; #173 (restauration finale à 02:54:29) = **16,549 ms** ; les cycles 168–171 de la campagne officielle valent 10,963–16,647 ms. Le log a produit exactement 2 nouveaux cycles complets, cohérents avec les 2 remises au premier plan effectuées.

## 5. Latences d'état (changement d'état par l'outil du Lead, mesure croisée)

| Événement | Valeur mesurée | Commentaire |
|---|---|---|
| Destruction de l'overlay après minimisation Riot | **3 615,195 ms** (W1) puis **3 571,44 ms** (W2) | poll 2 ms ; conforme à la fenêtre attendue grâce 3 500 ms + timer de sortie 1 s |
| Création de l'overlay après `foreground-riot-wait` | **69,109 ms** puis **70,363 ms** (dont foreground 36,1 / 41,7 ms) | action → overlay visible |
| Expand (clic synthétique 60 ms) | rect visible après **6,485 ms**, total 85,2 ms | 1er cycle, état replié → déplié (380×305) |
| Collapse | rect visible après **6,56 ms**, total 88,8 ms | 1er cycle, retour 40×40 en 1475,105 |
| `move-riot` (3 séries de 10 pas, SetWindowPos) | latences helper **1,361–2,529 ms** ; `changed_count=10/10` à chaque série ; `restored=true` | **non indépendant** (Stopwatch in-process de l'outil Lead) ; en revanche la géométrie est vérifiée indépendamment : offset `overlay.Left − riot.Left = 1482` et `overlay.Top − riot.Top = 105` **constants sur les 30 pas**, suivi fonctionnel 30/30, rect Riot restauré |

## 6. Comparaison aux chiffres du Lead

Références fournies dans le message GO (campagnes official-01/02, fenêtres 150 s, même PID 32420).

| Métrique | Lead | Vérification indépendante | Écart | Verdict |
|---|---|---|---|---|
| **CPU W** (% cœur) | 0,104 (fourchette 0,10–0,24) | **0,052–0,273** (2 passes : 0,052 / 0,273) | W2 −50 % ; W1 +163 % | **Concordant en ordre de grandeur**, non reproductible au % près (état non stationnaire : 4 à 21 quanta selon la passe ; cf. §7) |
| **CPU A** | 0,0312 (3 quanta / 150 s) | **0,052** (4 quanta / 120 s) | +66 % relatif ; +0,021 pp absolu | **Concordant après prise en compte de la quantification** (3 vs 4 quanta ; écart ≤ 1,3 quantum) |
| **CPU B** | 0,0208 (2 quanta / 150 s) | **0,052** (4 quanta / 120 s) | +151 % relatif ; +0,031 pp (≈ 2 quanta) | **Ordre de grandeur concordant**, écart relatif non conclusif (résolution) |
| **WS médian W** (Mo) | 11,54 (10,41–15,80) | 9,20 (W1) / 7,77 (W2) | −20 % / −33 % | **Écart** (cf. §7 : WS non stationnaire, trims) |
| **WS médian A** (Mo) | 31,27–33,68 | 26,13 | −16 % à −22 % | **Écart** (même cause) |
| **WS médian B** (Mo) | 39,02–39,89 | 29,38 | −25 % | **Écart** (même cause) |
| **Private WS** (Mo) | 3,38–5,85 / 8,70–9,36 / 9,91–10,24 | non mesuré | — | **Non vérifié** (limite du harnais) |
| **Commit W** (Mo) | 32,7–33,3 | 32,68 (W1) / 31,44 (W2) | −1 % / −5 % | **Concordant** |
| **Commit A / B** (Mo) | 18,52–18,96 / 19,22–19,54 | 32,46 / 32,48 | **+71 % / +68 %** | **Écart important, non expliqué** (cf. §7) |
| **Handles** | 437–440 / 430–435 / 437–444 | 437 / 437 / 437 | ≤ 0,7 % | **Concordant** |
| **GDI** | 15 / 21 / 21 | 15 / 21 / 21 | 0 % | **Concordant (exact)** |
| **USER** | 21 / 29 / 31–32 | 21 / 29 / 31 | 0 % | **Concordant (exact)** |
| **Threads** | 8–9 / 8–11 / 8–9 | max 9 / 9 / 9 (moy 8,1–8,7) | — | **Concordant** |
| **Latence p50 détection→affiché** | 17,6 (n=137) | **16,689** (n=173) | −5,2 % | **Concordant** |
| **Latence max détection→affiché** | ~88 | **88,026** (n=173) | +0,03 % | **Concordant** |
| **Création overlay après foreground** | 60–114 | 69,1 / 70,4 | dans la fourchette | **Concordant** |
| **Destruction après minimise** | 3,7–4,1 s | 3,571 / 3,615 s | −2 % à −8 % | **Concordant** (bas de fourchette) |
| **Expand / collapse (1er cycle)** | ≈ 6,5 | 6,485 / 6,56 | ±1 % | **Concordant** |
| **move-riot (latence)** | 1,53–3,40 | 1,36–2,53 (outil Lead) | compatible | **Compatible mais non indépendant** ; suivi fonctionnel 30/30 vérifié |
| **Démarrage à froid** | ~50 ms (7,2–88) | non mesuré | — | **Non vérifié** (pas de redémarrage autorisé) |
| **Surcoût instruments** | sampler 0,58–0,81 % ; probe ≤ 0,052 % | harnais 1,03–1,33 % | — | Harnais plus coûteux (Get-Counter parallèle), sans impact sur la cible mesurée |

## 7. Analyse des écarts — ce qui est réellement reproductible

1. **CPU : la quantification domine.** En régime de veille, la cible consomme quelques quanta par fenêtre (2 à 21 selon l'état et la passe). Nos moyennes A = B = 0,052 % (4 quanta) contre 0,0312 % (3 quanta) et 0,0208 % (2 quanta) chez le Lead : l'écart absolu est de 0,02–0,03 pp, soit ~1–2 quanta. **Conclusion : les CPU W/A/B sont du même ordre de grandeur ; les valeurs ponctuelles à ±50 % ne sont pas un écart de mesure mais l'effet de rafales discrètes.** W est le plus variable (0,052 % puis 0,273 % à 12 min d'intervalle pour le même état) : le CPU de veille est **bursty**, pas stationnaire.
2. **WS : non stationnaire, dominé par les trims.** Notre WS diminue fortement au fil de la session : W1 moyenne 9,77 Mo → W2 moyenne 8,05 Mo (**−18 % en 12 min, même état**), et 26,1 Mo en A, 29,4 Mo en B, contre 31–40 Mo chez le Lead. La mesure elle-même est exacte (cross-check compteurs ≤ 0,11 %) : c'est l'**état mémoire de l'application qui dérive** (compactions/trims documentés dans le log — 12 lignes « mémoire de travail compactée » ; page residency). Les chiffres Lead (campagne antérieure) et les nôtres (session plus tardive, ~1 h d'uptime) ne sont donc pas comparables point par point.
3. **Commit A/B : discordance non expliquée.** Nos deux méthodes concordent à 0,04 % sur le privé (Get-Process `PrivateMemorySize64` ≡ compteur « Octets privés »), et le commit W concorde avec le Lead (32,5–32,7 vs 32,7–33,3 Mo). Mais en A/B le Lead relève 18,5–19,5 Mo alors que nous mesurons 32,46–32,48 Mo de façon stable (et identique en W). Un écart de ~14 Mo ne peut pas être créé par l'ouverture du panneau (bitmap ~0,5 Mo) : il s'agit soit d'une compaction/GC entre les deux campagnes, soit d'une définition différente de la métrique « commit » côté Lead (`PagefileUsage`/`PrivateMemorySize64`/`WorkingSet` privé). **À trancher par le Lead ; en l'état le commit A/B n'est pas reproductible.**
4. **Métriques « structurelles » fiables.** Handles (437 constant), GDI (15/21/21), USER (21/29/31) et nombre de threads concordent exactement avec le Lead : ces valeurs sont stables et notre harnais les recoupe par P/Invoke sans dépendre des outils du Lead.
5. **Latences : très bon accord.** La chaîne « détection → overlay affiché » est un indicateur objectif et indépendant : p50 16,7 ms contre 17,6 ms (−5 %), max identique (88,0 ms), sur 173 cycles et 0 non parsé. Destruction après minimise (3,57–3,62 s) et création après foreground (69–70 ms) tombent dans les fourchettes Lead. Les latences `move-riot` et expand/collapse ne sont **pas** vérifiables indépendamment à l'échelle de la ms depuis un harnais hors processus ; seule la géométrie (offset constant, restauration) l'est, et elle concorde.

## 8. Limites

- **Private WS non mesuré** : le harnais ne fait pas `QueryWorkingSet` ; le poste « private WS » du tableau comparatif reste non vérifié.
- **Cold start non mesuré** : interdit de redémarrer le veilleur pendant la phase B ; seule la latence courante du log est vérifiée.
- **move-riot / expand / collapse millisecondes** : déclenchés par l'outil du Lead ; seule la géométrie et le suivi fonctionnel sont indépendants. Le « clic » du B a été effectué par `OverlayCtl -Action expand` (driver du Lead), comme prévu au protocole (le driver sert à changer d'état, pas à mesurer).
- **WS/commit dépendent de l'historique** de la session (trims, GC) : une comparaison rigoureuse exigerait des fenêtres synchronisées, un état mémoire de référence identique, ou une mesure par deltas.
- **Échantillonnage 1 Hz** : les rafales infra-seconde ne sont vues que via le pic (max/p95) ; le CPU moyen fiable, mais la variance élevée rend les petites différences non conclusives.
- **Mesure en session unique** : pas de répétition des états A/B (une seule fenêtre chacun) ; W a été mesuré deux fois, ce qui a suffi à révéler la non-stationnarité.
- **Culture** : artefacts CSV/JSON en culture invariante (décimales à point) ; ce document est en français (virgule décimale).
- Le harnais ajoute ~1,2 % d'un cœur de charge pendant la mesure ; les états mesurés restent du même ordre que ceux du Lead, mais la charge système est un facteur d'incertitude supplémentaire (la cible n'est pas instrumentée in-process, donc pas d'auto-inflation du CPU mesuré).

## 9. Restitution d'état (vérifiée)

État final identique à l'état initial du GO : overlay `RiotSwitch` **visible, replié, 40×40 en 1475,105**, `RiotSwitch` PID 32420, fenêtre « Riot Client » au premier plan (rect −7,0,1552×872 ; la largeur diffère de 7 px de l'instant initial −7,0,1545×872, effet du cycle minimise/restauration, position inchangée). `Verify-Probe -Mode Snapshot` final : verdict **PASS** (1 overlay + 1 client Riot). Aucun panneau déplié laissé ouvert, `settings` non modifié, aucun processus tué/redémarré, aucun fichier écrit hors `tools/perf/verify/` et `docs/perf/verification.fr.md`.

## 10. Reproductibilité (commandes exactes)

```powershell
# 1) Latences depuis le log (indépendant)
powershell -NoProfile -ExecutionPolicy Bypass -File tools\perf\verify\Verify-Probe.ps1 -Mode Analyze -Tag phaseB-log-final

# 2) État W : changer d'état avec l'outil du Lead, puis mesurer 120 s
powershell -NoProfile -ExecutionPolicy Bypass -File tools\perf\run\OverlayCtl.ps1 -Action minimize-riot -TimeoutMs 10000
Start-Sleep -Seconds 12
powershell -NoProfile -ExecutionPolicy Bypass -File tools\perf\verify\IndependentMeasure.ps1 -ProcessId <PID> -AllowAppProcess -DurationSec 120 -Tag phaseB-W

# 3) État A
powershell -NoProfile -ExecutionPolicy Bypass -File tools\perf\run\OverlayCtl.ps1 -Action foreground-riot-wait -TimeoutMs 5000
Start-Sleep -Seconds 2
powershell -NoProfile -ExecutionPolicy Bypass -File tools\perf\verify\IndependentMeasure.ps1 -ProcessId <PID> -AllowAppProcess -DurationSec 120 -Tag phaseB-A

# 4) État B (le clic du driver ne sert qu'à changer d'état)
powershell -NoProfile -ExecutionPolicy Bypass -File tools\perf\run\OverlayCtl.ps1 -Action expand
powershell -NoProfile -ExecutionPolicy Bypass -File tools\perf\verify\IndependentMeasure.ps1 -ProcessId <PID> -AllowAppProcess -DurationSec 120 -Tag phaseB-B
powershell -NoProfile -ExecutionPolicy Bypass -File tools\perf\run\OverlayCtl.ps1 -Action collapse
```

## 11. Artefacts

`tools/perf/verify/results/` (produits pendant la phase B) :

- `independent-measure-20261111-023854-phaseB-W{-direct.csv,-counters.csv,.json}`
- `independent-measure-20261111-024421-phaseB-A{…}` ; `independent-measure-20261111-024733-phaseB-B{…}` ; `independent-measure-20261111-025133-phaseB-W2{…}`
- `verify-probe-20261111-023657-phaseB-log{-pairs.csv,.json}` (analyse initiale, 171 cycles) ; `verify-probe-20261111-025432-phaseB-log-final{-pairs.csv,.json}` (analyse finale, 173 cycles)
- `verify-probe-snapshot-*phaseB-{W-pre,A-pre,B-pre,move-pre,move-post,W2-pre,final}{.csv,.json}`

## Verdict global

- **Reproductible** : handles, GDI, USER, threads (identiques) ; latences log détection→affiché (p50 −5 %, max identique, n=173) ; création après foreground, destruction après minimise, expand/collapse 1er cycle ; ordre de grandeur du CPU W/A/B ; commit en état W.
- **Non reproductible / écart** : WS médian dans tous les états (−16 % à −33 %, expliqué par la non-stationnarité mémoire/trims) ; commit en A/B (+68 % à +71 %, divergence de métrique ou d'état mémoire à trancher) ; private WS et cold start non vérifiés.
- **Conclusion** : les chiffres du Lead sont **globalement corroborés** pour le CPU (à la résolution des quanta), les ressources structurelles et les latences ; les valeurs mémoire (WS/commit) ne sont **pas directement comparables** entre les deux campagnes et nécessitent une méthodologie synchronisée (même état mémoire de référence, ou deltas). Aucune preuve de sous- ou sur-estimation systématique des instruments n'a été trouvée : tous nos cross-checks indépendants sont PASS (écarts ≤ 0,11 % sur WS, ≤ 1,55 % sur CPU hors cas plancher-de-bruit).
