# Driver de campagne — overlay RiotSwitch

Driver PowerShell de test et de mesure pour l'overlay WinForms de **RiotSwitch**.
Il sert de **méthode indépendante de vérification** des clics, des états de l'overlay
et des latences de suivi (à comparer aux mesures de l'outil `OverlayCtl` du Lead).

> Statut : livré, testé en lecture seule (`discover`, `state`, `wait-overlay`).
> Les actions interactives (`foreground-riot`, `click`, `expand`, `collapse`, `toggle`,
> `move-riot`, `hover`, `wheel`, `restore`) sont implémentées mais **ne doivent être
> exécutées que pendant la campagne**, après autorisation explicite du Lead.

---

## 1. Périmètre et sécurité

- Écrit uniquement dans `tools/perf/driver/` (script, `README.md`, `.state/`, `logs/`).
- **Ne modifie jamais** `src/`, `dist/`, ni la configuration RiotSwitch (lecture seule
  de `%LOCALAPPDATA%\RiotSwitch\settings.json` et `accounts.json`).
- **Ne compile pas, ne tue aucun processus** (ni Riot Client, ni RiotSwitch).
- Toutes les interactions sont des **messages Windows synthétiques** (`SendMessage`) :
  le curseur physique n'est pas déplacé, le focus clavier n'est pas volé. Les
  `WM_MOUSEMOVE` synthétiques ne peuvent pas déclencher de drag (le code de l'overlay
  vérifie `Control.MouseButtons`), et `CheckOutsideClick` ne peut pas fermer l'overlay
  (il exige un `VK_LBUTTON` physiquement enfoncé).
- Toute action interactive est **bloquée par défaut** : elle exige `-AllowInteraction`.
- `click -Target footer:0` (ajout/bascule de compte, écriture du coffre de comptes)
  exige **en plus** `-Force`. Le driver ne peut pas annuler cette action.
- `restore` est fourni pour remettre la fenêtre Riot et l'overlay dans l'état de
  référence. `move-riot` restaure aussi le rect Riot dans son bloc `finally`.

> Attention : ne pas lancer d'action interactive pendant que le Lead exécute ses
> propres tests (les deux outils déplaceraient la même fenêtre).

---

## 2. Prérequis / environnement de référence

- Windows 11, Windows PowerShell 5.1 (`powershell.exe`), processus 64 bits.
- `RiotSwitch.exe` démarré ; fenêtre overlay créée uniquement quand la fenêtre
  **Riot Client** est visible, non minimisée (critères du tracker RiotSwitch :
  titre exact `Riot Client`, processus `Riot Client`, non iconique, non cloaked,
  rect ≥ 1000×700, topmost exclu si < 1400×800).
- Riot Client : fenêtre `Chrome_WidgetWin_1` ~1552×872 sur la machine de référence,
  écran 1920×1080 à 96 DPI (scale = 1.0). Le driver gère néanmoins toute échelle
  DPI = `clamp(GetDpiForWindow(Riot)/96, 1.0, 2.5)`.
- Le driver lit le DPI via la fenêtre Riot Client (même calcul que l'application).

Si Riot Client est minimisé : `discover` retourne `exit 2` avec
`error.code = "riot_window_not_ready"` et `error.details.rejectionReasons = ["minimized"]`.
C'est normal : l'application dispose l'overlay dans cet état. Utiliser
`foreground-riot` (campagne) pour restaurer la fenêtre et laisser l'overlay réapparaître.

---

## 3. Fichiers

```
tools/perf/driver/
├─ riotswitch-driver.ps1     # driver complet (P/Invoke Add-Type + logique PS)
├─ README.md                 # ce document
├─ .state/
│  └─ baseline.json          # état de référence (rect Riot, overlay, pin, foreground)
└─ logs/
   └─ driver.jsonl           # journal JSONL d'une ligne par invocation (append)
```

`baseline.json` est capturé automatiquement avant la première action interactive
(si absent), ou explicitement avec `state -SaveBaseline`, ou après `foreground-riot`.
`restore` s'appuie dessus pour replacer la fenêtre Riot. Si le fichier est absent,
`restore` fait une restauration « au mieux » (dé-minimisation + re-collapse) et émet
un avertissement `baseline_missing_best_effort_restore`.

---

## 4. Démarrage rapide

```powershell
$driver = 'C:\Users\SuperKnacky\code\RiotSwitch\tools\perf\driver\riotswitch-driver.ps1'
powershell -NoProfile -ExecutionPolicy Bypass -File $driver -Action discover
```

Forcer l'encodage de sortie si besoin de lire du JSON accentué :

```powershell
[Console]::OutputEncoding = [Text.Encoding]::UTF8
```

Toutes les commandes renvoient **un seul objet JSON sur stdout** et un code de sortie
`0` (succès) ou `2` (échec). Le détail des mesures est dans `result`, l'enveloppe
commune dans le reste du document.

Exemples de campagne :

```powershell
# Phase 1 — lecture seule
-File $driver -Action discover
-File $driver -Action state
-File $driver -Action state -SaveBaseline

# Phase 2 — campagne (autorisation Lead requise)
-File $driver -Action foreground-riot -AllowInteraction
-File $driver -Action click -Target collapsed -AllowInteraction
-File $driver -Action click -Target close -AllowInteraction
-File $driver -Action expand -AllowInteraction
-File $driver -Action collapse -AllowInteraction
-File $driver -Action toggle -AllowInteraction
-File $driver -Action move-riot -Dx 120 -Dy 0 -Steps 12 -AllowInteraction
-File $driver -Action hover -Target header -Count 20 -IntervalMs 20 -AllowInteraction
-File $driver -Action wheel -Delta -120 -Count 20 -IntervalMs 20 -AllowInteraction
-File $driver -Action restore -AllowInteraction
```

---

## 5. Actions

| Action | Flags requis | Paramètres | Effet / mesures |
|---|---|---|---|
| `discover` | — | — | Lecture seule : fenêtres Riot/overlay, rects, DPI, scale, état overlay, classification. `exit 2` si Riot ou overlay introuvable. |
| `state` | — | `-SaveBaseline` (option) | `discover` + diagnostic d'état (`result.diagnosis`) + mapping des cibles de clic + baseline. Ne touche à rien sans `-SaveBaseline`. |
| `wait-overlay` | — | `-TimeoutMs` (défaut 3000) | Attend l'apparition de la fenêtre overlay visible ; retourne `result.elapsedMs`. |
| `foreground-riot` | `-AllowInteraction` | `-TimeoutMs` (défaut 3000) | Restaure Riot si minimisé (`SW_RESTORE`), `ForceForeground` (avec fallback `AttachThreadInput`), attend l'overlay. Retourne latences `showWindow/foreground/overlayAppear` (ms). Émet `overlay_state_after_foreground_*` si l'overlay n'est pas replié. |
| `click` | `-AllowInteraction` (+ `-Force` pour `footer:0`) | `-Target`, `-PressMs` (défaut 15) | Clic synthétique down/up. Cibles : `collapsed`, `close`, `pin`, `settings`, `header`, `footer:0`, `footer:1`, `footer:2`. Vérifie la transition attendue (expand/collapse, écriture `overlayPinned`, ouverture du dialogue Paramètres). |
| `expand` | `-AllowInteraction` | `-PressMs` | Clic sur le bouton replié 40 DIP (centre 20,20) ; attend l'état `expanded`. |
| `collapse` | `-AllowInteraction` | `-PressMs` | Clic sur CloseRect ; attend l'état `collapsed`. |
| `toggle` | `-AllowInteraction` | `-PressMs` | `expand` si replié, `collapse` si déplié. |
| `move-riot` | `-AllowInteraction` | `-Dx`, `-Dy`, `-Steps` (défaut 20) | Déplace Riot par pas de `SetWindowPos` (SWP_NOSIZE\|NOZORDER\|NOACTIVATE), mesure pour chaque pas la latence de suivi de l'overlay (poll QPC, tolérance ±2 px), puis **restaure** le rect Riot dans `finally`. |
| `hover` | `-AllowInteraction` | `-Target` (défaut : `header` si déplié, `collapsed` si replié), `-Count` (défaut 1), `-IntervalMs` (défaut 20) | Envoie `-Count` `WM_MOUSEMOVE` au point cible (cibles ci-dessus + `row:0`..`row:4`, hover uniquement, jamais de clic), puis `WM_MOUSELEAVE`. Latences par message + stats + durées. |
| `wheel` | `-AllowInteraction` | `-Delta` (défaut −120), `-Count`, `-IntervalMs` | Envoie `-Count` `WM_MOUSEWHEEL` au centre client de l'overlay (coordonnées écran dans lParam). Inerte si ≤ 5 comptes (`result.inert = true`, avertissement). |
| `restore` | `-AllowInteraction` | `-RestorePin`, `-RestoreForeground`, `-SkipSettingsClose` | Séquence : ferme le dialogue Paramètres éventuel (`WM_CLOSE`), restaure `overlayPinned` si `-RestorePin`, restaure le rect Riot de la baseline (dé-minimise si besoin), vérifie que l'overlay réapparaît, force `collapsed`, éventuellement restaure la fenêtre au premier plan, puis vérifie (`riotRectMatchesBaseline`, `overlayCollapsed`, `anchorMatches`). |

Options globales :

| Option | Effet |
|---|---|
| `-AllowInteraction` | Autorise les actions interactives (sinon `exit 2`, code `interaction_not_allowed`). |
| `-Force` | Requis en plus pour `click -Target footer:0`. |
| `-PressMs` | Durée d'appui entre down et up (défaut 15 ms) ; `0` = pas d'attente. |
| `-TimeoutMs` | Timeouts des attentes (borné 50..60000). |
| `-RestorePin` / `-RestoreForeground` | Sous-options de `restore`. |
| `-SkipSettingsClose` | `restore` ne ferme pas le dialogue Paramètres (déconseillé). |
| `-NoLog` | N'écrit pas la ligne JSONL. |

Le point de clic est exprimé en **coordonnées client de la fenêtre overlay**
(`WM_MOUSEMOVE`/`WM_LBUTTONDOWN`/`WM_LBUTTONUP` prennent des coordonnées client) ;
`WM_MOUSEWHEEL` prend des **coordonnées écran**.

---

## 6. Schéma JSON de sortie

Une ligne JSON par invocation, ASCII sûr (caractères non ASCII échappés `\uXXXX`),
décimaux au **point** (culture invariante), jamais de virgule décimale.
Toutes les durées sont en **millisecondes**, mesurées via QPC
(`Stopwatch.GetTimestamp()`, `timing.qpc.frequency`).

Enveloppe commune :

```jsonc
{
  "schema": "riotswitch.perf.driver/1",
  "action": "discover",                // action demandée
  "ok": true,                           // true => exit 0, false => exit 2
  "exitCode": 0,
  "startedUtc": "2026-11-11T00:58:18.4025271Z",
  "finishedUtc": "2026-11-11T00:58:18.4657288Z",
  "timing": {
    "processStartupMs": 93.187,         // démarrage processus -> P/Invoke prêt
    "actionMs": 370.0,                  // dispatch de l'action
    "totalMs": 463.1,
    "qpc": { "frequency": 10000000, "start": 449444316087, "end": 449449267027, "actionStart": 449449117030 }
  },
  "allowInteraction": false,
  "host": { "pid": 29228, "powershell": "5.1.26100.9711", "os": "Microsoft Windows NT 10.0.26200.0", "is64": true },

  "windows": {
    "riot":    { /* voir snapshot fenêtre */ } ,
    "riotCandidates": [ /* ... */ ],
    "overlay": { /* snapshot fenêtre overlay + layered/toolWindow/noActivate */ },
    "overlayCandidates": [ /* ... */ ]
  },
  "windowsSummary": {
    "riotHwnd": "0x1C08DC", "riotIconic": false,
    "overlayHwnd": "0x1600974", "overlayVisible": true,
    "overlayState": "collapsed",         // absent | hidden | collapsed | expanded | unknown
    "scale": 1.0, "scaleSource": "riot_client_dpi",
    "overlayExpectation": "overlay_visible"
  },
  "ready": true,                         // Riot prêt ET overlay visible
  "classification": {
    "state": "expanded",
    "widthDip": 380.0, "heightDip": 305.0,
    "accountRows": 3, "accountCountFromVault": 3,
    "statusBlockDip": 0.0, "statusLines": 0,
    "footerYDip": 256.0, "expectedHeightDip": 305.0, "residualDip": 0.0,
    "confidence": "exact",               // exact | approx | low | none
    "heightCandidates": [ /* top 3 de l'énumération n×statut */ ],
    "clickTargets": {
      "close":    { "target": "close", "pointDip": {"x":349,"y":31}, "rectDip": {"x":335,"y":17,"w":28,"h":28}, "pointPx": {"x":349,"y":31}, "effect": "...", "expects": "collapsed", "requiresForce": false, "notes": "..." },
      "pin":      { /* centre DIP (319,31), rect (305,17,28,28) */ },
      "header":   { /* centre DIP (190,31) */ },
      "settings": { /* centre DIP (190, footerY+18), rect (135, footerY, 110, 36) */ },
      "footer:0": { /* centre DIP (72,  footerY+18), requiresForce: true */ },
      "footer:1": { /* centre DIP (190, footerY+18) */ },
      "footer:2": { /* centre DIP (308, footerY+18) */ }
    },
    "anchor": {
      "source": "settings",              // settings | inferred
      "offsetRightDip": 30.0, "offsetTopDip": 105.0,
      "inferredOffsets": { "rightDip": 30.0, "topDip": 105.0 },
      "expected": { "x": 1986, "y": 393, "widthPx": 40, "heightPx": 40 },
      "deviationPx": { "x": 0, "y": 0 },
      "clamped": { "x": false, "y": false },
      "marginPx": 8, "matches": true
    }
  },

  "settings": { "path": "%LOCALAPPDATA%\\RiotSwitch\\settings.json", "readOk": true, "schemaVersion": 1,
                "overlayPinned": true, "overlayOffsetRightDip": 30, "overlayOffsetTopDip": 105,
                "overlayPositionSet": false, "error": null },
  "accounts": { "path": "%LOCALAPPDATA%\\RiotSwitch\\accounts.json", "readOk": true, "count": 3, "error": null },
  "baseline": { "exists": true, "path": "...\\tools\\perf\\driver\\.state\\baseline.json",
                "savedUtc": "...", "source": "manual-state", "data": { /* contenu du fichier */ }, "error": null },

  "result": { /* dépend de l'action, voir ci-dessous */ },
  "warnings": ["..."],                   // codes stables, ex. baseline_auto_captured...
  "error": null                          // { "code": "...", "message": "...", "details": ... } si ok=false
}
```

Snapshot fenêtre (`windows.riot`, `windows.overlay`, entrées de `*Candidates`) :

```jsonc
{ "hwnd": "0x1C08DC", "pid": 23544, "process": "Riot Client", "title": "Riot Client",
  "class": "Chrome_WidgetWin_1", "valid": true, "visible": true, "iconic": false,
  "zoomed": false, "enabled": true, "cloaked": false, "ownerHwnd": "0x0",
  "rect": { "x": 504, "y": 288, "w": 1552, "h": 872 },
  "client": { "w": 1536, "h": 864 },
  "clientOriginScreen": { "x": 512, "y": 288 },
  "dpi": 96, "scale": 1.0, "exStyle": "0x00200100",
  "layered": false, "toolWindow": false, "noActivate": false, "topmost": false,
  "appCriteriaOk": true, "rejectionReasons": [], "lenientTitleMatch": true }
```

En cas d'échec (`exit 2`) : `ok=false`, `exitCode=2` et

```jsonc
"error": { "code": "interaction_not_allowed", "message": "...", "details": { ... } }
```

Codes d'erreur : `invalid_args`, `interaction_not_allowed`, `force_required`,
`riot_window_not_found`, `riot_window_not_ready`, `riot_restore_timeout`,
`overlay_not_found`, `overlay_timeout`, `overlay_state_unknown`,
`transition_not_observed`, `invalid_state`, `invalid_target`,
`click_point_outside_overlay`, `baseline_capture_failed`, `native_layer_failed`,
`internal_error`.

### `result` par action

- `discover` : `{ ready, riotHwnd, overlayHwnd, overlayState, scale, scaleSource, note }`
- `state` : `{ ready, riotReady, overlayVisible, diagnosis{expectation,explanation,hint,...}, clickTargets, anchor, classificationWarnings, baseline, settingsReadOnly, accountsReadOnly, [baselineSaved] }`
- `wait-overlay` : `{ found, elapsedMs, overlayHwnd, overlayState, classification }`
- `foreground-riot` : `{ alreadyForeground, restoreNeeded, latencies{showWindowRestoreCallMs,restoreFromMinimizedMs,foregroundCallMs,foregroundObservedMs,overlayAppearMs}, riot, overlay, anchor, baseline }`
- `click` : `{ target, performed, pointDip, pointPx, latencies{moveMs,downMs,upMs,upTimedOut,pressHoldMs}, transition{expected,observed,verified,elapsedMs[,settingsDialog]}, pre, post, settingsAfter[, prePinned] }`
- `expand` / `collapse` : `{ performed, alreadyExpanded|alreadyCollapsed, latencies, transition{expected,observed,elapsedMs}, post }`
- `toggle` : `{ direction, performed, latencies, transition, post }`
- `move-riot` :
  ```jsonc
  { "move": { "dx": 120, "dy": 0, "steps": 12, "from": {"x":504,"y":288}, "to": {"x":624,"y":288} },
    "offsets": { "rightDip": 30, "topDip": 105, "source": "settings", "inferred": {...}, "settings": {...} },
    "panelSizePx": { "w": 40, "h": 40 },
    "overlayStateAtStart": "collapsed",
    "tracking": { "steps": 12, "detected": 12, "withinTolerance": true,
                  "latencyMs": { "count": 12, "min": 1.4, "mean": 1.6, "median": 1.55, "max": 1.9 },
                  "maxAbsResidualPx": 2, "pollTimeoutMs": 150 },
    "steps": [ { "index": 1, "riotX": 514, "riotY": 288, "moveCallOk": true, "moveCallMs": 0.2,
                 "overlayDetected": true, "detectionMs": 1.43,
                 "expectedOverlay": {"x":1996,"y":393,"clampedX":false,"clampedY":false},
                 "actualOverlay": {"x":1996,"y":393},
                 "residualPx": {"x":0,"y":0} }, /* ... */ ],
    "restore": { "riotTarget": {"x":504,"y":288}, "moveCallOk": true, "moveCallMs": 0.3,
                 "overlayBack": true, "overlayBackMs": 1.2, "riotRectRestored": true, "overlayRect": {...} } }
  ```
- `hover` : `{ target, rowIndex, pointDip, pointPx, countSent, intervalRequestedMs, latenciesMs[], latencyStats{count,min,mean,median,max}, gapStats, cleanupMs, totalDurationMs, post }`
- `wheel` : `{ delta, countSent, intervalRequestedMs, inert, accountCount, screenPoint{x,y}, latenciesMs[], latencyStats, gapStats, totalDurationMs, post }`
- `restore` : `{ baselineAvailable, baselinePath, baselineSavedUtc, steps[], final{riot,overlay,overlayVisible,foreground}, verified, riotRectMatchesBaseline, overlayCollapsed, anchorMatches }`

---

## 7. Mapping des cibles de clic (DIP → pixels client overlay)

Constantes issues de `src/RiotSwitcher.App/OverlayForm.cs` (ne pas modifier `src/`).
Coordonnées **DIP** ; conversion `px = round(DIP × scale)` avec
`scale = clamp(GetDpiForWindow(Riot)/96, 1.0, 2.5)` (scale = 1.0 à 96 DPI).

| Cible | Rect DIP (x,y,w,h) | Centre DIP | Remarque |
|---|---|---|---|
| `collapsed` | (0, 0, 40, 40) | **(20, 20)** | Bouton replié ; toute la surface 40×40 est cliquable. Down+up sans mouvement → `Expand()`. |
| `close` | (335, 17, 28, 28) | **(349, 31)** | CloseRect ; up dans le rect → `Collapse()`. |
| `pin` | (305, 17, 28, 28) | **(319, 31)** | PinRect ; up → `TogglePin()` (écrit `overlayPinned` dans settings.json, statut transitoire +24/40 DIP pendant 5 s). |
| `header` | (17, 11, 286, 40) | **(190, 31)** | Zone header sûre (hors boutons) ; up sans mouvement → sauvegarde des settings, pas de changement visuel. |
| `footer:0` | (17, footerY, 110, 36) | **(72, footerY+18)** | Bouton « Ajouter » → `CaptureCurrent()` ; **destructif/coffre**, exige `-Force`. |
| `footer:1` / `settings` | (135, footerY, 110, 36) | **(190, footerY+18)** | Bouton « Paramètres » → dialogue modal `RiotSwitch — Paramètres`. |
| `footer:2` | (253, footerY, 110, 36) | **(308, footerY+18)** | Bouton « Actualiser » → `ReloadData(update:true)`. |
| `row:0..4` | (17, 92+52·i, 346, 48) | (190, 92+52·i+24) | **Hover uniquement** : un clic changerait de compte Riot. Jamais utilisé par `click`. |

`footerY` (DIP) = `92 + listHeight + 12`, avec
`listHeight = 64` si 0 compte, sinon `n×48 + (n−1)×4` (`n = min(comptes, 5)`).
Donc `footerY = 168` (0 compte), **152 / 204 / 256 / 308 / 360** (1..5 comptes).
La hauteur totale du panneau déplié (DIP) = `footerY + 36 + statusBlock + 12 + 1`,
`statusBlock = 0` ou `8 + statusLines×16` (24 pour 1 ligne, 40 pour 2 lignes) :
- 0 compte : **217** ; 1 compte : **201** ; 3 comptes : **305** ; 5 comptes : **409** ;
- + statut 2 lignes : +40 DIP (ex. 5 comptes + statut = **449**).

Hauteurs **attendues** avec le coffre de référence (3 comptes, statut inactif) :
panneau déplié = **305 DIP**, `footerY = 256` ; le clic replié 40×40 = 40 DIP.

Le driver ne clique **jamais** un footer sans avoir validé la hauteur mesurée :
la classification énumère `n = 0..5 × statusBlock ∈ {0,24,40}` et retient le
meilleur résidu (`residualDip ≤ 1.5`), avec `confidence = exact|approx|low`.
Si `confidence = low` (hauteur incohérente avec le nombre de comptes du coffre),
les mesures restent exploitables mais le mapping doit être vérifié manuellement.

---

## 8. Classification de l'état de l'overlay

- Largeur ≈ 40 DIP et hauteur ≈ 40 DIP (±2,5) → `collapsed` (`confidence=exact`).
- Largeur ≈ 380 DIP (±3) et hauteur ≈ une des 18 combinaisons connues (±1,5) →
  `expanded`, avec `accountRows`, `statusBlockDip`, `footerYDip`, `confidence`.
- Fenêtre présente mais non visible → `hidden` ; absente → `absent`.
- Le driver **relit toujours** les fenêtres au début de chaque action : l'overlay est
  recréé par l'application quand Riot est minimisé puis restauré, donc le **HWND
  change** (`0x1600974` → `0x1620974` observé). Ne jamais réutiliser un HWND d'un JSON
  précédent ; `restore`/`click` relisent l'état courant.

---

## 9. Journalisation et horodatage

- Stdout : un objet JSON unique (parsable ligne à ligne).
- `logs/driver.jsonl` : une ligne JSON compacte par invocation (tsUtc, action, ok,
  exitCode, durationMs, qpc, errorCode, fenêtre Riot, overlay, cible, notes).
- Timings internes QPC (`Stopwatch.GetTimestamp`, fréquence 10 000 000 Hz sur Windows) :
  `processStartupMs` = démarrage processus → `Add-Type` compilé ; `actionMs` = dispatch ;
  latences par message (SendMessage) et de suivi (poll 2 ms, tolérance ±2 px).

Mesures de référence relevées avec Outil `OverlayCtl` du Lead (à comparer) :
expand ≈ 6,9–7,3 ms, collapse ≈ 6,8 ms, hover 20 rafales ≈ 1,26 ms/message,
wheel ≈ 0,18 ms/message, suivi de déplacement 3 pas ≈ 1,43–1,73 ms.
Le driver mesure des **durées d'appel** `SendMessage` (même boucle UI bloquée pendant
le traitement), donc des valeurs du même ordre ; les latences `move-riot` incluent en
plus le poll (granularité ~2 ms) et doivent être comparées avec la même tolérance.

---

## 10. Restauration et état de référence

`baseline.json` :

```jsonc
{ "schemaVersion": 1, "savedUtc": "...", "source": "foreground-riot|manual-state|auto-first-interactive",
  "driverSchema": "riotswitch.perf.driver/1",
  "riot": { "hwnd": "0x1C08DC", "pid": 23544, "rect": { "x": 504, "y": 288, "w": 1552, "h": 872 } },
  "overlay": { "hwnd": "0x1620974", "visible": true, "rect": { "x": 1986, "y": 393, "w": 40, "h": 40 }, "state": "collapsed" },
  "settings": { "overlayPinned": true, "overlayOffsetRightDip": 30, "overlayOffsetTopDip": 105 },
  "foregroundHwnd": "0x110A5C" }
```

`restore` vérifie à la fin : rect Riot = baseline (±1 px), overlay `collapsed`,
ancre recalculée cohérente (`anchor.matches`), aucun dialogue Paramètres résiduel.
`move-riot` restaure toujours le rect Riot, même en cas d'erreur.

---

## 11. Limites connues / incertitudes

- **Arrondis DIP** : l'application arrondit en pixels ; le driver tolère ±1–2 px
  (classification ±2,5 DIP sur la largeur du bouton replié, ±3 DIP sur le panneau).
  En DPI fractionnaire (125 %, 150 %), les centres calculés restent dans leurs rects
  mais les mesures peuvent varier de ±1 px.
- **Clics synthétiques** : les handlers de l'overlay reçoivent bien les messages
  (fenêtre layered `WS_EX_NOACTIVATE`, même processus non requis), mais un
  `WM_MOUSELEAVE` synthétique sert uniquement à réinitialiser le hover ; il ne
  reproduit pas un déplacement physique hors fenêtre.
- **Dialogue Paramètres** : `footer:1`/`settings` ouvre un `ShowDialog()` **modal**
  qui bloque la boucle UI de l'overlay ; le `WM_LBUTTONUP` est donc envoyé avec
  `SendMessageTimeout` (2 s) et `upTimedOut=true` peut apparaître. `restore` ferme
  ce dialogue (`WM_CLOSE`, titre contenant « Param »). Ne pas cliquer pin/close
  pendant que le dialogue est ouvert (overlay bloqué).
- **Statut transitoire du pin** : `TogglePin` affiche un statut pendant 5 s, ce qui
  augmente temporairement la hauteur du panneau (+24/+40 DIP) ; les mesures de
  hauteur doivent être interprétées après expiration ou croisées avec `footerYDip`.
- **`move-riot` avec un panneau déplié** : la hauteur attendue repose sur la
  classification ; si un statut transitoire est affiché au départ, l'avertissement
  `transient_status_active_may_change_panel_height_during_move` est émis.
- **`foreground-riot`** : `SetForegroundWindow` peut échouer selon les règles de
  focus de Windows ; le driver applique le même fallback `AttachThreadInput` que
  l'application et signale `foreground_not_observed` si la fenêtre n'est pas au
  premier plan, sans échouer si l'overlay est visible.
- **`footer:0`** : action destructive non réversible par `restore` (écriture du
  coffre de comptes) ; `-Force` est obligatoire pour éviter tout clic accidentel.
- Le driver ne modifie pas `src/`, ne recompile pas, ne tue aucun processus.

---

## 12. Dépannage

| Sortie | Cause probable | Action |
|---|---|---|
| `riot_window_not_found` | Riot Client fermé / aucun hwnd correspondant | démarrer Riot Client, relancer `discover` |
| `riot_window_not_ready` + `rejectionReasons:["minimized"]` | Riot minimisé → overlay disposé | `foreground-riot -AllowInteraction` (campagne) |
| `overlay_not_found` | Riot prêt mais overlay pas encore créé/disposé | `wait-overlay` puis réessayer ; vérifier que RiotSwitch.exe tourne |
| `overlay_timeout` | l'overlay n'apparaît pas dans le délai | `foreground-riot` puis `wait-overlay -TimeoutMs 5000` |
| `transition_not_observed` | le clic n'a pas produit l'effet attendu (cible décalée, statut actif, UI bloquée) | relire `state`, vérifier `footerYDip`/`confidence`, puis réessayer avec `-PressMs 25` |
| `invalid_state` | cible incompatible avec l'état (ex. `close` sur overlay replié) | `state` puis `expand`/`collapse` d'abord |
| `interaction_not_allowed` | action interactive sans `-AllowInteraction` | ajouter le flag (campagne uniquement) |
| `force_required` | `footer:0` sans `-Force` | n'utiliser qu'après autorisation explicite du Lead |
| `native_layer_failed` | compilation `Add-Type` impossible (policy/AV) | vérifier `Get-ExecutionPolicy`, relancer en 64 bits |
