# Sonde WinEvent passive — EventProbe (RiotSwitch, campagne de mesure CPU)

Sonde **purement passive** qui compte les événements WinEvent que le veilleur caché
de RiotSwitch reçoit (hook global identique à `src/RiotSwitcher.App/RiotWindowTracker.cs`)
et mesure son **propre coût CPU en GROSS**, ainsi que, en option, le CPU d'un
processus échantillonné (`-SamplerPid`) sur la même chronologie.

Version : EventProbe.ps1 **1.2.0** (Windows PowerShell 5.1, .NET Framework 4.x, C# 5).

---

## Statut (validé le 2026-11-11)

| Point | Statut | Preuve |
|---|---|---|
| Comptage des événements (types, idObject, Check) | **validé** | auto-test positif 60 s : 4 222 événements, 3 partitions cohérentes (`before-fix-*` = ancien run) |
| Coût propre en **GROSS** (même boucle, hooks actifs) | **validé < 0,5 % cœur** sur run ≥ 60 s | 0,26 % à 70 évts/s générés ; 0,052 % au repos |
| Fenêtre de contrôle (même boucle, sans hooks) | **validé ≈ 0 %** | `control = 0,000 %` sur 60 s |
| Callback managé (borne basse) | mesuré | ~1,6–3,1 ns/appel (10 M appels directs) |
| Défaut historique « busy loop » | **corrigé** | avant : 98,698 % GROSS ; cause : signature P/Invoke de `MsgWaitForMultipleObjectsEx` erronée (ERROR_INVALID_PARAMETER 87) |
| Interaction avec RiotSwitch / UI | **aucune** | hook out-of-context + lecture CPU (`OpenProcess` query-only) |

> Les runs de référence sont **≥ 60 s** : la comptabilité CPU des processus Windows
> n'est rafraîchie qu'une fois par tick d'horloge (~15,6 ms). Un run court (8 s) peut
> afficher 0 tick ou 5 ticks pour la même charge et n'est **pas** interprétable.

---

## 1. Fichiers

| Fichier | Rôle |
|---|---|
| `tools/perf/probe/EventProbe.ps1` | point d'entrée ; parse les options, lance la sonde native, calcule les métriques, écrit le résumé, le CSV et le JSON |
| `tools/perf/probe/EventProbeNative.cs` | helper C# 5 compilé à la volée par `Add-Type` : hooks, pompe de messages, compteurs, mesure CPU (aucune dépendance) |
| `tools/perf/probe/_EventGen.ps1` | **auto-test positif** : fenêtre WinForms hors écran déplacée/cachée/réaffichée + événements synthétiques `idObject != 0` |
| `tools/perf/probe/results/` | artefacts de validation (`passive-60s-fake.*`, `selftest-60s-generated.*`, `before-fix-*`) |

Écriture limitée à `tools/perf/probe/` : `src/`, `dist/` et l'application ne sont jamais
modifiés, et **aucune fenêtre n'est touchée** (la fenêtre de l'auto-test est créée hors
écran à `-32000,-32000` avec `SWP_NOACTIVATE`, sans vol de focus).

---

## 2. Mécanisme

### 2.1 Hooks (identiques à l'application)

| Hook | Plage | Flags |
|---|---|---|
| 1 | `EVENT_OBJECT_CREATE` `0x8000` → `EVENT_OBJECT_LOCATIONCHANGE` `0x800B` | `WINEVENT_OUTOFCONTEXT \| WINEVENT_SKIPOWNPROCESS` |
| 2 | `EVENT_SYSTEM_FOREGROUND` `0x0003` | idem |

`SetWinEventHook(eventMin, eventMax, IntPtr.Zero, callback, idProcess=0, idThread=0, flags)`
→ événements de **tout le bureau** (session courante), hors du processus de la sonde
(`SKIPOWNPROCESS`).

### 2.2 Phases de `Run()`

1. **prewarm** ~300 ms : JIT + première entrée dans user32, hors mesure ;
2. **contrôle** (3 s par défaut) : **même boucle de messages, aucun hook installé** →
   coût de la pompe seule (`sel_cpu_control_s`) ;
3. installation des **2 hooks** (échec ⇒ `InvalidOperationException`, exit 2) ;
4. **warmup** (1 s par défaut), compteurs remis à zéro ;
5. **mesure** : pompe bloquante, un `Snapshot()` toutes les `IntervalMs` + snapshot final ;
6. désinstallation des hooks, copie des compteurs, vérifications de cohérence.

### 2.3 Boucle de messages bloquante

```csharp
uint r = MsgWaitForMultipleObjectsEx(0, IntPtr.Zero, waitMs,
                                     QS_ALLINPUT /*0x04FF*/, 0 /*dwFlags*/);
// r == WAIT_TIMEOUT (0x102) => drainer les messages puis recalculer le timeout
while (PeekMessage(out msg, IntPtr.Zero, 0, 0, PM_REMOVE))
{
    TranslateMessage(ref msg);
    DispatchMessage(ref msg);
}
```

Points importants :

* l'ordre des paramètres est `(nCount, pHandles, dwMilliseconds, dwWakeMask, dwFlags)` —
  la signature `(…, bool bAlertable, uint dwWakeMask)` utilisée au départ provoquait
  `ERROR_INVALID_PARAMETER` (87) et une boucle occupée à ~100 % d'un cœur ;
* `TranslateMessage`/`DispatchMessage` sont conservés : sans eux, une partie des
  événements livrés (`idObject != 0`) était perdue dans l'auto-test (498 événements
  au lieu de 937) ;
* le callback managé ne fait **aucune** allocation, aucun `Interlocked` (tout se passe
  sur le thread de la pompe) : il incrémente des `long` et le compteur d'événements
  filtrés qui déclencheraient `Check()`.

### 2.4 Filtrage reproduit (identique à `OnWinEvent` de l'app)

```
if (idObject != 0)            -> compté "idObject != 0", PAS de Check()
if (eventType == 0x800B)      -> compté "LOCATIONCHANGE", PAS de Check()
sinon                         -> compté "Check event" (type != LOCATIONCHANGE et idObject == 0)
```

La partition est vérifiée à la fin : `check + locationchange_idobject0 + idobject_nonzero == total`
(et `type_sum + unknown == total`, `idobject_zero + idobject_nonzero == total`).

---

## 3. Métriques et formules

### 3.1 Comptage

| Métrique | Formule |
|---|---|
| `events_per_s` | `total_events / duration_s` |
| `median` / `max` du débit | médiane / max des `events_delta / window_s` par intervalle |
| `by_type[].per_s`, `pct` | `count / duration_s`, `count / total * 100` |
| `idobject_zero_pct` | `idobject_zero / total * 100` |
| `check_per_s` | `check_events / duration_s` |
| `check_pct_of_idobject0` | `check_events / idobject_zero * 100` |

### 3.2 Coût propre de la sonde

| Champ | Formule |
|---|---|
| `self_cpu_measure_s` | CPU process (kernel+user, `GetProcessTimes`) consommé pendant la fenêtre de mesure |
| `self_cpu_pct_core_gross` | `self_cpu_measure_s / duration_s * 100` (**métrique de référence**) |
| `control_cpu_pct_core` | `self_cpu_control_s / control_duration_s * 100` (pompe seule, sans hooks) |
| `overhead_gross_ok` | `self_cpu_pct_core_gross < 0,5` |
| `overhead_control_ok` | `control_cpu_pct_core < 0,5` |
| `overhead_ok` | **ET** des deux ; la valeur `net` (gross − contrôle au prorata) est **informative seulement** |
| `us_cpu_per_event_including_pump` | `self_cpu_measure_s * 1e6 / total_events` (quantifié par tick ⇒ à interpréter sur ≥ 60 s / milliers d'événements) |
| `callback_ns_per_call` | micro-benchmark : 10 M d'appels directs au callback de comptage, CPU `GetProcessTimes` avant/après ; **borne basse** du coût de hook de l'app |

### 3.3 Échantillonneur (`-SamplerPid` / `-SamplerName`)

Lecture **read-only** de `GetProcessTimes` via `OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION)`
(repli `PROCESS_QUERY_INFORMATION`) : aucun write, aucun `SuspendThread`. Une mesure par
intervalle : `cpu_pct_core = delta_cpu / window_s * 100`. Corrélations :
`r(event_rate, sampler_cpu)` et `r` avec décalage +1 intervalle (le CPU peut suivre
les événements). `r = null` si le CPU est constant.

---

## 4. Utilisation

### 4.1 Run passif de référence (60 s, sans échantillonneur)

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File `
  C:\Users\SuperKnacky\code\RiotSwitch\tools\perf\probe\EventProbe.ps1 `
  -DurationSeconds 60 -IntervalMs 1000 -Label baseline `
  -Csv  C:\Users\SuperKnacky\code\RiotSwitch\tools\perf\probe\results\events-baseline.csv `
  -Json C:\Users\SuperKnacky\code\RiotSwitch\tools\perf\probe\results\events-baseline.json
```

### 4.2 Run conjoint events/s + CPU du veilleur (série corrélée)

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File `
  C:\Users\SuperKnacky\code\RiotSwitch\tools\perf\probe\EventProbe.ps1 `
  -DurationSeconds 60 -IntervalMs 1000 -SamplerPid 30124 -Label watcher-idle `
  -Csv  C:\Users\SuperKnacky\code\RiotSwitch\tools\perf\probe\results\watcher-idle.csv `
  -Json C:\Users\SuperKnacky\code\RiotSwitch\tools\perf\probe\results\watcher-idle.json
```

Variante sans connaître le PID : `-SamplerName RiotSwitch` (prend le processus le plus
récent portant ce nom). Pour approximer `SKIPOWNPROCESS` côté veilleur, ajouter
`-ExcludePid 30124` (approximation : les événements sans fenêtre source ne sont pas
attribuables et restent comptés).

### 4.3 Auto-test positif (obligatoire pour valider la chaîne de mesure)

```powershell
$gen = Start-Process powershell -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass',
  '-File','C:\Users\SuperKnacky\code\RiotSwitch\tools\perf\probe\_EventGen.ps1',
  '-DurationMs','65000' -WindowStyle Hidden -PassThru
Start-Sleep -Milliseconds 1500
powershell -NoProfile -ExecutionPolicy Bypass -File `
  C:\Users\SuperKnacky\code\RiotSwitch\tools\perf\probe\EventProbe.ps1 `
  -DurationSeconds 60 -IntervalMs 5000 -SamplerPid $gen.Id -Label selftest `
  -Csv  C:\Users\SuperKnacky\code\RiotSwitch\tools\perf\probe\results\selftest.csv `
  -Json C:\Users\SuperKnacky\code\RiotSwitch\tools\perf\probe\results\selftest.json
```

`_EventGen.ps1` génère : une fenêtre hors écran déplacée en boucle (LOCATIONCHANGE),
cachée/réaffichée/fermée (HIDE/SHOW/CREATE/DESTROY), plus des événements synthétiques
`NotifyWinEvent()` avec `idObject != 0` (`OBJID_CLIENT`, `OBJID_CARET`, `OBJID_CURSOR`)
pour prouver le comptage de la partition non-window. Aucun événement n'est envoyé à
une fenêtre existante et aucun focus n'est pris.

Critères de succès : `total_events > 0`, `LOCATIONCHANGE` et `SHOW/HIDE > 0`,
`idobject_zero > 0` **et** `idobject_nonzero > 0`, les 3 `consistency` à `true`,
`hooks.object_hook_ok` et `hooks.foreground_hook_ok` à `true`.

---

## 5. Paramètres

| Paramètre | Défaut | Rôle |
|---|---|---|
| `-DurationSeconds` | 60 | fenêtre de mesure avec hooks (≥ 60 conseillé) |
| `-IntervalMs` | 1000 | période de la série (CSV) |
| `-ControlSeconds` | 3 | fenêtre de contrôle **sans hooks**, même boucle |
| `-WarmupSeconds` | 1 | warmup avec hooks, compteurs remis à zéro ensuite |
| `-SamplerPid` | 0 | PID à échantillonner (CPU read-only) |
| `-SamplerName` | `''` | alternative : processus le plus récent avec ce nom |
| `-ExcludePid` | `@()` | PID dont les événements ne sont pas comptés (approx. `SKIPOWNPROCESS`) |
| `-Label` | `probe` | étiquette libre du run |
| `-Csv` / `-Json` | `''` | chemins de sortie (répertoires créés si besoin) |

---

## 6. Sorties

* **stdout** : résumé humain, puis bloc `SUMMARY_JSON` (sans la série), puis chemins des fichiers.
* **CSV** : une ligne par intervalle, encodage ASCII, culture invariante (points décimaux) :
  `idx, iso_utc, elapsed_s, window_s, events_delta, events_cum, events_per_s,
  idobject0_delta, idobject0_per_s, idobject_nonzero_delta, idobject_nonzero_per_s,
  check_delta, check_per_s, locationchange_delta, locationchange_per_s, foreground_delta,
  evt_8000_delta … evt_0003_delta, probe_cpu_ms, probe_cpu_pct_core, probe_us_per_event,
  sampler_valid, sampler_cpu_ms, sampler_cpu_pct_core`
* **JSON** : `meta`, `args`, `counters` (dont `by_type[]`, `consistency`, `hooks`),
  `probe_cost`, `sampler`, `correlation`, `series[]`, `files`.
* **codes de sortie** : `0` succès, `2` hooks impossibles à installer, `1` autre erreur.

---

## 7. Résultats de validation (2026-11-11, hôte 16 cœurs)

Tous les runs sont des runs passifs sur des processus factices (aucun run sur le
veilleur réel n'a été demandé/effectué pendant la mise au point).

### 7.1 Avant correction (boucle occupée) — `results/before-fix-fake.*`

Run 6 s, ancienne version : `total_events = 0`, `self_cpu_measure_s = 5,921875 s`
sur 6 s ⇒ **98,698 % d'un cœur en GROSS** (fenêtre de contrôle ≈ 100 % également).
Cause : signature erronée de `MsgWaitForMultipleObjectsEx` ⇒ `ERROR_INVALID_PARAMETER` (87),
boucle occupée. C'est la preuve du défaut corrigé (artefact conservé).

### 7.2 Après correction — repos du bureau, 60 s — `results/passive-60s-fake.*`

| Métrique | Valeur |
|---|---|
| Événements | 106 (1,767/s ; médiane 0/s ; max 63,2/s) |
| Par type | CREATE 31, DESTROY 36, REORDER 13, LOCATIONCHANGE 26 |
| idObject | ==0 : 106 (100 %), !=0 : 0 |
| Check events | 80 (1,333/s, 75,5 % du total) |
| Cohérence | type_sum / idobject_sum / check_partition = true / true / true |
| Coût propre **GROSS** | **0,052 % d'un cœur** (0,03125 s / 60 s) |
| Contrôle (sans hooks) | 0,000 % |
| Callback managé | 3,125 ns/appel |
| Échantillonneur factice | 0 % (process `Start-Sleep`) |

À faible débit, `us_cpu_per_event` est quantifié par tick et non significatif
(294,8 µs/évt affiché ⇒ artefact de quantification).

### 7.3 Après correction — charge générée 60 s — `results/selftest-60s-generated.*`

Auto-test positif (`_EventGen.ps1`, 65 s), probe 60 s, échantillonneur = générateur :

| Métrique | Valeur |
|---|---|
| Événements | 4 222 (70,362/s ; médiane 71,3/s ; max 72,8/s) |
| Par type | CREATE 181, DESTROY 12, SHOW 263, HIDE 89, REORDER 1, LOCATIONCHANGE 3 676 |
| idObject | ==0 : 3 696 (87,54 %), !=0 : 526 (12,46 %) |
| Check events | 195 (3,25/s, 4,62 % du total, 5,28 % de idObject==0) |
| Cohérence | true / true / true |
| Coût propre **GROSS** | **0,26 % d'un cœur** (0,15625 s / 60 s) — **cible < 0,5 % respectée** |
| Contrôle (sans hooks) | 0,000 % |
| Coût de livraison | **37,0 µs/événement** (gross / événements livrés) |
| Callback managé seul | 3,125 ns/appel (= borne basse du callback, hors livraison) |
| Échantillonneur (générateur) | 2,163 % cœur en moyenne |
| Corrélation | r = 0,06 ; r(lag1) = 0,72 sur 12 intervalles |

### 7.4 Run court 8 s (illustration de la limite de résolution) — `results/selftest-8s-short-window.*`

Même charge ~71,5 évts/s, 8 s : 572 événements, cohérence OK, mais
`gross = 0,977 %` (5 ticks de 15,625 ms). Avec un débit et une charge identiques, le
run de 60 s donne 0,26 % : **un run court ne permet pas de conclure sur l'overhead**.
Seuls les runs ≥ 60 s (≈ 2 000+ événements) sont interprétables.

### 7.5 Synthèse

* pompe bloquante sans hooks : **0 %** sur toutes les fenêtres de contrôle ;
* coût propre mesuré **en GROSS** : 0,052 % au repos, 0,26 % à ~70 évts/s ;
* coût ≈ **37 µs par événement livré** (livraison out-of-context incluse) ; le
  callback managé pur est négligeable (~3 ns) ;
* le coût est **linéaire en débit d'événements** : à ~135 évts/s on a mesuré 0,495 %
  sur 60 s (période chargée du bureau, artefact historique non conservé).

---

## 8. Interprétation pour la campagne

Le CPU du veilleur se décompose approximativement en :

```
CPU_veilleur ≈ N_livrés × c_livraison + N_check × c_check + c_timer_1000ms
```

* `N_livrés` = événements/s mesurés par la sonde (**tous**, y compris ceux que l'app
  filtre immédiatement : `idObject != 0` et `LOCATIONCHANGE`) ;
* `c_livraison` ≈ **37 µs/événement** sur cet hôte (borne basse : même hop user32
  out-of-context que l'app, hors `Check()`) ;
* `N_check` = `check_events` (type != LOCATIONCHANGE et idObject == 0) : chaque
  `Check()` ajoute `BeginInvoke` + `RiotClientWindow.Find()` + logique raise/restore,
  **non mesurés** par la sonde (par construction) ;
* le timer de secours de 1 000 ms et les autres coûts du veilleur ne sont pas dans
  la sonde.

Exemples d'ordre de grandeur : 70 évts/s ⇒ ~2,6 ms de livraison par seconde
(0,26 % d'un cœur) ; 135 évts/s ⇒ ~0,5 % d'un cœur ; au repos (~2 évts/s) ⇒ ~0,05 %.

Conséquence pratique : la sonde est **fiable pour compter** (types, filtrage, débit)
et son propre coût est **< 0,5 % d'un cœur tant que le débit d'événements reste
≲ 130 évts/s sur 60 s**. Au-delà (bureau très animé, curseur en mouvement continu,
chargement d'UI), son coût croît linéairement et elle doit alors être exclue d'une
mesure CPU concurrente (ou lancée dans un run dédié de caractérisation du débit,
sans échantillonnage CPU simultané).

---

## 9. Limites connues

1. **Hook global out-of-context** : la sonde compte les événements de toute la session,
   sans attribution par processus (c'est le comportement du hook de l'app). L'option
   `-ExcludePid` ne fait qu'approximer `SKIPOWNPROCESS`.
2. Les événements sans fenêtre source (`hwnd = 0`, événements système/accessibilité)
   ne sont pas attribuables à un processus mais sont comptés.
3. La livraison out-of-context dépend du bureau actif et de la session ; écran verrouillé,
   bureau non interactif ou session déconnectée ⇒ pas de livraison.
4. **Quantification CPU** : `GetProcessTimes` est rafraîchi par tick (~15,6 ms).
   En dessous de ~30 s ou de ~2 000 événements, le coût propre et `µs/événement`
   sont dominés par la quantification ⇒ utiliser ≥ 60 s.
5. `us_cpu_per_event` ne peut pas descendre sous « un tick / nombre d'événements » :
   ignorer les valeurs aberrantes (ex. 0 tick ⇒ `delivery_below_cpu_resolution_ns`).
6. `callback_ns_per_call` est une **borne basse** : il mesure le corps du callback
   managé, pas le hop user32 ni les traitements de l'application.
7. Les événements synthétiques `NotifyWinEvent` de `_EventGen.ps1` sont **fabriqués**
   (trois objets `idObject != 0` par cycle) : ils servent uniquement à prouver le
   comptage des deux partitions et ne représentent pas une interaction utilisateur.
8. La sonde ne mesure pas la consommation du hook **dans** RiotSwitch, ni `Check()`,
   ni les allocations de l'app (le CPU du veilleur reste à mesurer par le Lead avec
   l'outillage de campagne).
9. Version 1.2.0 validée sur Windows 11 26200 / PowerShell 5.1 ; l'API `MsgWaitForMultipleObjectsEx`
   et les constantes sont stables, mais un autre Windows peut différer.

---

## 10. Conformité / hygiène

* aucun fichier de `src/`, `dist/` ou du produit n'est modifié, aucune recompilation
  de l'application, aucun lancement de l'application ;
* aucune interaction avec les fenêtres existantes : la sonde installe seulement des
  hooks et lit des compteurs CPU (accès « query ») ; `_EventGen.ps1` ne crée que sa
  propre fenêtre hors écran, sans focus ;
* écriture uniquement dans `tools/perf/probe/` ;
* `-SamplerPid` est en lecture seule (`OpenProcess` query-only + `GetProcessTimes`).

---

## 11. Reproduction des runs de validation

```powershell
# 1) repos 60 s
$fake = Start-Process powershell -ArgumentList '-NoProfile','-Command','Start-Sleep 90' -WindowStyle Hidden -PassThru
Start-Sleep -Milliseconds 1200
powershell -NoProfile -ExecutionPolicy Bypass -File tools\perf\probe\EventProbe.ps1 `
  -DurationSeconds 60 -IntervalMs 1000 -SamplerPid $fake.Id -Label passive-60s-fake `
  -Csv tools\perf\probe\results\passive-60s-fake.csv -Json tools\perf\probe\results\passive-60s-fake.json

# 2) auto-test positif 60 s (charge générée)
$gen = Start-Process powershell -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass',
  '-File',(Resolve-Path tools\perf\probe\_EventGen.ps1),'-DurationMs','65000' -WindowStyle Hidden -PassThru
Start-Sleep -Milliseconds 1800
powershell -NoProfile -ExecutionPolicy Bypass -File tools\perf\probe\EventProbe.ps1 `
  -DurationSeconds 60 -IntervalMs 5000 -SamplerPid $gen.Id -Label selftest-60s-generated `
  -Csv tools\perf\probe\results\selftest-60s-generated.csv -Json tools\perf\probe\results\selftest-60s-generated.json
```
