# Audit statique des coûts — RiotSwitch

> Préparation de la campagne de mesure de performance (task-4). **Audit statique, lecture seule : aucune mesure live n'a été effectuée ici.** Toute valeur chiffrée non sourcée est une **hypothèse [H]** à valider par la campagne ; les valeurs issues de `docs/validation.fr.md` sont marquées **[D]** (documentaires, non reproduites dans cet audit).

## 0. Fiche et verdict en bref

| | |
|---|---|
| Objet | Inventaire statique des coûts CPU/RAM/rendu, inventaire des claims README/docs, hypothèses quantitatives, protocole de mesure |
| Version auditée | source HEAD `ac32f18` ; binaire distribué `dist\RiotSwitch.exe` **1.1.17.0** (`ProductVersion 1.1.17+fb329029…`, 207 360 o, build 2026-11-10T21:44:18Z ; code = commit `da5bef5`, doc = `fb32902`) |
| Machine de référence | Windows 11 Pro 26200 ; AMD Ryzen 7 9800X3D (8 cœurs / **16 processeurs logiques**) ; 61,7 Go RAM ; PowerShell 5.1.26100.9711 |
| Réglages actuels | `%LOCALAPPDATA%\RiotSwitch\settings.json` : `backgroundMode=0` (Watch), `autostart=true`, `autoCheckUpdates=true`, `overlayPinned=true`, `overlayOffsetRightDip=30`, `overlayOffsetTopDip=105`, `lastUpdateCheckUtc=2026-11-10T20:50:45Z` |
| Périmètre | `src/RiotSwitcher.App`, `src/RiotSwitcher.Core`, `dist/README.md`, `docs/architecture.fr.md`, `docs/validation.fr.md`, `docs/utilisation.fr.md`, `README.md` |
| Hors périmètre | mesures live (task-4), `SwitchService`/API Riot, CLI, tests unitaires, rendu hors écran |
| Instance en cours | PID 30124 lancé en **`--launch-riot --ephemeral`** (mode zéro fond, `exitOnClientClose=true`) : **ne convient pas à l'état W** ; la campagne doit utiliser une instance `--watch` dédiée (§5.1) |

**Verdict en bref**

1. **État W (veilleur sans overlay) : source CPU dominante attendue = le timer de secours du tracker à 1 Hz** (`RiotWindowTracker.cs:43`), qui exécute `RiotClientWindow.Find()` et, quand aucune fenêtre Riot n'est trouvée, **jusqu'à 5 énumérations `EnumWindows` par tick** (`RiotWindowTracker.cs:112-139`). Budget attendu **0,10–0,50 % d'un cœur** : le claim ≈0,3 % est plausible, mais dépend du nombre de fenêtres du bureau (à consigner).
2. **Autres contributeurs attendus, par ordre décroissant** : événements de hook retenus (CREATE/DESTROY/SHOW/HIDE/REDRAW/STATECHANGE top-level + FOREGROUND, LOCATIONCHANGE exclu) → un `Check()` chacun ; timer d'arrêt 1 Hz **seulement** en mode launcher/`--attach` (2 × `Process.GetProcesses` par tick, 0,3–0,8 % cœur) ; trim/GC (quasi nul en régime établi, pic à la première passe) ; vérification de mise à jour (one-shot à T+20 s).
3. **Claims vérifiables** : WS 10–16 Mo, privé 14–16 Mo, CPU ≈0,3 %, suivi 1–2 ms, timer overlay 500 ms, trim >32 Mo, 380 DIP / 380×316 / +36 DIP, statuts 5 s/8 s. **Trois points à trancher** : (a) « privé » n'est pas défini (commit privé vs *private working set*) et un log de trim indique `privée=24 Mo` en mode launcher ; (b) la mesure « CPU 0 % sur 4 s » (`validation.fr.md:79`) est sous la résolution utile ; (c) `architecture.fr.md:39` documente un timer tracker de **2 s** alors que le code est à **1 000 ms** (`RiotWindowTracker.cs:43`) et que la note de release v1.1.14 dit 1 s (`validation.fr.md:154`).
4. **Protocole** : 6 états W/A/B/C/D/E/F, intégration ΔCPU/Δt sur ≥120–180 s, 3 répétitions, compteurs externes + journal comme contrôle de validité ; budget ≈50–65 min pour la campagne complète.

## 1. Méthode et conventions

- Inspection exhaustive de `src/` (App/Core), `dist/README.md`, `docs/*.fr.md`, `README.md` ; aucune modification hors `docs/perf/`.
- Chaque coût est classé : **[C]** fait de code (fichier:ligne vérifiable), **[H]** hypothèse chiffrée à tester, **[D]** valeur documentaire existante.
- Unités : **Mo = MiB** (1 MiB = 1 048 576 octets) ; CPU en **% d'un cœur** (100 % = un processeur logique à plein temps) ; **% machine = % cœur / 16**.
- Le binaire distribué est une publication *framework-dependent* 1.1.17 (207 360 o) : le coût de démarrage inclut le runtime .NET 8 partagé, pas l'overlay.

## 2. Inventaire statique des mécanismes

### 2.1 Timers WinForms (6 au total)

| Timer (champ) | Période | Code | Démarrage → arrêt | Travail par tick | États | Coût attendu |
|---|---|---|---|---|---|---|
| `_fallback` (tracker) | 1 000 ms | `RiotWindowTracker.cs:43-44` | `Start()` `:73` → jamais arrêté (Dispose `:292-309`) | `Check()` `:108-191` : `Find()` + éventuellement `RestoreMinimizedOnce()`/`FindPresent()` + `Changed` | W, A, B, C, D, E, F | **0,1–0,5 % cœur en W** (5 énumérations/tick) ; ~0,02–0,1 % en A (1 énumération/tick) |
| `_trimTimer` | 2 000 ms puis 10 000 ms | `WatchContext.cs:73-74` | `Start()` `:82` → `DisposeResources` | `TrimWorkingSetIfIdle()` `:259-293` : skip si overlay `:262` ; seuil `32L*1024*1024` `:267` ; 2 × `GC.Collect(Forced, blocking, compacting)` + `WaitForPendingFinalizers` `:270-272` ; `EmptyWorkingSet` `:274` ; intervalle → 10 s `:277` | W, F (et tout état sans overlay) | ≈0 en régime établi ; 20–80 ms à la 1re passe ; 10–50 ms/passe si WS > 33,55 Mo |
| `_exitTimer` | 1 000 ms | `WatchContext.cs:67-68` | `ScheduleExitCheck()` `:184-188` (uniquement `exitOnClientClose`) → Stop `:154`/`:219` | `CheckExitPending()` `:206-221` → `IsRiotClientAlive()` `:190-204` = `FindClientUi()` **ou** `FindService()` = 2 × `Process.GetProcesses()` | transitoire launcher/`--attach` (jamais en W watch) | 3–8 ms/s = **0,3–0,8 % cœur** quand actif |
| `_positionTimer` (overlay) | 500 ms | `OverlayForm.cs:166-176` | `ShowAttached()` `:247` → `StopTimers()` `:2060-2077` | `UpdatePosition()` + `EnsureAboveOwner()` | A, B, C, D, E | 0,02–0,1 % |
| `_outsideTimer` (overlay) | 120 ms | `OverlayForm.cs:178-182` | `Expand()` `:1730` → `Collapse()` `:1737` | `CheckOutsideClick()` `:1871-1897` : 2 × `GetAsyncKeyState`, `GetCursorPos`, `GetWindowRect` | B, C | <0,02 % |
| `_statusTimer` (overlay) | one-shot 5 000/8 000 ms | `OverlayForm.cs:186-187` | `SetStatus()` `:1813-1825` → `ExpireStatus()` | efface/recale le message | C, E | négligeable |

Notes :
- Granularité `WM_TIMER` ≈ 15,6 ms : périodes réelles 1 000–1 016 ms, 500–516 ms, 120–141 ms selon la charge ; compter les ticks réellement mesurés, jamais les valeurs nominales.
- Aucun `System.Threading.Timer`, aucune boucle `while` de polling, aucun `NotifyIcon` (recherche exhaustive) : le veilleur ne se réveille que par ces 6 timers et les hooks.

### 2.2 Hooks `SetWinEventHook` (4 au total)

| Hook | Portée / filtre | Code | Callback et travail | Fréquence attendue | Coût/événement | États |
|---|---|---|---|---|---|---|
| Tracker, plage large | `EVENT_OBJECT_CREATE` 0x8000 → `EVENT_OBJECT_LOCATIONCHANGE` 0x800B ; tous processus (`idProcess=0`, `idThread=0`) ; `WINEVENT_OUTOFCONTEXT \| WINEVENT_SKIPOWNPROCESS` | `RiotWindowTracker.cs:53-60` ; filtre `idObject != 0` `:87` ; LOCATIONCHANGE rejeté `:93` ; `BeginInvoke(Check)` `:97-98` | `Check()` complet : `Find()` et jusqu'à 4 énumérations supplémentaires | 0,2–2 événements retenus/s au repos ; 10–100/s en rafale (app, menu, toast, bureau virtuel) | 0,5–3 ms (un `Check()`) si aucune fenêtre Riot | W, A, B, C, D, E, F |
| Tracker, avant-plan | `EVENT_SYSTEM_FOREGROUND` seul | `:64-71` | même callback → `Check()` | 0,1–2/s | idem | W, A, B, C, D, E, F |
| Overlay, déplacement | `EVENT_OBJECT_LOCATIONCHANGE` seul | `OverlayForm.cs:194-201` ; `OnTargetWinEvent()` `:387-418` | si `hwnd == _target.Handle` → `UpdatePosition()` (`SetWindowPos`, sans redraw) | tous les déplacements de fenêtres top-level : ≈0 au repos, 30–200/s pendant un glisser/animations | 1–5 µs si autre fenêtre (rejet) ; 0,05–0,2 ms si cible | A, B, C, D, E |
| Overlay, avant-plan | `EVENT_SYSTEM_FOREGROUND` seul | `:203-210` | `EnsureAboveOwner()` si la cible redevient visible | 0,1–1/s | 10–50 µs | A, B, C, D, E |

Points importants :
- Les hooks sont **out-of-context** et **SKIPOWNPROCESS** : les événements du process RiotSwitch lui-même ne le réveillent pas ; les callbacks sont livrés sur le thread UI via la boucle de messages (`BeginInvoke`), donc un `Check()` lent retarde les autres messages et peut faire coalescer/perdre des événements.
- La plage 0x8000–0x800B inclut aussi `REDRAW` (0x8004) et `STATECHANGE` (0x8005) : seuls les événements de fenêtres **top-level** (`idObject == 0`) sont retenus.
- `EVENT_OBJECT_LOCATIONCHANGE` est ignoré par le tracker (`:93`) ; c'est le hook de l'overlay qui gère la position, et seulement pour le handle cible.

### 2.3 Threads

- **Thread UI (STA)** : `Application.Run(new WatchContext(...))` (`Program.cs:162`). Porte tous les timers, les callbacks de hook, la création/destruction de l'overlay, le rendu GDI+ et `UpdateLayeredWindow`. C'est lui qui doit porter >90 % du CPU en W.
- **ThreadPool** : `Task.Run(CheckUpdatesInBackgroundAsync)` (`WatchContext.cs:81`) pour la vérification de mise à jour HTTP (une fois, après `Task.Delay(20 s)` `:98`) ; `Task.Run(() => _switchService.Switch(...))` (`OverlayForm.cs:1933`) uniquement pendant un changement de compte.
- **Thread launcher** : `new Thread("RiotSwitch.ShowClient")` (`Program.cs:230-242`), uniquement en mode `--launch-riot` ; boucle ≤40 × (essai 1 s + `Sleep(250 ms)`), background, meurt après.
- **Runtime .NET** : GC, finalizer, tiered compilation, I/O async — ≈8–12 threads attendus ; mesurer `Threads.Count` et le top 5 CPU par thread.
- **GC forcé** : deux `GC.Collect(GC.MaxGeneration, Forced, blocking:true, compacting:true)` + `WaitForPendingFinalizers` dans le trim (`WatchContext.cs:270-272`) — pause UI visible, uniquement lors d'une passe.

### 2.4 Chemins de rendu et allocations chaudes

Pipeline d'un rendu (`OverlayForm.UpdateLayered`, `:527-547`) :

1. `GetScale()` = `GetDpiForWindow(_target.Handle)/96`, clamp 1,0–2,5 (`:572-584`) ;
2. `ComputeLayout()` (`:586-688`) : `GetWindowRect` cible, DIP→px, clamp à la fenêtre client ±8 DIP (`EdgeMarginDip`), allocation d'une `List<RectangleF>` (`:629-637`) ;
3. `RenderBitmap(w,h,TextHint)` (`:559-570`) : `new Bitmap(w,h,Format32bppArgb)` (pixels non managés GDI+), `Graphics.FromImage`, `SmoothingMode.AntiAlias`, `TextRenderingHint.ClearTypeGridFit` (`TextHint` `:556`), `InterpolationMode.HighQualityBicubic`, `Clear(Transparent)`, `ScaleTransform(_scale)`, `Draw(...)` (`:738-747`) ;
4. `ApplyLayeredWindow(bitmap, rect)` (`:698-736`) : `GetDC(0)` → `CreateCompatibleDC` → `bitmap.GetHbitmap` → `SelectObject` → `UpdateLayeredWindow(ULW_ALPHA)` → libération de tous les handles GDI ;
5. composition par DWM (coût hors process RiotSwitch, §5.4).

Tailles de bitmap 32 bpp (4 octets/pixel, avant composition) :

| État overlay | DIP à 100 / 125 / 150 % | Bitmap à 100 % | Bitmap à 150 % |
|---|---|---|---|
| replié 40×40 | 40 / 50 / 60 | 6,4 Ko | 14,4 Ko |
| déplié base 380×316 | 380×316 / 475×395 / 570×474 | 0,48 Mo | 1,08 Mo |
| déplié + statut 1 ligne 380×352 | 380×352 / 475×440 / 570×528 | 0,53 Mo | 1,20 Mo |
| déplié max 5 comptes + statut 2 lignes 380×449 | 380×449 / 475×561 / 570×674 | 0,68 Mo | 1,54 Mo |

Déclencheurs de rendu et coût attendu par rendu **[H]** (Ryzen 7 9800X3D) :

| Action | Redessine ? | Coût CPU attendu | Source |
|---|---|---|---|
| affichage initial / `Load` | oui | 0,8–3 ms (+ 1re fois : cache polices GDI+ 2–10 ms) | `OverlayForm.cs:212`, `:236-250` |
| `Expand()` / `Collapse()` | oui | 0,8–3 ms chacun | `:1717-1753` |
| survol qui change d'état (ligne/bouton) | oui, 1 × par transition | 0,8–3 ms | `:1467-1528` |
| molette (1 cran) | oui | 0,8–3 ms par cran | `:1605-1615` |
| glisser de l'overlay (chaque move) | oui | 1–4 ms × 60–120 moves/s (pic 6–30 % cœur) | `:1467-1528` |
| statut, épinglage, fin de switch | oui | 0,8–3 ms | `:1695-1715`, `:1800-1828`, `:1981-2012` |
| déplacement de la fenêtre Riot (LOCATIONCHANGE) | **non** : `SetWindowPos` seul | 0,05–0,2 ms/événement | `:322-380`, `:363-377` |
| redimensionnement de la fenêtre Riot | oui (`ComputeLayout` + `UpdateLayered`) | 1–4 ms + `SetWindowPos` | `:379` |
| tick position 500 ms sans changement | non (retour avant `ComputeLayout`) | ≈0,01–0,05 ms | `:322-380`, `:166-176` |

Allocations observables :
- `ReadTitle()` alloue un `StringBuilder` + une chaîne **par fenêtre visible et titrée, à chaque énumération** (`RiotClientWindow.cs:207-214`) : à 5 énumérations/s × 30–60 fenêtres → ≈150–300 chaînes/s, ≈25–60 Ko/s (gen0 toutes les ~1–3 min, coût <0,02 % cœur) ;
- `RenderBitmap` alloue un `Bitmap` dont les pixels sont **non managés** (pression GC faible) mais des objets GDI+ managés ; `Graphics`, `Font` (5–15 par rendu), `Pen`/`Brush`/`GraphicsPath` sont alloués/libérés à chaque rendu (`Draw*`, `:749-1399`) ;
- `ComputeLayout` alloue `List<RectangleF>` + rectangles (`:629-650`) ; `ComputeStatusLines` alloue `Bitmap(1,1)` + `Graphics` + `Font(9f)` + `StringFormat` à chaque message (pas par frame) (`:1760-1780`) ;
- `ReloadData` : `ListAccounts().ToList()` (lecture `accounts.json`) + `RiotSessionReader.ReadFile()` (YAML + SHA-256 + regexes) — chemins froids (ouverture de l'overlay, refresh, fin de switch) (`:291-320`).

### 2.5 P/Invoke et chemins chauds

| Mécanisme | Où | Fréquence | Coût attendu |
|---|---|---|---|
| `EnumWindows` complet (le callback retourne toujours `true`, pas de sortie anticipée) | `RiotClientWindow.cs:33` (Find), `:94` (FindMinimized), `:153` (FindPresent) | 1 ×/s en A ; **5 ×/s en W** (Find + FindMinimized + Find + FindPresent + Find) | 0,2–1,5 ms/énumération selon N |
| `DwmGetWindowAttribute(DWMWA_CLOAKED)` par fenêtre visible | `RiotClientWindow.cs:39`, `:220-236` | N_visibles × énumérations | 2–10 µs/fenêtre |
| `GetWindowTextLength` + `GetWindowText` par fenêtre visible | `:207-214` | idem | 1–4 µs/fenêtre |
| `Process.GetProcessById` + `ProcessName` (titre « Riot Client » seulement) | `:43`, `:333-344` | rare | 20–100 µs |
| `WindowFromPoint` ×25 (grille 5×5) | `:56`, `:282-331` | seulement candidat visible non-foreground | 25 × 0,5–2 µs |
| `MonitorFromWindow` / `GetMonitorInfo` | `:242-272` | par candidat | 2–10 µs |
| `Process.GetProcesses()` (+ nom/StartTime par process) | `RiotProcessController.cs:288` via `WatchContext.cs:197-198` | **2 × par tick de 1 s** quand `_exitTimer` actif (launcher/`--attach`) | 1,5–4 ms par énumération |
| `UpdateLayeredWindow` + DC/HBITMAP | `OverlayForm.cs:698-736` ; `AppNativeMethods.cs:100-131` | par rendu | 0,2–0,8 ms |
| `GetDpiForWindow` | `OverlayForm.cs:538` | par rendu | <1 µs |
| `EmptyWorkingSet` + 2 GC bloquants | `WatchContext.cs:270-274` | à chaque passe de trim | 20–80 ms/passe |
| `GetAsyncKeyState` ×2 + `GetCursorPos` + `GetWindowRect` | `OverlayForm.cs:1871-1897` | 8,3 ×/s panneau déplié | ≈5–20 µs/tick |
| I/O fichier : log, settings, coffre, JSON install | `FileLogger.cs:49-67` ; `SettingsStore.cs:76-93` ; `SessionVault.cs:53-59` | événements/interactions | quelques ms, hors régime établi |

### 2.6 Tableau de synthèse mécanisme → fréquence → coût attendu → états

| # | Mécanisme | Fréquence | Coût attendu | États |
|---|---|---|---|---|
| M1 | Timer fallback tracker → `Check()` | 1 Hz (1 000–1 016 ms) | **0,1–0,5 % cœur en W** (5 énumérations/s) ; ~0,02–0,1 % en A (1 énumération/s) | W, A, B, C, D, E, F |
| M2 | Hook tracker (0x8000–0x800B, top-level, hors LOCATIONCHANGE) | 0,2–2/s repos ; 10–100/s rafale | 0,5–3 ms/événement (un `Check()`) → 0,01–0,2 % au repos ; pics 0,5–30 % | W, A, B, C, D, E, F |
| M3 | Hook tracker FOREGROUND | 0,1–2/s | idem M2 | W, A, B, C, D, E, F |
| M4 | Trim + GC bloquants + `EmptyWorkingSet` | 1re passe ~2 s ; puis 10 s si WS > 32 MiB **et** sans overlay | ≈0 en régime établi ; 20–80 ms/passe sinon | W, F (pas A/B/C/D/E) |
| M5 | Timer exit 1 Hz → 2 × `Process.GetProcesses` | 1 Hz, uniquement `exitOnClientClose` en attente | 3–8 ms/s → 0,3–0,8 % cœur | transitoire launcher/`--attach` (pas W watch) |
| M6 | Timer position 500 ms + `EnsureAboveOwner` | 2 Hz | 0,02–0,1 % | A, B, C, D, E |
| M7 | Timer extérieur 120 ms | 8,3 Hz panneau déplié | <0,02 % | B, C |
| M8 | Timer statut one-shot 5/8 s | à chaque message | négligeable | C, E |
| M9 | Rendu GDI+ + `UpdateLayeredWindow` | par interaction/état | 0,8–4 ms/rendu ; glisser 1–4 ms × 60–120/s | A, B, C, D (resize), E, F |
| M10 | 3–5 `EnumWindows` par `Check()` en W | 5/s | 1–5 ms/s (0,1–0,5 %) ; dépend de N fenêtres | W, F (avant overlay) |
| M11 | Vérification mise à jour HTTP | 1 × à T+20 s (si cache 24 h expiré) | 5–50 ms one-shot + réseau | F, début W |
| M12 | Log fichier / rotation | sur événement | <0,01 % hors démarrage | tous |
| M13 | Allocations/GC de fond (`ReadTitle`) | 25–60 Ko/s | <0,02 % | W, A, B |
| M14 | Démarrage : COM WScript.Shell + `.lnk`, découverte Riot, JSON, JIT, 1er rendu | 1 × au lancement | 100–400 ms une fois | F |

### 2.7 Budget CPU attendu de l'état W (avant campagne)

Hypothèse avec N ≈ 60–150 fenêtres top-level, 20–60 visibles, coût 0,2–1,0 ms par énumération **[H]** :

| Contribution | Estimation | Part |
|---|---|---|
| M1/M10 : 5 énumérations/s | 1,0–5,0 ms/s → **0,10–0,50 % cœur** | dominante (60–90 %) |
| M2/M3 (événements au repos) | 0,1–1,0 ms/s → 0,01–0,10 % | secondaire |
| M4 (vérification 10 s) | ≈0 | négligeable |
| M13 + boucle de messages | 0,01–0,05 % | négligeable |
| **Total attendu** | **0,15–0,55 % cœur** = 0,01–0,035 % machine | cohérent avec ≈0,28–0,30 % **[D]** |

Si la campagne mesure > 0,6 % : chercher le churn de fenêtres/overlay, le mode launcher (exit timer), un trim répété (WS > 32 MiB), ou un autre agent en cours. Si elle mesure < 0,15 % : vérifier que le tracker tourne (log « Tracker démarré ») et que N est petit.

## 3. Claims existants : citations exactes et vérification

### 3.1 Localisation (écart avec l'énoncé de tâche)

`README.md` racine (105 lignes) **ne contient aucun claim de performance chiffré** : il dit seulement (`README.md:101`) « C# / .NET 8, overlay WinForms rendu en GDI+, aucun paquet tiers. » Les claims « lignes ~94 et ~239 » cités dans la tâche sont dans **`dist/README.md`** (248 lignes), le README distribué. `docs/utilisation.fr.md:67` et `:87` les dupliquent. Toutes les citations ci-dessous sont verbatim.

### 3.2 Citations des claims

**C1 — WorkingSet 10–16 Mo, CPU ≈0,3 %, privé 14–16 Mo (watch, sans overlay)**
> « Il est optimisé pour rester très léger : WorkingSet d'environ 10–16 Mo au repos après compactage (privé ≈ 14–16 Mo) et CPU quasi nul (≈0,3 % d'un cœur en mesure précise, 0 % affiché dans le Gestionnaire des tâches). » — `dist/README.md:94`
>
> « Le veilleur compacte sa mémoire de travail au repos (trim au-delà de 32 Mo, uniquement sans overlay) : WorkingSet ≈ 10–16 Mo, privé ≈ 14–16 Mo, CPU quasi nul (≈0,3 % d'un cœur en mesure précise). » — `dist/README.md:239`
>
> « après compactage WorkingSet ≈ 9,5–16 Mo (9,7 Mo à 3 s, 15 Mo à 13 s, 16,3 Mo à 25 s), privé ≈ 14–16 Mo, CPU ≈ 0,3 % d'un cœur en mesure précise (invisible dans le Gestionnaire des tâches) ; démarrage à ≈ 62,6 Mo avant compactage » — `docs/validation.fr.md:17`
>
> « Mesure réelle (veilleur caché, Riot Client présent mais non visible) : 62,6 Mo à 1,5 s, 9,7 Mo à 3 s, 15 Mo à 13 s, 16,3 Mo à 25 s, privé 14–16 Mo ; CPU post-compactage ≈ 0,28 % d'un cœur (Gestionnaire des tâches : 0 %). » — `docs/validation.fr.md:74`
>
> « le WorkingSet redescend autour de 10–16 Mo (mesuré), privé ≈ 14–16 Mo, sans consommation CPU mesurable entre deux passages » — `docs/architecture.fr.md:42`
>
> « Le seuil mémoire du veilleur est mesuré autour de 62 Mo de WorkingSet au démarrage, puis compacté autour de 10–16 Mo (privé ≈ 14–16 Mo, CPU ≈ 0,3 % d'un cœur en mesure précise / 0 % affiché) par le trim déclenché au-delà de 32 Mo » — `docs/architecture.fr.md:237`

**C2 — suivi immédiat 1–2 ms, timer de secours overlay 500 ms, sans redessin**
> « l'overlay suit le déplacement de la fenêtre Riot en 1–2 ms (hook `EVENT_OBJECT_LOCATIONCHANGE` filtré sur la fenêtre cible), sans attendre le timer de secours de 500 ms et sans redessiner tant que seule la position change. » — `dist/README.md:115` (identique `docs/utilisation.fr.md:87`)
>
> « un hook `EVENT_OBJECT_LOCATIONCHANGE` filtré sur la fenêtre cible redéplace l'overlay immédiatement (mesuré à 1–2 ms, contre jusqu'à 500 ms avec le seul timer). Si seule la position change, `SetWindowPos` déplace la fenêtre layered sans redessiner ; `UpdateLayeredWindow` n'est réutilisé que si la taille de mise en page change » — `docs/architecture.fr.md:73`
>
> « déplacements programmatiques du client → overlay à jour en 1–2 ms (+120 px : 2 ms ; −60/+40 : 1 ms ; glissement de 20 pas de 6 px à 15 ms suivi exactement) ; overlay forcé sous le client … réassertion automatique au tick de secours (≤ 700 ms, mesuré 122 ms) » — `docs/validation.fr.md:79`
>
> « l'overlay reste au-dessus de la fenêtre Riot (`EnsureAboveOwner()`, rangs Z 53–57 contre 72 …) et suit ses déplacements en 1–2 ms … réassertion automatique ≤ 700 ms après une mise sous le client forcée (mesuré 122 ms) » — `docs/validation.fr.md:35`

**C3 — trim > 32 Mo, uniquement sans overlay**
> « trim `EmptyWorkingSet` déclenché au-delà de 32 Mo de WorkingSet, uniquement sans overlay » — `docs/validation.fr.md:30`
>
> « Le veilleur compacte sa mémoire de travail au repos : `GC.Collect` puis `EmptyWorkingSet` (psapi) déclenché 2 s après le démarrage puis toutes les 10 s **uniquement si le WorkingSet dépasse 32 Mo et qu'aucun overlay n'est affiché** » — `docs/architecture.fr.md:42`

**C4 — timer tracker : 2 s documenté, 1 s codé**
> « `RiotWindowTracker` combine `SetWinEventHook` (…) et un timer de secours de 2 secondes. » — `docs/architecture.fr.md:39`
>
> « Release `v1.1.14` : (…) timer de secours réduit à 1 s » — `docs/validation.fr.md:154`
>
> Code : `_fallback = new System.Windows.Forms.Timer { Interval = 1000 }` — `src/RiotSwitcher.App/RiotWindowTracker.cs:43`. → **écart documentaire** (l'architecture n'a pas été mise à jour après v1.1.14).

**C5 — géométrie et rétention des statuts**
> « panneau replié : bouton 40×40 … panneau déplié jusqu'à 380×449 (5 comptes + statut 2 lignes) » — `docs/validation.fr.md:18`
>
> « statut affiché en 380×352 = H0 + 36 DIP, effacement automatique mesuré 5 088 ms après le clic ; second message → effacé 5 040 ms après le dernier clic (6 145 ms après le premier) ; fermeture pendant un statut puis réouverture 901 ms après → panneau sans bandeau » — `docs/validation.fr.md:83`
>
> « 5 s pour une information ou un succès, 8 s pour un avertissement ou une erreur » — `dist/README.md:116`
>
> « panneau compact (380 DIP) » — `dist/README.md:109`

**C6 — « aucun CPU mesurable » / « CPU 0 % » (formulations non quantifiées)**
> « Tant qu'aucune fenêtre du Riot Client n'est visible, aucun overlay n'existe : pas de fenêtre, pas de dessin, pas d'activité CPU mesurable. » — `docs/architecture.fr.md:40`
>
> « `RiotSwitch.exe --watch` → processus unique caché, aucune fenêtre, CPU 0 % au repos. » — `docs/validation.fr.md:53`
>
> « CPU 0 % d'un cœur sur 4 s, WorkingSet 69,1 Mo (trim sauté tant que l'overlay est affiché) » — `docs/validation.fr.md:79`
>
> checklist encore non cochée : « [ ] Mode veilleur sans Riot : aucune fenêtre, CPU 0 % au repos, mémoire mesurée. » — `docs/validation.fr.md:246`

**C7 — non observables en campagne (rendu hors écran)**
> « vérifiée par 22 rendus GDI+ hors écran » — `docs/validation.fr.md:18` ; « pixels de texte 4 627 → 5 016, franges de sous-pixels `|R−B|` moyen 15,7 → 64,6, contraste haut/mi 0,32 → 0,43 » — `docs/validation.fr.md:85`. Ces valeurs relèvent d'une vérification statique/visuelle, pas de la campagne CPU/RAM.

### 3.3 Tableau claim → mesure de campagne → critère

| # | Claim (valeur) | Sources | État(s) | Mesure requise | Critère de verdict |
|---|---|---|---|---|---|
| C1 | WS 10–16 Mo après compactage, sans overlay | `dist/README.md:94, :239` ; `validation.fr.md:17, :74` ; `architecture.fr.md:42, :237` ; `utilisation.fr.md:67` | W | WS 1 Hz sur 180 s après trim confirmé ; médiane/min/max ; nb de passes de trim | médiane ∈ [9 ; 17] MiB **et** trim observé ≤ 5 s après démarrage → conforme ; sinon écart chiffré |
| C2 | privé 14–16 Mo | idem C1 | W | **deux** grandeurs : `PrivateMemorySize64` (commit privé) **et** *private working set* (somme `QueryWorkingSet`, pages non partagées) ; médianes | préciser la définition : commit ∈ [12 ; 18] MiB → conforme ; private WS ∈ [9 ; 17] MiB → conforme ; si commit ≈ 24 Mo (cf. log du 2026-11-10T22:13:24Z) → claim à corriger/préciser |
| C3 | CPU ≈ 0,3 % d'un cœur | `dist/README.md:94, :239` ; `validation.fr.md:17` (0,3), `:74` (0,28) ; `architecture.fr.md:237` ; `utilisation.fr.md:67` | W | intégrale ΔCPU/Δt sur 180 s, 3 runs ; % cœur + % machine ; N fenêtres noté | médiane ∈ [0,15 ; 0,50] % cœur → conforme ; sinon écart chiffré |
| C4 | « 0 % affiché dans le Gestionnaire » | `dist/README.md:94` ; `validation.fr.md:17, :74` | W | calcul : % machine = % cœur / 16 | % machine < 0,5 % ⇒ 0 % affiché ; claim compatible (ne pas mesurer au Gestionnaire) |
| C5 | suivi 1–2 ms | `dist/README.md:115` ; `utilisation.fr.md:87` ; `architecture.fr.md:73` ; `validation.fr.md:35, :79` | D | latence par mouvement : QPC entre le `SetWindowPos` cible (driver) et le changement de rect de l'overlay (polling 0,1–0,2 ms) ; 30 mouvements | p50 ≤ 2 ms **et** p95 ≤ 2 ms ; max ≤ 5 ms (tolérance ordonnancement) |
| C6 | timer de secours overlay 500 ms (filet) | `dist/README.md:115` ; `utilisation.fr.md:87` ; `architecture.fr.md:72` | D | p95 de C5 ≪ 500 ms ; vérifier code `OverlayForm.cs:166` (500 ms) | p95 ≤ 5 ms démontre que le hook est utilisé ; le 500 ms reste le pire cas théorique |
| C7 | trim > 32 Mo, seulement sans overlay | `validation.fr.md:30` ; `architecture.fr.md:42` ; `dist/README.md:239` | W, F, A, B | log « mémoire de travail compactée » + WS ; A/B : aucun trim même si WS > 32 MiB ; code `WatchContext.cs:262`, `:267` | conforme si 0 trim pendant A/B, ≤ 1 pendant W (hors démarrage), et trim observé en F |
| C8 | démarrage ≈ 62,6 Mo puis 9,7@3 s, 15@13 s, 16,3@25 s | `validation.fr.md:17, :74` ; `architecture.fr.md:237` | F | WS à 100 ms de t0 à 40 s ; pic avant trim ; t_trim ; WS à 3/13/25 s | pic ∈ [45 ; 80] MiB et t_trim ≤ 5 s → conforme ; sinon écart (build/machine) |
| C9 | 40×40 / 380 DIP / 380×316 / +36 DIP / 380×449 | `validation.fr.md:18, :37, :79, :83` ; `dist/README.md:109` ; `architecture.fr.md:77, :80` | A, B, C, E | rect overlay en px + échelle DPI → DIP ; statut 1 ligne puis 2 lignes, 5 comptes | 40 DIP replié ; 380 DIP de large ; +36 DIP statut 1 ligne ; ≤ 449 DIP (5 comptes + 2 lignes) ; tolérance ±1 DIP |
| C10 | ordre Z (rangs 53–57 vs 72) ; réassertion ≤ 700 ms | `validation.fr.md:35, :79` ; `dist/README.md:242` | A, B, D | Z-order par `GetWindow(GW_HWNDPREV)` ; forcer l'overlay sous Riot puis mesurer le rétablissement | overlay au-dessus de l'owner ; réassertion ≤ 700 ms (attendu ≈ 500–516 ms par tick) |
| C11 | statuts 5 s / 8 s ; +36 DIP ; collapse efface | `dist/README.md:116` ; `validation.fr.md:37, :83` ; `architecture.fr.md:80` | C, E | déclencher Info/Warning, mesurer la durée visible (rect 316→352→316) | 5 000–5 200 ms ; 8 000–8 200 ms ; retour 316 DIP ; aucun statut après collapse |
| C12 | « CPU 0 % sur 4 s » ; WS 69,1 Mo overlay visible | `validation.fr.md:79` | A, B | refaire avec 120–180 s ; WS avec overlay (trim sauté) | la formulation 4 s est **non concluante** (§3.4) ; la campagne produit une borne sur 180 s ; WS > 32 MiB attendu (trim sauté) |
| C13 | « aucune activité CPU mesurable » sans fenêtre Riot | `architecture.fr.md:40, :42` | W | C3 + GDI/USER + vérifier 0 overlay (énumération des fenêtres du process) | si CPU W ≤ 0,6 % et 0 rendu/overlay → conforme à l'esprit ; remplacer « non mesurable » par la valeur mesurée |
| C14 | `--watch` : 1 processus, 0 fenêtre, CPU 0 % | `validation.fr.md:53, :246` | W | 1 seul PID (mutex) ; 0 fenêtre visible du process ; CPU borné | conforme si 1 instance, 0 fenêtre, CPU ≤ 0,6 % |
| C15 | tracker n'appelle plus `Find()` à chaque déplacement | `dist/README.md:242` ; `architecture.fr.md:74` ; code `RiotWindowTracker.cs:93` | D | pendant D : aucun log tracker hors changement de handle ; CPU/mouvement faible vs sous-test resize (redraw) | conforme si p95 CPU/mouvement < 1 ms et ratio move/resize < 0,5 ; sinon écart |
| C16 | 22 rendus hors écran / ClearType | `validation.fr.md:18, :85` ; `dist/README.md:110` | — | non mesurable en campagne (rendu hors écran) | hors périmètre ; vérification statique/visuelle |
| C17 | timer « 2 s » (architecture) | `architecture.fr.md:39` | — | lecture code : 1 000 ms (`RiotWindowTracker.cs:43`) ; note release : 1 s (`validation.fr.md:154`) | écart documentaire à corriger (pas une mesure) |

### 3.4 Écarts et ambiguïtés à trancher

1. **Localisation des claims** : la tâche vise « README ~94/~239 » ; il s'agit de `dist/README.md`, pas du `README.md` racine (105 lignes, sans claims perf). La racine et `docs/utilisation.fr.md` doivent rester alignés sur la formulation mesurée.
2. **« privé » non défini** : `PrivateMemorySize64` (commit privé, ce que logue `WatchContext.cs:281-286`) n'est pas le *private working set*. La revendication 14–16 Mo est datée de la v1.1.11 (`validation.fr.md:74`) ; le log de trim du **2026-11-10T22:13:24Z** affiche `working set=1 Mo, privée=24 Mo` (instance launcher, après GC + `EmptyWorkingSet`). La campagne doit mesurer les deux et fixer la définition.
3. **CPU « 0 % sur 4 s »** (`validation.fr.md:79`) : 4 s est inférieur à la résolution utile (quantum `GetProcessTimes` ≈ 15,6 ms → 0,39 % sur 4 s) et ne peut pas établir « 0 % ». À remplacer par une borne sur 120–180 s (§5).
4. **Timer tracker** : `architecture.fr.md:39` dit 2 s, le code (`RiotWindowTracker.cs:43`) et la note de release v1.1.14 disent 1 s. Corriger l'architecture : le nombre de `Find()`/s en dépend.
5. **Bande morte du trim** : le seuil est `32L*1024*1024` = 33,55 Mo décimaux (`WatchContext.cs:267`) ; entre 16 et 32 MiB, aucun trim ne s'exécute. Une dérive de WS (churn overlay, exit timer) peut donc laisser WS > 16 Mo sans correction ; le claim « 10–16 Mo » doit être daté « après compactage, sans activité », et la campagne doit rapporter la distribution complète (pas seulement la médiane).
6. **Deux « timers de secours »** : le tracker (1 000 ms, `RiotWindowTracker.cs:43`) et la position de l'overlay (500 ms, `OverlayForm.cs:166`). Les docs les distinguent correctement, sauf `architecture.fr.md:39` (2 s, obsolète) ; ne pas les confondre dans le rapport.

## 4. Hypothèses quantitatives sur l'état W et tests discriminant

### 4.1 Hypothèses

| # | Hypothèse | Estimation chiffrée **[H]** | Contribution attendue |
|---|---|---|---|
| H1 | Le timer de secours du tracker (1 Hz) est dominant : chaque tick → `Find()` ; si aucune fenêtre Riot → + `FindMinimized()` (toujours 1 énumération), + `Find()` bis, + `FindPresent()` (1 énumération), + `Find()` ter = **5 énumérations/s** (`RiotWindowTracker.cs:112-139`) | `Find()` = 0,2–1,0 ms (N = 60–150 fenêtres, 20–60 visibles, 3–10 µs/fenêtre dont DWM + `ReadTitle`) → **1–5 ms/s = 0,10–0,50 % cœur** | 60–90 % du CPU W |
| H2 | Les événements du hook global (CREATE/DESTROY/SHOW/HIDE/REDRAW/STATECHANGE top-level + FOREGROUND) ajoutent des `Check()` ; LOCATIONCHANGE est rejeté sans coût (`:93`) | repos 0,2–2 év/s × 0,5–3 ms = 0,01–0,2 % ; rafales 10–100 év/s = pics 0,5–30 % (courts) | 5–30 % du CPU W |
| H3 | Le trim/GC ne coûte quasi rien en régime établi (WS < 32 MiB) ; première passe = 2 GC bloquants + `EmptyWorkingSet` ; passes répétées seulement si WS > 33,55 Mo | régime : < 0,01 % ; 1re passe : 20–80 ms one-shot ; si répétée : 10–50 ms/10 s = 0,10–0,50 % | variable, surtout F/début W |
| H4 | Le timer d'arrêt 1 Hz (launcher/`--attach`) est coûteux : `CheckExitPending` → `IsRiotClientAlive` = 2 × `Process.GetProcesses()` + nom/StartTime par process | 150–250 process : 1,5–4 ms/énumération × 2 = **3–8 ms/s = 0,3–0,8 % cœur** | 0 % en W watch ; jusqu'à ~1 % en launcher sans overlay |
| H5 | GC/allocations de fond négligeables : `ReadTitle` alloue 25–60 Ko/s (gen0 toutes les 1–3 min) ; aucune allocation par frame au repos | < 0,02 % cœur ; pics < 1 ms | marginal |
| H6 | La vérification de mise à jour crée un pic one-shot à T+20 s (HTTP + écriture settings) | 5–50 ms CPU + réseau + disque | F et premières 60 s de W |
| H7 | La cadence réelle des timers (quantum 15,6 ms) et la coalescence expliquent les écarts de ticks, pas une source de CPU | 1 Hz → 1 000–1 016 ms ; 500 ms → 500–516 ms ; 120 ms → 125–141 ms | tous les états |
| H8 | Le coût mesuré par process attribue mal la composition DWM : le rendu de l'overlay coûte aussi dans `dwm.exe` | surface repliée 6,4 Ko ; dépliée 0,48–0,68 Mo → DWM 0,1–2 % pendant les redraws | A/B/C/E : mesurer `dwm.exe` à part |

### 4.2 Tests discriminant

**T1 — Comparer W (5 énumérations/s) et A (1 énumération/s + timers overlay).** Mesurer W1 (Riot fermé), W2 (processus Riot présents sans fenêtre) et A (Riot visible, overlay replié), 180 s chacun.
- Attendu si H1 domine : CPU_W > CPU_A de ≈ 0,08–0,3 % cœur (4 énumérations/s de moins en A, compensées par les timers overlay ≈ 0,02–0,1 %).
- W1 ≈ W2 : l'absence de fenêtre Riot ne change pas le nombre d'énumérations ; une différence signalerait le timer d'arrêt ou un autre effet (mode launcher, `IsRiotClientAlive`).

**T2 — Volume d'événements (churn de fenêtres synthétiques).** Un processus auxiliaire (PowerShell/WinForms) affiche/masque une fenêtre top-level au titre quelconque (jamais « Riot Client ») à 0 ; 0,2 ; 1 ; 2 ; 5 cycles/s, 60 s par palier, en mesurant uniquement RiotSwitch.
- Ajuster CPU = a + b·cadence ; **b = coût par cycle** (≈ nombre d'événements retenus × coût d'un `Check()` = 1–5 énumérations) ; attendu 1–10 ms/cycle ; **a** = CPU de base W (timer + événements de fond).
- Linéarité R² > 0,9 et b dans la fourchette → H2 confirmée ; b très supérieur (≈ 5–15 ms/cycle) → chaque événement coûte plus qu'un `Check()` (marshalling/file d'attente) ; b ≈ 0 → les événements ne déclenchent pas de `Check()` (filtre inattendu).

**T3 — Coût d'`EnumWindows` par fenêtre (test décisif pour H1).** Trois paliers de fenêtres top-level : N0 (bureau minimal, ≈ 15 fenêtres), N1 (+50 fenêtres simples), N2 (+150). Mesurer W 120 s par palier ; régresser CPU sur N.
- Pente attendue = **5 énumérations/s × 3–10 µs/fenêtre** = 15–50 µs/s par fenêtre → +50 fenêtres ≈ +0,075–0,25 % cœur ; +150 ≈ +0,22–0,75 %.
- Comparer le CPU extrapolé à N0 au CPU mesuré : si l'écart est faible, H1 suffit à expliquer W ; sinon chercher M2/M4/M5.

**T4 — Trim/GC.** Séries 1 s : CPU + WS. Signatures attendues : chute de WS > 10 MiB + pic CPU sur la grille de 10 s = trim/GC (H3) ; aucune signature si WS reste < 32 MiB (H3 ≈ 0). Comparer W (trim actif) et A/B (trim sauté) : des pics périodiques présents en W et absents en A/B confirment H3.

**T5 — Timer d'arrêt (launcher/`--attach`).** Instance launcher avec client Riot en tray (processus vivant, fenêtre absente) → `_exitTimer` actif (`WatchContext.cs:184-188`, `:206-221`) ; mesurer 120 s avant/après la disparition de la fenêtre. Attendu si H4 : +0,3–0,8 % cœur, pics à 1 Hz sur le thread UI. En mode watch : **0** différence (timer jamais démarré), ce qui justifie W en `--watch`.

**T6 — Vérification de mise à jour.** Démarrage à froid avec `lastUpdateCheckUtc` > 24 h : échantillonnage 100–250 ms sur 40 s ; attendu pic CPU/réseau vers T+20 s (`WatchContext.cs:81`, `:98`) + ligne de log éventuelle + `lastUpdateCheckUtc` mis à jour. Pour W/A/B : soit `autoCheckUpdates=false` (sauvegarde/restauration de `settings.json`), soit démarrage ≥ 60 s avant et vérification qu'aucune mise à jour n'a eu lieu pendant.

**T7 — Absence de redessin au déplacement (C15).** Dans D, comparer 10 déplacements de 100 px (attendu 0,05–0,2 ms CPU/mouvement) à 10 redimensionnements de ±10 px (attendu 1–4 ms/événement car `UpdateLayered`). Ratio move/resize < 0,5 → conforme ; sinon le chemin « `SetWindowPos` sans redessin » (`OverlayForm.cs:363-377`) n'est pas emprunté.

### 4.3 Règles de décision

- **H1 confirmée** si T3 donne une pente par fenêtre cohérente avec 5 énumérations/s, que T1 (W/A) suit la prédiction et que T4 ne montre ni trim répété ni pics inexpliqués.
- **H2 confirmée** si T2 est linéaire avec b ∈ [1 ; 10] ms/cycle.
- **H3 confirmée** si T4 montre les pics sur la grille de trim et si A/B n'en ont pas.
- **H4 confirmée** si T5 reproduit +0,3–0,8 % et l'absence de l'effet en watch.
- Si W mesuré > 0,6 % et H1–H4 insuffisantes : suspecter (a) churn overlay (log création/destruction), (b) autres agents/build, (c) antivirus/Defender, (d) fréquence de `Check()` supérieure à 1 Hz par événements.

## 5. Protocole de mesure consolidé

### 5.1 Préparation (avant toute mesure)

1. **Périmètre figé** : binaire `dist\RiotSwitch.exe` 1.1.17+fb329029, source HEAD `ac32f18` ; consigner le SHA-256 de l'exe et de `settings.json` ; ne rien rebuilder pendant la campagne.
2. **Instance dédiée `--watch`** : fermer l'instance en mode launcher (PID 30124 = `--launch-riot --ephemeral`, `exitOnClientClose=true` → **exit timer actif, données non comparables**). Lancer `dist\RiotSwitch.exe --watch` ; vérifier le log de démarrage (`watch=True`, `launch=False`, `attach=False`), `Tracker démarré (hook=…, foreground=…)`, un seul PID (mutex `Local\RiotSwitch.Watch`), 0 fenêtre visible du process.
3. **État Riot contrôlé** : W1 = aucun processus Riot ; W2 = processus Riot présents mais aucune fenêtre top-level (client en tray) — W2 est la configuration de `validation.fr.md:74`, W1 sert de contrôle ; A/B/C/D = Riot visible, même rect (ex. 1552×872), même écran, page statique sans animation, client au premier plan ou recouvert < 20 %.
4. **Environnement** : session locale déverrouillée (pas de RDP), DWM actif, mode d'alimentation fixe (performances), DND/notifications activées, aucun autre agent/CI/`dotnet build`/`dotnet test` en cours, pas de jeu plein écran, pas de veille/économiseur ; fermer les consoles et fenêtres inutiles (chaque fenêtre top-level augmente le coût de `Find()`).
5. **Settings** : ne pas modifier `settings.json` sauf nécessité de contrôle (`autoCheckUpdates`) ; sauvegarder, modifier, restaurer, consigner le hash. `overlayPinned=true` est sans effet sur les mesures (verrouille seulement le glisser).
6. **Aucune mesure pendant la première minute** après lancement (JIT, 1re passe de trim à 2 s, vérification de mise à jour à T+20 s) ; attendre la ligne de trim et/ou `lastUpdateCheckUtc` > heure de démarrage.
7. **Instrumentation** : sampler externe de task-1 (`tools/perf/sampler/ProcessSampler.ps1`, compteurs P/Invoke) à 1 s (W/A/B), 250 ms (C), 100–250 ms (F), avec les colonnes du §5.7 ; fallback provisoire `tools/perf/lead/QuickBaseline.ps1` (1 Hz, CSV + JSON) — **ne pas** l'utiliser pour F (le pic de démarrage est manqué) ni pour les latences. Driver de task-2 (`OverlayDriver.ps1`) pour les actions A–E, horodatages QPC pour D.
8. **Contrôle de surcoût** : 60 s de sampler sur un process témoin immobile, comparé au même process sans sampler ; surcoût cible < 0,1 % cœur (max 0,5 % exigé par task-1).

### 5.2 États et échantillonnage

| État | Définition opérationnelle | Durée / échantillonnage | n | Mesures clés |
|---|---|---|---|---|
| **W1** | watch, Riot fermé, aucun overlay | 180 s, 1 Hz (250 ms pour pics) | 3 | CPU intégral, WS/privé, handles/threads, GDI/USER, page faults, IO, logs |
| **W2** | watch, processus Riot sans fenêtre (tray) | 180 s, 1 Hz | 2 | idem (comparaison `validation.fr.md:74`) |
| **A** | Riot visible stable, overlay replié 40 DIP, sans interaction | 180 s, 1 Hz | 3 | CPU, WS, GDI, `dwm.exe` |
| **B** | panneau déplié 380 DIP, sans interaction ni statut | 180 s, 1 Hz | 3 | CPU, WS, GDI, `dwm.exe` |
| **C** | interactions : survol des 5 lignes + boutons, molette 20 crans, pauses | 60 s, 250 ms | 3 | CPU par catégorie, rect/redraw attendus, latence de réaction |
| **D** | suivi de fenêtre Riot : 30 déplacements (+100/−100 px) espacés de 200 ms ; sous-test 10 redimensionnements | 60–90 s | 3 séries | latence QPC par mouvement (p50/p95/max), CPU/mouvement, ratio move/resize |
| **E** | cycles ouverture/fermeture : expand + 100 ms + collapse + 100 ms | 30 cycles (5 de chauffe) | 1 série | CPU/cycle, latences, WS/handles/GDI avant/après |
| **F** | démarrage à froid + création overlay | 5 lancements, 100 ms pendant 40–60 s | 5 | t_overlay, t_trim, pic WS, intégrale CPU, logs |

Ordre recommandé : baseline machine 60 s → W1 → A → B → (répéter W1/A/B 2 fois) → W2 → C → D → E → F. Durée ≈ 50–65 min. **Sérialiser avec les autres agents** : aucun build/driver/sampler d'un autre membre pendant une fenêtre (sauf le sampler de la fenêtre courante).

### 5.3 Formules, unités, incertitudes

- **% d'un cœur** = 100 × ΔCPU / Δt ; ΔCPU = (User + Kernel) via `GetProcessTimes`/`TotalProcessorTime` (unités 100 ns) ; Δt = horloge murale QPC. **Intégrer sur la fenêtre** : 100 × ΣΔCPU_i / ΣΔt_i, jamais la moyenne des % par échantillon.
- **% machine** = % cœur / **16** (`[Environment]::ProcessorCount`) : 0,30 % cœur = 0,019 % machine → arrondi Gestionnaire 0 %.
- **Mo (MiB)** = octets / 1 048 576. Pour « privé », rapporter **deux** grandeurs : `PrivateMemorySize64` (commit privé) et *private working set* (somme des pages non partagées via `QueryWorkingSet`) ; ne pas les mélanger dans un verdict.
- **Latence (D)** : QPC au `SetWindowPos` de la fenêtre Riot (driver) → premier `GetWindowRect` de l'overlay reflétant la nouvelle position (polling 0,1–0,2 ms) ; p50/p95/max sur 30 mouvements.
- **Incertitudes** : résolution de `GetProcessTimes` ≈ 15,6 ms → u(%cœur) ≈ 100 × 0,0156/Δt : **0,009 %** sur 180 s, **0,026 %** sur 60 s, **1,56 %** sur 1 s. Conséquence : les % par échantillon 1 s ne servent qu'à détecter les pics ; le claim CPU se juge sur l'intégrale ≥ 120 s (idéal 180 s). Surcoût sampler à quantifier (cible < 0,1 % cœur). Mémoire : granularité 4 KiB (négligeable). Latence : résolution QPC négligeable, incertitude d'ordonnancement 0,1–1 ms → exiger le p95.
- **Exemple de calcul** : ΔCPU = 0,54 s sur Δt = 180 s → 0,30 % cœur = 0,019 % machine ; médiane WS = 14,2 MiB ; Δ handles = 0.
- **Bandes de verdict** (claim « ≈ ») : CPU W ∈ [0,15 ; 0,50] % cœur ; WS ∈ [9 ; 17] MiB ; privé commit ∈ [12 ; 18] MiB ; pic démarrage ∈ [45 ; 80] MiB ; latence p95 ≤ 2 ms ; réassertion ≤ 700 ms.

### 5.4 Biais et contrôles

| Biais | Effet | Contrôle / mitigation |
|---|---|---|
| **Composition DWM** | le rendu/`UpdateLayeredWindow` coûte aussi dans `dwm.exe` ; le CPU du process seul sous-estime le coût système | mesurer `dwm.exe` (et le total machine) en parallèle en A/B/C/E ; rapporter « CPU RiotSwitch » et « CPU système » séparément |
| **Animations Riot/Electron** | LOCATIONCHANGE en rafale → callbacks overlay ; CPU Riot attribué à tort | page statique, pas de déplacement/redimensionnement Riot hors D ; mesurer aussi le CPU Riot et ne pas l'imputer |
| **Autres agents / build / CI / DSH** | pics machine pendant les fenêtres | sérialiser ; consigner les process actifs ; jeter la fenêtre si le CPU machine au repos dépasse 5 % |
| **Cadence WM_TIMER ≈ 15,6 ms** | périodes réelles +0–15,6 ms ; nb de ticks inférieur au nominal | compter les ticks réels (série), utiliser les deltas mesurés, jamais les valeurs nominales pour un coût/événement |
| **Arrondi DIP / échelle** | 40 DIP = 40/50/60 px ; 380 DIP = 380/475/570 px ; aire × s² | consigner `GetDpiForWindow`/échelle et les rects en px **et** DIP ; ne comparer qu'à échelle identique |
| **Trim / page faults** | `EmptyWorkingSet` pagine ; pics CPU/IO et défauts de page ensuite | mesurer les page faults ; ne pas mesurer < 30 s après un trim ; rapporter le nombre de passes |
| **Mise à jour auto (T+20 s)** | pic CPU/réseau/disque one-shot | désactiver (`autoCheckUpdates=false`, avec sauvegarde/restauration) ou attendre la fin et vérifier `lastUpdateCheckUtc` hors fenêtre |
| **JIT / 1er rendu / cache GDI+** | surcoût one-shot au démarrage et au 1er affichage | F : répéter 5 fois ; E : ignorer le 1er cycle (chauffe) |
| **Arrondi du Gestionnaire** | 0,3 % cœur = 0,019 % machine → 0 % affiché | ne jamais utiliser le Gestionnaire comme instrument ; calculer % machine |
| **Fréquence/boost, cœurs P/E** | CPU time ≠ cycles ; sensibilité à la charge | plan d'alimentation fixe, aucune charge parallèle, même session |
| **Moniteurs/DPI multiples** | `GetDpiForWindow` dépend du moniteur ; taille en px | Riot et overlay sur le même moniteur, config consignée |
| **Session verrouillée / RDP** | DWM/affichage différents | session locale déverrouillée uniquement |
| **Toasts / création de fenêtres** | chaque fenêtre top-level = événement → `Check()` | DND/Focus Assist, fermer chats/notifications, aucune console ouverte pendant W/A/B |
| **Survol de l'overlay** | redessine à chaque transition | souris garée hors overlay en A/B ; D utilise le driver, pas la souris |
| **Antivirus/Defender, indexation** | I/O et CPU parasites | consigner ; éviter les écritures massives ; ne pas rebuild |

### 5.5 Checks de validité (à appliquer fenêtre par fenêtre)

1. **Identité** : 1 seul PID, exe = hash attendu, cmdline `--watch`, version 1.1.17, hash de `settings.json` inchangé ; log de démarrage cohérent.
2. **État** : rects overlay et Riot identiques au début et à la fin ; aucune ligne de log « création de l'overlay » / « fenêtre Riot Client absente » / « overlay affiché » dans la fenêtre (sauf E/F) ; aucun trim en A/B ; en W, au plus une passe de trim et aucune dans les 30 s précédant le début.
3. **Série** : aucun trou > 2 × intervalle ; `TotalProcessorTime` monotone ; dérive d'horloge < 1 % ; premier/dernier échantillon hors transitions.
4. **Stationnarité** : tiers de fenêtre ; |moyenne(T1) − moyenne(T3)| ≤ 20 % de la moyenne (ou ≤ 0,05 % cœur si la valeur est très petite) ; sinon décaler la fenêtre et refaire.
5. **Bruit machine** : CPU machine au repos ≥ 95 % libre avant la campagne ; si un build/test d'un autre agent démarre pendant une fenêtre → fenêtre invalidée et rejouée.
6. **Surcoût d'instrumentation** : sampler < 0,1 % cœur sur un process témoin ; cross-check `GetProcessTimes` vs `typeperf`/`Get-Counter` < 3 %.
7. **Ressources** : handles/GDI/USER stables (pas de croissance monotone > 5 % entre A/B/E) ; threads dans la fourchette attendue (≈ 8–12).
8. **F** : distinguer démarrage « froid » (≥ 120 s après l'arrêt précédent, pas de rebuild) ; noter que le cache OS ne peut pas être vidé sans redémarrage (limite à documenter).

### 5.6 Ce qu'il faut éviter (pour ne pas perturber la mesure)

- Mesurer l'instance launcher (`--launch-riot --ephemeral`) ou `--attach` pour W/A/B (timer d'arrêt 1 Hz).
- Cliquer, survoler ou déplacer l'overlay pendant A/B ; ouvrir les Paramètres (dialogue bloquant + relecture) ; lancer un switch de compte.
- Déplacer/minimiser/restaurer la fenêtre Riot pendant W/A/B/C (hors D) ; redimensionner le client hors sous-test (redraw).
- Lancer un build/test/publish, le sampler ou le driver d'un autre agent pendant une fenêtre ; laisser DSH/CI/Defender travailler.
- Laisser des consoles, éditeurs, toasts ou notifications créer/afficher des fenêtres pendant W/A/B.
- Mesurer dans les 60 premières secondes (JIT, trim, update) ou juste après un trim.
- Utiliser le Gestionnaire des tâches comme instrument, ou moyenner des % par échantillon 1 s pour le CPU.
- Changer le mode d'alimentation, la résolution/échelle, verrouiller la session, passer en RDP, lancer un jeu plein écran.
- Modifier `settings.json` sans sauvegarde/restauration ni hash ; rebuilder le binaire entre deux états.
- Oublier de consigner le nombre de fenêtres top-level et l'échelle DPI : sans eux, le CPU W n'est pas interprétable.

### 5.7 Données et livrables

- **CSV brut par fenêtre** (`tools/perf/results/`), une ligne par échantillon : `utc_iso, elapsed_s, state, run_id, cpu_total_s, cpu_user_s, cpu_kernel_s, cpu_pct_core_interval, ws_bytes, private_commit_bytes, private_ws_bytes, peak_ws_bytes, handles, gdi_objects, user_objects, threads, io_read_bytes, io_write_bytes, page_faults, dwm_cpu_total_s, notes`.
- **JSON de synthèse par run** : intégrale CPU/Δt → % cœur/% machine ; WS/privé min/médiane/max ; handles/threads min/max ; rects overlay/Riot en px + DIP ; échelle ; N fenêtres top-level ; durée ; nombre de passes de trim ; latences D (p50/p95/max).
- **Journal** : copie de `%LOCALAPPDATA%\RiotSwitch\logs\app.log` sur la plage de mesure + `settings.json` et hashes.
- **Rapport final (task-4)** : `docs/perf/rapport-performance.fr.md`, comparaison aux bandes §5.3, verdict par claim C1–C15, causes des écarts, recommandations (docs à corriger : timer 2 s, définition « privé », formulation 4 s).
- Aucune modification de code/settings pendant la campagne (hors sauvegarde/restauration contrôlée) ; aucun commit.

## 6. Écarts code/docs et points à trancher (récapitulatif)

| # | Constat | Source | Action proposée |
|---|---|---|---|
| 1 | claims perf dans `dist/README.md`, absents du `README.md` racine | `README.md:101` ; `dist/README.md:94, :239` | aligner racine/dist/util sur les valeurs mesurées |
| 2 | timer tracker documenté 2 s, codé 1 s | `architecture.fr.md:39` vs `RiotWindowTracker.cs:43` ; `validation.fr.md:154` | corriger l'architecture après la campagne |
| 3 | « privé » ambigu (commit vs *private working set*) | `WatchContext.cs:281-286` ; `validation.fr.md:17, :74` | mesurer les deux, fixer la définition, corriger si besoin |
| 4 | « CPU 0 % sur 4 s » non concluant | `validation.fr.md:79` | remplacer par une borne ≥ 120–180 s |
| 5 | bande morte du trim 16–32 MiB | `WatchContext.cs:267` | documenter « après compactage, sans activité » ; rapporter la distribution |
| 6 | checklist perf encore vide | `validation.fr.md:246` | clôturer par la campagne (état W mesuré) |
| 7 | log trim : `privée=24 Mo` en launcher (2026-11-10T22:13:24Z) | log local | vérifier en watch et trancher la définition |
| 8 | Riot client instable (fenêtre détectée/absente à répétition dans les logs du 2026-11-10) | log local | préparer une fenêtre stable avant A/B ; invalider les fenêtres avec churn |

## 7. Annexes

### A. Matrice état × mécanismes actifs

| Mécanisme | W1/W2 | A | B | C | D | E | F |
|---|---|---|---|---|---|---|---|
| Timer fallback tracker 1 Hz | oui | oui | oui | oui | oui | oui | oui |
| Hooks tracker (0x8000–0x800B) | oui | oui | oui | oui | oui | oui | oui |
| Trim/GC + `EmptyWorkingSet` | oui | — | — | — | — | — | 1re passe |
| Timer exit 1 Hz | — (watch) | — | — | — | — | — | — |
| Timer position 500 ms | — | oui | oui | oui | oui | oui | — |
| Timer extérieur 120 ms | — | — | oui | oui | — | oui (déplié) | — |
| Timer statut one-shot | — | — | — | oui | oui | oui | — |
| Hook overlay LOCATIONCHANGE | — | oui | oui | oui | oui | oui | — |
| Hook overlay FOREGROUND | — | oui | oui | oui | oui | oui | — |
| Rendu GDI+ / `UpdateLayeredWindow` | — | 1 × (show) | 1 × (expand) | à chaque transition | resize seulement | 2 ×/cycle | oui (création) |
| Update check HTTP | one-shot | — | — | — | — | — | one-shot |
| Log / allocations de fond | oui | oui | oui | oui | oui | oui | oui |

### B. Checklist opérateur

**Avant** : [ ] instance `--watch` dédiée ; [ ] 1 PID ; [ ] Riot dans l'état attendu ; [ ] session déverrouillée ; [ ] DND ; [ ] autres agents prévenus ; [ ] sampler/driver prêts ; [ ] hash `settings.json` ; [ ] baseline machine 60 s.
**Pendant** : [ ] sampler démarré avant l'action ; [ ] actions driver horodatées ; [ ] état vérifié début/fin ; [ ] aucune interaction parasite ; [ ] log copié.
**Après** : [ ] 3 runs W/A/B ; [ ] latences D (30) ; [ ] E (30 cycles) ; [ ] F (5) ; [ ] checks §5.5 ; [ ] résultats rangés ; [ ] settings restaurés.

### C. Lexique

WS = `WorkingSet64` ; privé commit = `PrivateMemorySize64` ; *private WS* = pages non partagées ; % cœur = un processeur logique à 100 % ; % machine = % cœur / 16 ; DIP = unité indépendante du DPI (96 DPI = 1,0) ; QPC = `QueryPerformanceCounter` ; OUTOFCONTEXT = hook asynchrone livré au thread installeur ; SKIPOWNPROCESS = pas d'événements du process lui-même ; LOCATIONCHANGE = 0x800B.

### D. Constats de logs existants (lecture seule, à ne pas surinterpréter)

- `%LOCALAPPDATA%\RiotSwitch\logs\app.log` : lignes de trim `Veilleur : mémoire de travail compactée (working set=1 Mo, privée=24 Mo).` ; créations/destructions d'overlay répétées (fenêtre Riot détectée puis « absente » après 5–11 s) — signe soit d'un client Riot instable (Electron), soit de tests d'autres agents ; à rejouer et contrôler.
- L'instance PID 30124 tourne en `--launch-riot --ephemeral` : ne pas l'utiliser pour W (exit timer actif).
- Ces constats ne sont pas des mesures de campagne ; ils motivent les checks du §5.5.

---

*Audit statique réalisé en lecture seule le 2026-11-11 ; aucune mesure live, aucune interaction avec l'instance en cours, aucune modification hors `docs/perf/`.*
