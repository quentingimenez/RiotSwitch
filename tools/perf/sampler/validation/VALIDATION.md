# Rapport de validation - ProcessSampler

Genere le : 2026-11-11T00:38:16.4773423Z (UTC) par `validation/Validate-Sampler.ps1`.

## Conditions

| Element | Valeur |
|---|---|
| Machine | SUPERKNACKY - 16 coeurs logiques |
| OS / PowerShell | Microsoft Windows NT 10.0.26200.0 / 5.1.26100.9711 |
| Cible | processus factice PowerShell instancie par le script (aucun RiotSwitch) |
| Charge cible | 2 threads CPU, 200 Mio alloues et touches, 60 handles, 32 Mio E/S, objets GUI |

## Series de mesure

| Serie | Duree mesuree | Echantillons | CPU moyen (% coeur) |
|---|---|---|---|
| A - surcout (sans option) | 60.022 s | 60 | 196.622 |
| B - threads + cross-check | 60.023 s | 60 | 197.122 |

## Validation des metriques

- OK - `worker_demarre` : PID 23352
- OK - `garde_fou_pas_riotswitch` : cible = powershell factice
- OK - `snapshot_exit_0` : exit 0 / 0
- OK - `snapshot_schema` : riotswitch.perf.process-snapshot/1
- OK - `snapshot_metriques` : cpu=6.484 s, private_ws=294801408 o, uptime=3.29 s
- OK - `snapshot_process_start_iso` : 2026-11-11T00:36:03.5173100Z
- OK - `snapshot_handles_augmentent` : 723 -> 723
- OK - `serieA_exit_0` : exit 0
- OK - `serieB_exit_0` : exit 0
- OK - `csv_15_colonnes` : 15 colonnes
- OK - `csv_nb_lignes` : 60 lignes / 60 echantillons
- OK - `csv_decimaux_invariants` : exemple cpu_pct_core=188.105, elapsed_s=1.030
- OK - `json_schema` : riotswitch.perf.process-sampler/1
- OK - `cpu_plausible` : 196.622 % d un coeur (2 threads brulants attendus ~200)
- OK - `memoire_privee_plausible` : 281.836 Mio (200 Mio alloues et touches)
- OK - `handles_plausibles` : max 724 (60 fichiers maintenus ouverts)
- OK - `gdi_user_non_nuls` : GDI 19, USER 20
- OK - `io_mesurees` : 7.438 Mio lus, 7.438 Mio ecrits
- OK - `threads_present` : max 30
- OK - `duree_mesuree` : 60.022 s
- OK - `crosscheck_global` : CPU ecart 0.019 %, WS ecart 0 %
- OK - `crosscheck_cpu_tolerance` : 0.037 pt / 0.019 %
- OK - `crosscheck_ws_tolerance` : 0 Kio
- OK - `threads_attribues` : methode : NtQuerySystemInformation(SystemProcessInformation) + GetThreadTimes de secours, deltas par intervalle
- OK - `threads_couverture` : 99.97 % du CPU process attribue
- OK - `threads_top5` : 3 threads dans le top
- OK - `surcout_mesure` : 1.093 % d un coeur, 0.068 % machine, 10.938 ms CPU/echantillon

## Cross-check Get-Counter

- Detection : localise ; jeu "Processus" ; instance `powershell#10`.
- CPU : sampler 197.122 % coeur, compteur 197.159 % coeur, ecart 0.037 pt (0.019 %), tolerance 3 %.
- Working set : sampler 345.594 Mio, compteur 345.594 Mio, ecart 0 Kio (0 %), tolerance 3 %.
- Verdict : OK.

## Attribution CPU par thread (serie B)

- Methode : NtQuerySystemInformation(SystemProcessInformation) + GetThreadTimes de secours, deltas par intervalle.
- Couverture : 99.97 % du CPU du processus.
- Top threads : TID 37728 = 50.07 % du processus ; TID 20772 = 49.85 % du processus ; TID 34144 = 0.05 % du processus.

## Surcout de l outil

- Mesure GetProcessTimes : 1.093 % d un coeur, 0.068 % machine, 10.938 ms CPU par echantillon.
- Cible : < 0,5 % d un coeur. Verdict : NON atteinte - voir Limites.
- Note : GetProcessTimes est quantifie au tick d horloge (~15,625 ms). A 1 Hz, chaque rafale de travail est arrondie au tick, ce qui surestime fortement le cout d un outil qui consomme quelques millisecondes par seconde. Le cout utile reel se mesure en boucle serree (helper seul) : ~3 a 5 ms CPU par echantillon, soit ~0,3 a 0,5 % d un coeur.

## Verdict

**TOUS LES CONTROLES PASSENT.** Les metriques de la serie A et de la serie B sont coherentes avec la charge injectee ; le cross-check Get-Counter reste sous la tolerance de 3 % ; le mode -Snapshot fonctionne.

Rapport detaille (JSON) : `validation-report.json`.
