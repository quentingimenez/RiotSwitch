# ProcessSampler - echantillonneur exact de processus Windows

Outil d'echantillonnage de performance pour la campagne de mesure RiotSwitch.

Objectif : mesurer un processus **externe** (CPU, memoire, handles, objets GDI/USER,
E/S, defauts de page, threads) a intervalle fixe, avec des valeurs **exactes** issues
d'appels Win32 (pas d'estimation via `System.Diagnostics.Process`) et un surcout
aussi faible que possible.

Le processus cible n'est **jamais** modifie : seuls des handles en lecture seule
(`PROCESS_QUERY_LIMITED_INFORMATION` / `PROCESS_VM_READ`) sont ouverts puis fermes.
Aucune injection de code, aucune interaction avec les fenetres, aucun arret.

## Fichiers

| Fichier | Role |
|---|---|
| `ProcessSampler.ps1` | Script principal (PowerShell 5.1). Echantillonnage, CSV, JSON, cross-check. |
| `ProcessNative.cs` | Helper C# 5 (compile a la volee par `Add-Type`) contenant tous les P/Invoke. |
| `Get-ProcessCounterMap.ps1` | Helpers de cross-check : decouverte des noms de compteurs localises et resolution du nom d'instance de performance d'un PID. |
| `validation/DummyWorker.ps1` | Processus factice de validation (threads CPU, memoire, handles, E/S, objets GUI). |
| `validation/Validate-Sampler.ps1` | Validation bout en bout (2 series de 60 s, controles, rapports). |
| `validation/VALIDATION.md` | Rapport de validation chiffre genere. |
| `results/` | Sorties par defaut des mesures et de la validation. |

## Prerequis

- Windows 11 (teste sur Windows 11 Pro FR, build 10.0.26200).
- Windows PowerShell 5.1 (desktop). Le helper C# est compile avec les reglages par
  defaut de `Add-Type` (C# 5), donc compatible PowerShell 5.1.
- Droits utilisateur normaux. Un processus protege (systeme, anti-triche) peut refuser
  l'ouverture de handle : l'outil echoue alors avec un message explicite.
- Aucune dependance externe. `Get-Counter` / `typeperf` sont fournis par Windows et ne
  servent qu'au cross-check optionnel.

**Ne pas mesurer RiotSwitch.exe pendant la campagne** : les tests et la validation
doivent se faire sur un processus factice.

## Utilisation

Depuis ce dossier :

```powershell
# Serie de 60 s a 1 Hz sur un processus par nom (nom unique obligatoire)
powershell -NoProfile -ExecutionPolicy Bypass -File .\ProcessSampler.ps1 `
    -ProcessName notepad -DurationSeconds 60 -Label "campagne-A"

# Par PID, CSV/JSON explicites, intervalle 500 ms, attribution CPU par thread
powershell -NoProfile -ExecutionPolicy Bypass -File .\ProcessSampler.ps1 `
    -ProcessId 4242 -DurationSeconds 120 -IntervalMs 500 `
    -Csv .\results\run.csv -Json .\results\run.json -Label "campagne-B" -IncludeThreads

# Avec cross-check CPU / working set via Get-Counter, JSON renvoye sur stdout
powershell -NoProfile -ExecutionPolicy Bypass -File .\ProcessSampler.ps1 `
    -ProcessId 4242 -DurationSeconds 60 -CrossCheck -EmitJson

# Instantane unique (avant/apres un cycle d'ouverture-fermeture de l'application)
powershell -NoProfile -ExecutionPolicy Bypass -File .\ProcessSampler.ps1 `
    -ProcessId 4242 -Snapshot -Label "avant" -Json .\results\avant.json
```

Le code de sortie est `0` en cas de succes. Toute erreur bloquante (cible introuvable,
plusieurs processus pour un nom, handle impossible, ecriture impossible) provoque un
arret avec message et code non nul.

### Parametres

| Parametre | Defaut | Description |
|---|---|---|
| `-ProcessId <int>` | 0 | PID du processus cible. Obligatoire si `-ProcessName` absent. |
| `-ProcessName <string>` | '' | Nom du processus (avec ou sans `.exe`). Doit designer un seul processus, sinon l'outil refuse et liste les PID candidats. |
| `-DurationSeconds <int>` | 60 | Duree de la mesure. |
| `-IntervalMs <int>` | 1000 | Periode d'echantillonnage (50 a 60000 ms). |
| `-Csv <path>` | `results\sampler-<label>-<pid>-<horodatage>.csv` | CSV par echantillon. |
| `-Json <path>` | meme nom que le CSV, extension `.json` | JSON de synthese. |
| `-Label <string>` | nom du processus | Etiquette recopiee dans le JSON et les noms de fichiers. |
| `-IncludeThreads` | desactive | Active la lecture des threads et l'attribution CPU top N. |
| `-TopThreads <int>` | 5 | Nombre de threads remontes (1 a 64). |
| `-CrossCheck` | desactive | Compare CPU et working set a `Get-Counter` pendant la meme fenetre. |
| `-Snapshot` | desactive | Mode instantane : une seule lecture de toutes les metriques, JSON puis sortie. Ignore duree/intervalle/threads/cross-check et ne produit pas de CSV. |
| `-EmitJson` | desactive | Emet le JSON de synthese sur stdout entre `SUMMARY_JSON` et `SUMMARY_JSON_END`. |
| `-Quiet` | desactive | N'affiche que le resume final. |

### Format CSV (15 colonnes, separateur `,`, nombres a point decimal)

| Colonne | Unite | Definition |
|---|---|---|
| `timestamp_utc` | ISO 8601 | Horodatage de l'echantillon (UTC). |
| `elapsed_s` | s | Temps ecoule depuis la ligne de base (horloge monotone). |
| `cpu_total_s` | s | CPU cumule du processus depuis la ligne de base (100 ns converti). |
| `cpu_pct_core` | % d'un coeur | Delta CPU de l'intervalle / delta temps reel x 100. Peut depasser 100 (processus multithread), comme le compteur PerfMon. |
| `ws_bytes` | octets | Working set courant (`PROCESS_MEMORY_COUNTERS_EX.WorkingSetSize`). |
| `private_ws_bytes` | octets | Working set prive exact : pages valides **non partagees** via `QueryWorkingSet`, multipliees par la taille de page. |
| `commit_bytes` | octets | Commit charge du processus (`PagefileUsage`). |
| `peak_ws_bytes` | octets | Pic de working set observe par le processus. |
| `handles` | count | Handles du processus. |
| `gdi` | count | Objets GDI. |
| `user` | count | Objets USER. |
| `threads` | count | Nombre de threads. |
| `io_read_bytes` | octets | Octets lus **pendant l'intervalle** (delta), pas un cumul. |
| `io_write_bytes` | octets | Octets ecrits **pendant l'intervalle** (delta). |
| `pagefaults_delta` | count | Defauts de page de l'intervalle (delta, correction de debordement 32 bits). |

Les nombres sont formates avec la culture invariante : le CSV reste lisible par tout
outil d'analyse quel que soit le parametre regional (fr-FR utilise la virgule decimale).

### Structure du JSON de synthese

`schema: "riotswitch.perf.process-sampler/1"` ; sections principales :

- `tool` : nom/version du script, helper natif, version PowerShell et OS ;
- `host` : nom de machine, nombre de processeurs logiques ;
- `target` : PID, nom, chemin de l'executable, date de demarrage, uptime, droits de
  handle obtenus, support du working set prive, disparition eventuelle en cours de mesure ;
- `cpu` : moyenne/min/max/p50/p95 par intervalle en **% d'un coeur** ET en **% machine**
  (machine = % coeur / nombre de processeurs logiques), plus l'agregat (CPU total /
  duree), le CPU total et les parts user/noyau ;
- `memory` : min/mediane/max du WS, du WS prive et du commit, pic WS, variation WS ;
- `handles`, `gdi_objects`, `user_objects`, `threads` : min/max/premier/dernier ;
- `io` : totaux d'octets lus/ecrits et debits (octets/s) ;
- `page_faults` : total et defauts/s ;
- `threads_cpu` (si `-IncludeThreads`) : methode, nombre de threads vus, CPU attribue,
  couverture (% du CPU du processus), top N avec TID, CPU, % du CPU du processus et
  % d'un coeur ;
- `sampler_overhead` : temps CPU du processus PowerShell hote pendant la boucle seule,
  (avec la limite de mesure expliquee plus bas) ;
- `cross_check` (si `-CrossCheck`) : noms de compteurs utilises, instance, erreurs,
  comparaison CPU et working set avec tolerances ;
- `warnings` et `notes` : avertissements d'execution et definitions methodologiques.

En mode `-Snapshot`, le schema est `"riotswitch.perf.process-snapshot/1"` avec
`target` (dont `process_start_iso` et `uptime_s`) et `counters` (CPU user/noyau/total,
WS, WS prive, commit, pic WS, handles, GDI/USER, threads, E/S, defauts de page).

### Percentiles

`p50`/`p95` sont calcules par interpolation lineaire sur les valeurs **par intervalle**
(rang = p/100 x (n-1)), pas sur les cumuls.

## Mesures et methode exacte

- CPU : `GetProcessTimes` (100 ns), delta par intervalle. Le taux CPU est le rapport du
  delta CPU au delta de temps reel mesure par `Stopwatch` : il n'est pas quantifie au
  tick d'horloge, contrairement aux valeurs brutes.
- Working set prive : `QueryWorkingSet` renvoie un bloc par page du working set ; le bit
  `Shared` de ce bloc marque les pages partagees, donc private WS = (pages du working set - pages partagees) x taille de page (4096 o).
  Le buffer est reutilise d'un echantillon a l'autre (cache statique cote helper).
- Threads : `NtQuerySystemInformation(SystemProcessInformation)` fournit le nombre de
  threads et le CPU cumule noyau+user de chaque thread en un seul appel systeme ;
  `GetThreadTimes` sert de repli. Le premier passage d'un thread est sa ligne de base :
  un thread cree en cours de mesure perd au plus le CPU de son premier intervalle.
- IO : `GetProcessIoCounters` (cumuls) ; le CSV publie les deltas de l'intervalle.
- Defauts de page : compteur 32 bits cumule, delta avec correction de debordement.
- Handles / GDI / USER : `GetProcessHandleCount`, `GetGuiResources(GR_GDIOBJECTS)`,
  `GetGuiResources(GR_USEROBJECTS)`.

### Cross-check

Avec `-CrossCheck`, un job PowerShell collecte en parallele `Get-Counter` a 1 s pendant
la meme fenetre. Les noms de compteurs sont **localises** (Windows francais :
`\Processus(*)\% temps processeur`, `\Processus(*)\Plage de travail`) : l'outil decouvre
dynamiquement les noms disponibles via `Get-Counter -ListSet *`, reconnait la variante
francaise ou anglaise, puis resout le nom d'instance de performance du PID
(ex. `powershell#3`) via WMI/CIM (`Win32_PerfFormattedData_PerfProc_Process`). Repli
anglais si un jeu francais est absent.

Tolerances : CPU ecart relatif <= 3 % (ou <= 0,5 point de % coeur) ; working set ecart
relatif <= 3 % (ou <= 1 Mio). Le verdict est dans `cross_check.overall_pass`.

## Surcout de l'outil

Deux facteurs dominent le cout par echantillon a 1 Hz :

1. `QueryWorkingSet` est en O(nombre de pages du working set) cote noyau (ex. ~70 000
   pages pour un processus de 285 Mio) ;
2. `NtQuerySystemInformation` parcourt une copie de la table systeme (une fois par
   echantillon, buffer reutilise).

A cela s'ajoute un effet de frequence : un thread qui se reveille apres 1 s de sommeil
travaille plus lentement qu'en boucle serree (caches froids, frequence CPU basse).

Mesure honnete a 1 Hz : la boucle de l'outil consomme ~1,1 a 1,4 % d'un coeur sur cette
machine (1,09 % en serie sans option, 1,33 % avec threads et cross-check), soit ~0,07 a
0,08 % de la machine (16 coeurs). Cette valeur est **surestimee** par la
methode de mesure : `GetProcessTimes` est quantifie au tick d'horloge (~15,6 ms) et une
rafale de quelques millisecondes est arrondie au tick superieur. Le cout utile mesure en
boucle serree (helper seul, sans attente) est de ~3 a 5 ms CPU par echantillon, soit
~0,3 a 0,5 % d'un coeur. Voir `validation/VALIDATION.md` pour les chiffres du run de
validation et la discussion detaillee.

Si une campagne exige un surcout plus bas, deux leviers existent :
`-IntervalMs 2000` (divise le cout par deux) ou la desactivation de l'attribution
threads (leger gain). Ces choix doivent etre documentes dans la campagne.

## Validation

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\validation\Validate-Sampler.ps1
```

Le script lance `DummyWorker.ps1` (2 threads CPU, 200 Mio alloues et touches, 60 handles,
32 Mio d'E/S, objets GUI), puis execute deux series de 60 s (sans option, puis avec
`-IncludeThreads -CrossCheck`), deux instantanes `-Snapshot`, verifie automatiquement
coherence CSV/JSON, valeurs attendues, tolerance du cross-check et couverture de
l'attribution threads, et ecrit :

- `validation/validation-report.json` (detail machine) ;
- `validation/VALIDATION.md` (rapport lisible en francais).

Resultats du dernier run (2026-11-11T00:38:16Z, 27 controles sur 27 OK) :

- charge factice : 2 threads brulants, 200 Mio alloues et touches, 60 handles, 32 Mio
  d'E/S, objets GUI ;
- CPU mesure : 196,62 % d'un coeur (serie A) et 197,12 % (serie B) ;
- working set prive : 281,84 Mio (serie A), coherent avec 200 Mio alloues + base
  PowerShell ;
- cross-check Get-Counter : ecart CPU 0,037 pt (0,019 %) et ecart WS 0 octet ;
- attribution threads : 99,97 % du CPU du processus, 2 threads brulants a ~50 % chacun ;
- surcout mesure : 1,09 % d'un coeur (0,068 % machine) sans option, 1,33 % avec threads
  et cross-check ; voir la limite de mesure ci-dessus et `validation/VALIDATION.md`.

## Limites connues

- `QueryWorkingSet` exige `PROCESS_VM_READ` et un jeu de pages lisible ; quelques
  processus systeme/proteges refusent l'ouverture (message explicite, pas de mesure
  partielle silencieuse).
- Le surcout croit avec la taille du working set (scan des pages) et le nombre de
  threads (si `-IncludeThreads`).
- La mesure du surcout propre est quantifiee au tick d'horloge : elle est fiable en
  ordre de grandeur, pas a 0,1 % pres.
- Un thread cree pendant la mesure n'est attribue qu'a partir de son premier
  echantillon ; le CPU de son premier intervalle peut manquer (couverture indiquee dans
  le JSON).
- Le CSV publie les deltas d'E/S par intervalle ; les totaux et debits sont dans le JSON.
- Le cross-check `Get-Counter` depend de la disponibilite des compteurs de performance
  (desactives sur certaines VM). Si indisponible, un avertissement est emis et le
  cross-check est ignore sans faire echouer la mesure.
- Le mode `-Snapshot` ne fournit pas de statistiques : une seule lecture.
- L'outil est concu pour Windows PowerShell 5.1 ; il n'a pas ete valide sur PowerShell 7.
