# Vérification indépendante — RiotSwitch (phase A)

Harnais du rôle **verifier** de la campagne de mesure de performance RiotSwitch.
Objectif : **vérifier sans faire confiance aux outils du Lead** (`tools/perf/sampler`,
`tools/perf/driver`, `tools/perf/probe`). Tout le code de ce dossier a été écrit
indépendamment : aucun `using`/dot-source vers les outils des autres équipiers.

Version : **1.0.0** — 2026-11-11 (phase A : construction + auto-tests).
État : **auto-tests PASS ; en attente du GO du Lead pour la phase B**.

---

## 1. Périmètre et garanties de sécurité

Ce harnais **ne touche pas à l'application** :

- aucune interaction UI : pas de clic, pas de `SetForegroundWindow`, pas de
  déplacement/redimensionnement/minimisation de fenêtre, pas de simulation de
  touches ou de souris ;
- aucun processus n'est démarré, arrêté ou tué (Riot, RiotSwitch, Riot Client,
  etc. restent intacts) ; le seul processus lancé est le **processus factice
  interne** de l'auto-test `IndependentMeasure -SelfTest`, tué par le script
  lui-même en fin de test ;
- lecture seule du log applicatif (`FileShare.ReadWrite | Delete`, car le
  logger garde le fichier ouvert) et **lecture passive** de la liste des
  fenêtres (`EnumWindows` + `GetWindowRect`, aucune modification) ;
- écritures limitées à `tools/perf/verify/results/` (et
  `tools/perf/verify/.selftest/`, transitoire). Rien n'est écrit dans `src/`,
  `dist/`, ni dans `tools/perf/sampler|driver|probe|results|run`.

En phase A, **aucune mesure réelle n'est effectuée sur RiotSwitch** : les
mesures ont uniquement porté sur un processus factice. `IndependentMeasure.ps1`
refuse par ailleurs de mesurer un processus de la famille Riot
(RiotSwitch, Riot Client/ClientServices/CrashHandler, LeagueClient, VALORANT,
UX, etc.) sans le commutateur explicite `-AllowAppProcess`, qui n'est à utiliser
qu'en phase B **après le GO**.

---

## 2. Contenu du dossier

| Fichier | Rôle |
|---|---|
| `IndependentMeasure.ps1` | Mesure CPU/RAM/GDI/handles d'un processus par 2 méthodes indépendantes + cross-check ; CSV + JSON. |
| `Verify-Probe.ps1` | Latences « détection fenêtre Riot → overlay affiché » depuis le log + détection de la fenêtre overlay par P/Invoke maison + cross-check log ↔ fenêtres. |
| `results/` | Sorties horodatées des exécutions (CSV + JSON). |
| `.selftest/` | Exécutable factice transitoire de l'auto-test (supprimé en fin d'auto-test). |
| `README.md` | Ce document. |

En phase B uniquement, une synthèse pourra être publiée dans
`docs/perf/verification.fr.md` (hors phase A).

---

## 3. Environnement et conventions

- Windows, **PowerShell 5.1 Desktop** (`powershell.exe`, pas `pwsh`).
- Culture machine `fr-FR` (décimaux à virgule, noms de compteurs et de
  catégories localisés en français) : **tous les CSV et JSON de sortie sont
  écrits en culture invariante** (point décimal), indépendamment de la culture
  de la session.
- Les scripts sont enregistrés en **UTF-8 avec BOM** (obligatoire : PS 5.1 lit
  un `.ps1` UTF-8 sans BOM comme de l'ANSI et casse les accents présents dans
  les regex du log).
- Les noms de compteurs de performance sont **découverts dynamiquement**
  (aucun `\Processus(...)` codé en dur) pour rester valides sur un Windows
  francophone comme anglophone.
- 16 cœurs logiques sur la machine de campagne : un « % temps processeur » de
  100 % représente **un** cœur logique, pas la machine entière.

---

## 4. `IndependentMeasure.ps1` — CPU, RAM, GDI, handles

### 4.1 Moyens de mesure (deux méthodes distinctes, simultanées)

**Méthode A — compteurs de performance Windows (PDH)**
`Get-Counter` sur le jeu de compteurs processus. Découverte dynamique :

1. `Get-Counter -ListSet *` → recherche du jeu dont le nom normalisé
   (minuscules, accents retirés) contient `process|processus` ;
2. dans ce jeu, sélection des chemins dont le nom normalisé correspond à
   `% temps processeur | % processor time` (en excluant `% temps privilégié`,
   `% temps utilisateur`, `% temps d'inactivité`, `% temps d'interruption`,
   `% temps DPC`, `% temps système`), `plage de travail | working set`,
   `octets privés | private bytes`, `nombre de handles | handle count` ;
3. résolution de l'**instance de performance** du PID :
   `Get-CimInstance Win32_PerfFormattedData_PerfProc_Process -Filter "IDProcess = <pid>"`
   → propriété `Name` (repli `Get-WmiObject`, puis nom unique), car un même
   nom de processus peut recevoir un suffixe `#N` ;
4. collecte dans un **runspace dédié** (`[powershell]::Create()` +
   `BeginInvoke`) avec `MaxSamples = N + 2`, en parallèle de la méthode B.

**Méthode B — échantillonnage direct `Get-Process` à 1 Hz**
`TotalProcessorTime`, `WorkingSet64`, `PrivateMemorySize64`, `HandleCount`,
`Threads.Count`, plus `GetGuiResources` (P/Invoke `user32.dll`,
`OpenProcess(PROCESS_QUERY_INFORMATION=0x400)` avec repli
`PROCESS_QUERY_LIMITED_INFORMATION=0x1000`, `GR_GDIOBJECTS=0`,
`GR_USEROBJECTS=1`).

### 4.2 Formules

- **CPU % (d'un cœur logique)** :
  `ΔTotalProcessorTime / Δtemps_mural × 100`, où `ΔTotalProcessorTime` est la
  différence de temps CPU cumulé entre deux échantillons et `Δtemps_mural` la
  différence d'horloge murale mesurée par le harnais. La valeur peut dépasser
  100 % si le processus occupe plusieurs cœurs.
- **RAM** : `WorkingSet64 / 1 MiB` (ensemble de travail) et
  `PrivateMemorySize64 / 1 MiB` (octets privés / commit privé).
- **GDI / USER** : nombre d'objets GDI et USER du processus.
- **Statistiques** (séries de latences ou de mesures) : `Count`, `Min`, `Mean`,
  `Median`, `P95` (indice `ceil(0.95×n)-1`, borné), `Max`, `StdDev`
  (écart-type de population, division par `n`).

### 4.3 Cross-check des deux méthodes

Les deux méthodes mesurent la **même fenêtre temporelle** ; le premier
échantillon de chaque série est exclu (chauffe PDH des compteurs de type
taux). Le cross-check compare les **moyennes des échantillons 2..N** :

| Grandeur | Écart relatif | Plancher de bruit |
|---|---|---|
| CPU | `|A−B| / max(|A|,|B|) ≤ 5 %` | 0,5 point de pourcentage |
| Working set | `|A−B| / max(|A|,|B|) ≤ 5 %` | 2 MiB |

Si l'écart relatif est sous 5 % → `PASS` (mode `relative`). Sinon, si l'écart
absolu est sous le plancher de bruit → `PASS` en mode `plancher-de-bruit`
(valeurs très faibles où un pourcentage n'a pas de sens). Sinon → `FAIL` avec
l'écart affiché et journalisé ; la mesure est marquée non fiable, le script
sort en code 5. Si les compteurs sont indisponibles, le cross-check est
`UNAVAILABLE` (code 6) ; avec `-SkipCounterCrossCheck`, il est `SKIPPED`.

### 4.4 Usage

```powershell
# Auto-test complet (processus factice, AUCUNE mesure réelle) :
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tools\perf\verify\IndependentMeasure.ps1 -SelfTest

# Mesure d'un processus non-Riot (dépannage, phase A) :
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tools\perf\verify\IndependentMeasure.ps1 `
    -ProcessName notepad -DurationSec 30 -IntervalSec 1 -Tag essai

# PHASE B UNIQUEMENT, après le GO et en série (une seule mesure à la fois) :
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tools\perf\verify\IndependentMeasure.ps1 `
    -ProcessName RiotSwitch -AllowAppProcess -DurationSec 60 -IntervalSec 1 -Tag W
```

Paramètres : `-ProcessName` (défaut `RiotSwitch`), `-ProcessId`,
`-DurationSec` (5..3600, défaut 60), `-IntervalSec` (0,2..10, défaut 1,0),
`-Tag`, `-OutDir` (défaut `tools/perf/verify/results`), `-AllowAppProcess`,
`-SkipCounterCrossCheck`, `-SelfTest`, `-KeepSelfTestArtifacts`.

### 4.5 Sorties

Dans `results/`, pour chaque mesure :
`independent-measure-<yyyyMMdd-HHmmss>[-<tag>]-direct.csv`,
`...-counters.csv`, `...json`. Champs principaux : horodatage UTC, PID,
nom, durée, intervalle, nombre d'échantillons, série directe
(`timestampUtc`, `cpuPercentOneCore`, `workingSetMb`, `privateMb`,
`handleCount`, `threadCount`, `gdiObjects`, `userObjects`), série compteurs
(`cpuPercent`, `workingSetMb`, `privateMb`, `handleCount`), statistiques des
deux séries, bloc `crossCheck` (`status`, `passBy`, `cpu`, `workingSet`,
`notes`), bloc `harness` (surcoût CPU du harnais), culture, hôte, version.

### 4.6 Codes de sortie

`0` OK · `1` erreur inattendue · `2` processus introuvable · `3` garde de phase
(processus Riot sans `-AllowAppProcess`) · `4` mesure interrompue (processus
terminé pendant la mesure — le CSV/JSON partiels sont écrits) · `5` cross-check
en échec · `6` compteurs indisponibles · `7` auto-test en échec.

### 4.7 Auto-test phase A (résultats)

Exécuté le 2026-11-11 (`-SelfTest`), processus factice `RSV34b5d61c.exe`
(~70 % d'un cœur, ~109,6 Mo de WS). Deux exécutions successives ont donné des
résultats cohérents (fourchette sur deux runs : écart CPU 0,06–0,09 %,
WS 0,00 %, surcoût 1,95–2,19 %) :

- 20/20 échantillons directs, gigue d'ordonnancement moyenne 0,006 ms
  (max 0,012 ms) ;
- CPU direct : min 59,745 / moy 64,658 / méd 64,420 / p95 68,260 / max 69,009
  (% d'un cœur) ; WS 109,578–109,586 Mo ; privé 107,754 Mo ; handles 189 ;
  GDI 0 (processus console .NET sans objet GDI — normal) ;
- compteurs : 22 échantillons, CPU moy 64,709 %, WS moy 109,584 Mo ;
- **cross-check PASS** : CPU 64,608 vs 64,567 → écart 0,06 % ;
  WS 109,584 vs 109,584 Mo → écart 0,00 % ;
- **surcoût du harnais : 2,186 % d'un cœur** (0,438 s CPU / 20,013 s) ;
- robustesse : arrêt du processus en cours de mesure → CSV/JSON partiels
  écrits, `aborted=true`, code 4 (vérifié sur un second processus factice) ;
- **verdict : SELFTEST PASS** (code 0).

---

## 5. `Verify-Probe.ps1` — latences overlay et fenêtres

### 5.1 Source des latences : le log applicatif

Fichier par défaut :
`%LOCALAPPDATA%\RiotSwitch\logs\app.log`, archives `app.log.1`, `.2`, `.3`
(inclues avec `-IncludeRotated`, triées par date de dernière écriture).
Format des lignes (écrit par `FileLogger`, UTC) :

```
2026-11-10T13:26:55.8451512+00:00 [INFO] message
```

Messages suivis (regex ancrées, accents littéraux) :

| Événement | Message |
|---|---|
| détection fenêtre Riot | `Tracker : fenêtre Riot Client détectée hwnd=<n>[ pid=<n> rect=(x,y,WxH)].` |
| création overlay | `WatchContext : création de l'overlay.` |
| construction | `WatchContext : overlay construit, affichage.` |
| affichage | `WatchContext : overlay affiché (handle=<n>, visible=True/False, created=True/False).` |
| disparition Riot | `Tracker : fenêtre Riot Client absente.` |
| minimisation / focus | `Tracker : fenêtre Riot Client minimisée détectée ...` / `... sans focus ...` (comptées à part, elles **ne** déclenchent **pas** de cycle de latence) |

Le format historique du log (avant l'ajout de `pid=`/`rect=`) est toléré : les
lignes `détectée hwnd=<n>.` sont reconnues et les champs `pid`/`rect` restent
vides dans les CSV. Les fichiers rotatifs contiennent 61 détections de ce type
(232 créations d'overlay au total sur les archives). Une ligne finale
incomplète (écriture en cours) est ignorée et comptée `partialTail`, pas comme
erreur de parsing.

Appariement des événements en cycles : `detect → created → built → shown`.
Statuts : `complete` ; `abandoned-absent` (disparition Riot avant affichage) ;
`abandoned-new-detect` (nouvelle détection avant affichage, ex. rafale de
réaffichages) ; `partial-end` (cycle ouvert en fin de log). Les événements
orphelins sont comptés séparément.

Latences calculées (ms) :

- **principale : `detect → shown`** (détection fenêtre Riot → overlay affiché) ;
- décomposition : `detect → created`, `created → built`, `built → shown`.

Les latences négatives sont comptées (`NegativeCount`) et les valeurs
supérieures à `-MaxLatencyMs` (défaut 10 000 ms) sont exclues des statistiques
(`TooLongCount`).

### 5.2 Détection de la fenêtre overlay (P/Invoke maison, sans driver)

`EnumWindows` + `GetWindowTextLength`/`GetWindowText`, `GetClassName`,
`IsWindowVisible`, `GetWindowRect`, `GetWindowThreadProcessId`, `GetWindow`
(`GW_OWNER`), `GetWindowLongPtr` (`GWL_EXSTYLE`, dispatch 64/32 bits).

Règles de classification (conformes au code source de l'application) :

- **overlay** : titre exact `RiotSwitch` (comparaison ordinale, casse
  respectée), processus `RiotSwitch` (comparaison ordinale insensible à la
  casse), fenêtre **visible** ;
- **client Riot** : titre exact `Riot Client`, processus `Riot Client`,
  fenêtre **visible** ;
- informations complémentaires relevées : rectangle physique, `ExStyle`
  (dont `WS_EX_LAYERED=0x80000`, `WS_EX_TOOLWINDOW=0x80`,
  `WS_EX_NOACTIVATE=0x8000000`), fenêtre propriétaire (`owner`) et son
  processus — l'overlay est attaché au client Riot par `ShowAttached`.

Cross-check log ↔ fenêtres : sur la dernière paire complète, les handles du
log (`overlay affiché handle=...`) sont comparés aux fenêtres réellement
observées ; on vérifie aussi `visible`, la présence de `WS_EX_LAYERED` et
`WS_EX_TOOLWINDOW`, et `owner = client Riot`. Statuts : `PASS`, `MISMATCH`,
`WINDOWS-ABSENT` (aucune fenêtre correspondante), `NO-PAIR` (rien à
comparer). Un `MISMATCH` ne fait sortir en code 6 qu'avec `-StrictWindows`
(informatif en phase A, car aucune exigence de cohérence n'est imposée hors
GO).

### 5.3 Modes

| Mode | Description |
|---|---|
| `Analyze` (défaut) | Analyse le(s) log(s), calcule les latences, écrit `-pairs.csv` + `.json`, cross-check fenêtres. |
| `Snapshot` | Instantané passif de la liste des fenêtres à l'instant T (overlay, client Riot), verdict `PASS`/`NO-OVERLAY`/`NO-RIOT-CLIENT`. |
| `Watch` | Scrutation passive pendant `-DurationSec` s (`-PollMs`, défaut 250 ms) : transitions `riot-appear/disappear`, `overlay-appear/disappear`, latence observée entre première vue Riot et première vue overlay, comparaison avec la dernière paire du log (tolérance `2×PollMs + 100` ms) ; sorties `-watch-<stamp>.json` et `-transitions.csv`. Les fenêtres déjà présentes au démarrage constituent la ligne de base et ne comptent **pas** comme transition. |
| `SelfTest` | Auto-test : EnumWindows/P-Invoke (≥1 fenêtre, une fenêtre visible crédible avec pid/process/rect/ExStyle) + analyse du log réel (0 ligne non parsée, ≥1 détection, ≥1 cycle complet, validations CSV/JSON, décimales invariantes) ; artefacts supprimés sauf `-KeepSelfTestArtifacts`. |

Paramètres : `-Mode`, `-LogPath` (fichier ou dossier), `-IncludeRotated`,
`-DurationSec` (défaut 30), `-PollMs` (défaut 250), `-MaxLatencyMs`
(défaut 10000), `-OutDir`, `-Tag`, `-ExpectOverlay`, `-ExpectRiotClient`,
`-StrictWindows`, `-KeepSelfTestArtifacts`, `-Quiet`.

### 5.4 Usage

```powershell
# Auto-test (log existant + EnumWindows, lecture passive) :
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tools\perf\verify\Verify-Probe.ps1 -Mode SelfTest

# Analyse du log courant + archives rotatives :
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tools\perf\verify\Verify-Probe.ps1 -Mode Analyze -IncludeRotated -Tag phaseA

# Instantané passif des fenêtres, avec exigences :
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tools\perf\verify\Verify-Probe.ps1 -Mode Snapshot -ExpectOverlay -ExpectRiotClient

# Observation de transitions (ex. 30 s) :
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tools\perf\verify\Verify-Probe.ps1 -Mode Watch -DurationSec 30 -PollMs 250 -Tag go-W
```

### 5.5 Codes de sortie

`0` OK · `1` erreur inattendue · `2` log absent ou vide · `3` usage invalide ·
`4` auto-test en échec · `5` attente `-Expect*` non satisfaite ·
`6` incohérence fenêtre stricte (`-StrictWindows`).

### 5.6 Auto-test phase A (résultats)

Exécuté le 2026-11-11, log réel + fenêtres réelles (lecture passive
uniquement) :

- log courant `app.log` : 5 225 lignes, **0 ligne non parsée**,
  143 détections / 143 créations / 143 constructions / 143 affichages,
  143 cycles complets, 0 orphelin, 0 partiel ;
- latence `detect → shown` (n = 143) : **min 7,236 ms / moy 25,008 ms /
  méd. 17,554 ms / p95 62,014 ms / max 88,026 ms / écart-type 17,269 ms** ;
  décomposition : détection→création 1,135 ms de moyenne,
  création→construction 1,004 ms, construction→affichage 22,869 ms ;
- avec `-IncludeRotated` (archives + log courant, 2026-11-09 → 2026-11-11) :
  234 détections, 231 cycles complets, 3 détections abandonnées par une
  nouvelle détection (réaffichages), **0 orphelin** ; latence
  min 7,236 / moy 29,749 / méd 20,152 / p95 71,526 / max 91,742 ms ;
- cross-check fenêtres : **PASS** à chaque exécution (overlay observé
  `hwnd=3934262`, visible, `ExStyle=0x8090080` — contient bien
  `WS_EX_LAYERED|WS_EX_TOOLWINDOW|WS_EX_NOACTIVATE` — owner = client Riot
  `hwnd=23791988`) ;
- instantané : 470 fenêtres de premier niveau (285 avec titre),
  1 overlay + 1 client Riot ; `-ExpectOverlay -ExpectRiotClient` → PASS ;
- `Watch -DurationSec 10` : 20 scrutations, 0 erreur, 0 transition
  (fenêtres déjà présentes → ligne de base), verdict PASS ;
- **verdict : SELFTEST PASS** (code 0).

---

## 6. Protocole phase B proposé (à valider par le Lead ; après GO uniquement)

Prérequis : ordre explicite du Lead, **mesures strictement sérialisées**
(aucune autre mesure/outil de campagne en cours), application non
redémarrée par le verifier, état de l'app indiqué par le Lead pour chaque
point de mesure (W = veille seule, A/B = variantes à comparer, etc.).

1. Vérifier le harnais : `Verify-Probe.ps1 -Mode SelfTest` → exit 0.
2. Relever l'état des fenêtres avant mesure :
   `Verify-Probe.ps1 -Mode Snapshot -Tag <état>`.
3. Mesurer le processus (une mesure à la fois, 60 s par défaut) :
   `IndependentMeasure.ps1 -ProcessName RiotSwitch -AllowAppProcess -DurationSec 60 -IntervalSec 1 -Tag <W|A|B>` → exiger
   `crossCheck.status = PASS` (sinon investiguer avant d'exploiter les chiffres).
4. Si le scénario prévoit une transition d'overlay : lancer
   `Verify-Probe.ps1 -Mode Watch -DurationSec <n> -ExpectOverlay -Tag go-<état>`
   *avant* l'action du Lead (ou attendre le cycle déclenché par le Lead), puis
   relever `observedLatencyMs` et la comparaison log/observe.
5. Après la campagne : `Verify-Probe.ps1 -Mode Analyze -IncludeRotated`
   pour la distribution complète des latences des états traversés.
6. Rapporter au Lead : chiffres par état, cross-checks, écarts, incertitudes,
   limites ; en cas de désaccord avec les outils du Lead, fournir les CSV/JSON
   du dossier `results/` comme preuve indépendante.

Règles à ne pas enfreindre : ne jamais tuer Riot/RiotSwitch, ne pas
redémarrer l'app, ne pas interagir avec l'UI, ne pas mesurer en parallèle
d'une autre mesure, ne pas modifier `src/` ni `dist/`.

---

## 7. Tolérances, limites et pièges connus

- **Cross-check CPU/WS** : tolérance 5 % (relatif) ou plancher de bruit
  (0,5 pp CPU, 2 MiB WS). En dessous de ces planchers, un pourcentage d'écart
  n'est pas significatif. Le cross-check porte sur les moyennes hors premier
  échantillon : une mesure courte (ou très variable) peut donc différer
  légèrement de la moyenne complète.
- **CPU** : exprimé en % d'**un cœur logique** (100 % = un cœur à pleine
  charge). Un facteur 16 est nécessaire pour un % machine.
- **PDH** : le premier échantillon d'un compteur de taux vaut souvent 0
  (chauffe) ; il est exclu du cross-check. Les compteurs peuvent être
  indisponibles (permissions, WMI/CIM en échec) → code 6, mesure directe
  toujours exploitable.
- **GDI/USER** : `GetGuiResources` peut échouer sur un processus protégé
  (renvoie 0) ; 0 est aussi une valeur légitime pour un processus sans objet
  GDI (ex. console). Ne pas interpréter 0 comme une preuve d'absence de fuite
  sans le croiser avec les compteurs `Nombre de handles`.
- **Ordonnancement** : gigue mesurée de l'ordre de quelques dizaines de µs
  par échantillon à 1 Hz ; négligeable devant les latences d'overlay mais à
  rappeler pour des moyennes très courtes.
- **Surcoût du harnais** : ~1,95 % d'un cœur pour la mesure combinée
  compteurs + 1 Hz (mesuré sur factice 20 s). À prendre en compte si le
  processus mesuré est lui-même à ~1 % d'un cœur.
- **Logs** : horodatages UTC. Un cycle dont la détection est antérieure à
  l'archive la plus ancienne conservée n'est pas reconstituable (orphelin
  possiblement absent) ; les archives `app.log.*` sont lues dans l'ordre
  chronologique. Une rotation pendant une veille peut produire `NO-DATA`.
  Les paires abandonnées (rafales de réaffichages, disparition du client)
  sont exclues des latences et comptées à part — ne pas les confondre avec
  des mesures manquantes.
- **Fenêtres** : `EnumWindows` ne voit que les fenêtres de bureau de la
  session interactive courante ; un processus élevé (UAC) peut empêcher la
  résolution de son nom (`ProcessName` vide) et donc sa classification. Les
  rectangles sont en pixels physiques (la conscience DPI du processus
  PowerShell hôte peut nuancer l'interprétation sur écran mis à l'échelle).
  Un overlay rendu invisible (ou absent) est correctement rapporté
  `NO-OVERLAY` ; `-ExpectOverlay` transforme cela en code 5.
- **`Watch`** : résolution limitée à `PollMs` (250 ms par défaut) ; la
  tolérance log/observé (`2×PollMs+100`) absorbe cette granularité. Les
  fenêtres présentes au démarrage sont la ligne de base (pas de transition à
  t0) ; une fenêtre qui apparaît et disparaît entre deux scrutations peut
  être manquée.
- **Culture** : les CSV/JSON sont en culture invariante (point décimal), les
  affichages console suivent la culture de la session (`fr-FR`, virgule). Ne
  pas parser la console pour des chiffres.
- **Encodage** : conserver le BOM UTF-8 des `.ps1` (sinon accents des regex
  log cassés en PS 5.1) ; ne pas réécrire ces scripts avec un éditeur
  supprimant le BOM.

---

## 8. Reproduire les auto-tests

```powershell
Set-Location C:\Users\SuperKnacky\code\RiotSwitch

# 1) Mesure indépendante sur processus factice (aucune mesure réelle)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tools\perf\verify\IndependentMeasure.ps1 -SelfTest
# attendu : SELFTEST : PASS, code 0

# 2) Sonde de latences sur log + fenêtres (lecture passive)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tools\perf\verify\Verify-Probe.ps1 -Mode SelfTest
# attendu : SELFTEST : PASS, code 0
```

Les fichiers produits par la mesure factice sont conservés dans `results/`
(préfixe `selftest`), ceux de `Verify-Probe -Mode SelfTest` sont supprimés en
fin d'auto-test (utiliser `-KeepSelfTestArtifacts` pour les inspecter).

---

## 9. Historique

- **1.0.0** — 2026-11-11, phase A : première version des deux outils,
  auto-tests PASS (cross-check CPU 0,09 % / WS 0,00 % ; 143 cycles de latence
  analysés ; cross-check fenêtres PASS). Correctifs notables : contournement
  d'un bug PS 5.1 (`@()` sur une `List<T>` vide lève une `ArgumentException`),
  validation CSV consciente des guillemets (`DetectRect` contient des
  virgules), prise en charge des anciennes lignes de log sans `pid`/`rect`,
  ligne de base du mode `Watch`.
