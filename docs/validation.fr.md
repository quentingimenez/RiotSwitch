# Validation

Ce document liste les vérifications déjà effectuées et la checklist restante avant de considérer RiotSwitch comme prêt à l'emploi.

## État au 10 novembre 2026

| Élément | État |
| --- | --- |
| Build solution (Debug) | ✅ 0 avertissement, 0 erreur |
| Tests unitaires Core | ✅ 65/65 |
| CLI `status` / `doctor` / `window` (lecture seule, installation réelle) | ✅ |
| Capture des comptes A et B | ✅ compte A et compte B enregistrés dans le coffre, format PslV1 |
| Auto-update (version, GitHub Releases, SHA-256, zip-slip) | ✅ tests unitaires (65/65) ; vérification et installation réelles validées de la release v1.0.0 vers v1.1.0 |
| Publication GitHub + CI | ✅ dépôt public `quentingimenez/RiotSwitch`, CI verte, releases `v1.0.0` à `v1.1.14` ; v1.1.3 ajoute un exécutable autonome + SHA-256, v1.1.4 ajoute l'installateur Inno Setup + SHA-256, v1.1.6/v1.1.7 conservent le switcher quand la fenêtre Riot est réduite/relancée, v1.1.8 affiche le tag de version dans les paramètres, v1.1.9 ignore les fenêtres Riot non visibles ou recouvertes, v1.1.10 remplace le test du centre par un échantillonnage de visibilité (20 % exposés), v1.1.11 remet le veilleur par défaut et compacte sa mémoire de travail |
| Icône de l'application | ✅ logo « Twin Profiles » transparent intégré (`app.ico` multi-tailles + `Assets/logo-twin-profiles.png`), contenu agrandi dans v1.1.2 (recadrage serré sans ombre portée, 94–100 % du cadre selon la taille), icône vérifiée dans l'exe et les fenêtres |
| API locale : authentification lockfile + lecture du PUUID | ✅ |
| Mode veilleur caché (sans Riot) | ✅ aucune fenêtre ; après compactage WorkingSet ≈ 9,5–16 Mo (9,7 Mo à 3 s, 15 Mo à 13 s, 16,3 Mo à 25 s), privé ≈ 14–16 Mo, CPU ≈ 0,3 % d'un cœur en mesure précise (invisible dans le Gestionnaire des tâches) ; démarrage à ≈ 62,6 Mo avant compactage |
| Overlay visuel attaché | ✅ testé sur second écran : bouton 40×40, panneau déplié 340×200, clic sans vol de focus |
| Épinglage de l'overlay | ✅ depuis la v1.1.15, la punaise **verrouille le glisser** sans détacher l'overlay : l'overlay épinglé reste aimanté à la fenêtre Riot et suit ses déplacements (bouton replié et panneau déplié), le glisser à la souris est neutralisé ; le désépinglage réactive le glisser sans saut de position |
| Ordre des comptes | ✅ `MoveAccount` (▲/▼) et tri A → Z testés sur 3 comptes, persistance après rechargement, ordre partagé coffre/overlay/paramètres |
| `--launch-riot --ephemeral` | ✅ testé depuis un shell pollué (`ELECTRON_RUN_AS_NODE=1`) : UI ouverte, overlay créé, processus quitté avec le client |
| Switch via l'overlay (clic réel) | ✅ B→A puis A→B déclenchés en cliquant sur le bouton ⇄ puis sur la ligne du compte ; API locale vérifiée après chaque relance, journal nettoyé |
| Switch réel A↔B | ✅ validé le 09/11 vers 19:55 : A→B puis B→A, sortie 0, vérification API du PUUID, UI et service relancés |
| Rollback réel | ✅ provoqué par des sessions cibles expirées : retour au compte précédent, UI restaurée, journal effacé (avant correctif d'environnement, puis pipeline complet revalidé). Depuis la v1.1.15, une session cible expirée ne déclenche plus ce rollback : voir la ligne suivante ; il ne subsiste que pour le cas « un autre compte est confirmé ». |
| Mode de démarrage par défaut | ✅ v1.1.11 : `AppSettings.BackgroundMode = Watch` et `Autostart=true` par défaut, `Normalize` retombe sur Watch ; sans argument, l'application démarre le veilleur et crée le raccourci Startup `--watch`. Le zéro fond reste disponible explicitement via `--launch-riot --ephemeral` / le raccourci « Riot Client (Switch) ». Sur l'installation de test, les raccourcis Riot Client d'origine ont été restaurés, les paramètres sont en Watch/Autostart et le veilleur compacte sa mémoire |
| Premier lancement WelcomeForm | ⏳ à valider |
| Publish `dist/` | ✅ republié en 1.1.15 (`dist\RiotSwitch.exe`, `dist\cli\RiotSwitch.Cli.exe`) |
| Tag de version dans les paramètres | ✅ version courante affichée en haut à droite de la fenêtre Paramètres ; capture vérifiée ; titre `RiotSwitch — Paramètres` corrigé (l'ancienne constante `AppInfo.SettingsTitle` était doublement encodée) |
| Overlay et fenêtre Riot non visible | ✅ v1.1.10 : filtre DWM cloaked, surface visible ≥ 25 % de la zone de travail, puis échantillonnage d'une grille 5×5 (au moins 20 % des points exposés au client Riot ou à l'overlay ; client au premier plan accepté directement). Le test du seul centre était trop strict et masquait l'overlay quand une petite fenêtre recouvrait le centre. Tracker réagit à `EVENT_SYSTEM_FOREGROUND` et timer de secours 2 s |
| Veilleur par défaut + mémoire (v1.1.11) | ✅ défauts Watch/Autostart ; trim `EmptyWorkingSet` déclenché au-delà de 32 Mo de WorkingSet, uniquement sans overlay ; mesures ci-dessus ; bug de comparaison de handle dans `RiotWindowTracker` corrigé (plus de log/événement toutes les 2 s quand aucune fenêtre Riot n'est présente) |
| Overlay après ouverture réduite du Riot Client (v1.1.12) | ✅ `RiotClientWindow.FindMinimized()` + restauration unique `SW_RESTORE` par le tracker ; une fenêtre déjà connue n'est jamais rouverte si l'utilisateur la minimise. Testé en réel : client réduit (hwnd 8391202) → restauré automatiquement, overlay créé ; minimisation manuelle → overlay détruit, pas de restauration ; restauration manuelle → overlay recréé. |
| Stabilité de l'overlay au lancement/rendu (v1.1.13) | ✅ `RiotWindowTracker` conserve l'overlay pendant 3,5 s après une disparition transitoire de la fenêtre Riot (`_absentSinceUtc`, `AbsentGraceMs=3500`) : plus de destruction/recréation pendant le chargement de la page Electron. Testé client fermé puis relancé : fenêtre détectée à 14:22:22.068, overlay créé (handle 4393300), aucune ligne « absente » pendant les 12 s suivantes. |
| Remontée du Riot Client lancé sans focus (v1.1.14) | ✅ `RiotClientWindow.FindPresent()` repère une fenêtre Riot visible même recouverte ; `RiotWindowTracker.RaiseIfNotForeground()` remonte le client **une seule fois par handle** (processus lancé après le veilleur, `ForceForeground` avec `SetForegroundWindow`/`AttachThreadInput`). Test réel : client complètement fermé puis relancé pendant que le GUI DSH restait au premier plan ; log 14:42:26.267 « fenêtre Riot Client sans focus hwnd=5900768 pid=9264 ; remontée unique », `GetForegroundWindow` devient le Riot Client, overlay créé (`handle=6293618`) et clic au centre du bouton atteint l'overlay. Le doublon `Riot Client.lnk` du menu Démarrer a été retiré (sauvegarde dans `%LOCALAPPDATA%\RiotSwitch\riot-shortcut-backups`), il ne reste que `Client Riot.lnk`. |
| Session cible expirée sans retour au compte précédent (v1.1.15) | ✅ tests unitaires (65/65) : `Expired_target_session_leaves_client_on_login_page` → `SwitchOutcome.ReconnectRequired`, aucune restauration de sauvegarde, une seule séquence arrêt/démarrage, session cible toujours installée, journal effacé et erreur « Session expirée : reconnecte-toi… » enregistrée sur le compte ; `Other_account_after_relaunch_rolls_back` → `VerificationFailed` + rollback (deuxième cycle arrêt/démarrage, session précédente restaurée) ; `Confirmed_target_account_succeeds_after_relaunch` → succès. CLI : `ReconnectRequired` mappé sur le code de sortie 5. Reste à revalider en conditions réelles avec une session réellement expirée. |
| Ordre Z et suivi immédiat de l'overlay (v1.1.15) | ✅ l'overlay reste au-dessus de la fenêtre Riot (`EnsureAboveOwner()`, rangs Z 53–57 contre 72, exstyle non topmost) et suit ses déplacements en 1–2 ms (hook `EVENT_OBJECT_LOCATIONCHANGE` filtré sur la cible, déplacement sans redessin) ; réassertion automatique ≤ 700 ms après une mise sous le client forcée (mesuré 122 ms) ; recréé au-dessus après recouvrement du client (rang 53 contre 72). Build 0/0, tests 65/65 ; validation utilisateur en cours. |
| Glisser borné à la fenêtre du client (v1.1.15) | ✅ le bouton et le panneau ne sortent plus de la fenêtre Riot : clamp de la mise en page et des offsets au rectangle `GetWindowRect(client)` (marge 8 DIP), pendant le glisser, au déplacement et au redimensionnement ; le panneau ne se referme plus pendant un glisser bloqué par un bord. Testé avec une fausse fenêtre « Riot Client » 1200×800 : glisser au-delà des quatre bords → bouton (608,308)/(1752,1052), panneau (608,308)/(1412,776), panneau resté ouvert ; déplacement de la fenêtre → overlay (108,108) ; redimensionnement 1000×700 → overlay (608,308). Build 0/0, tests 65/65, dist republié en 1.1.15 ; validation utilisateur en cours. |
| Rétention des messages de statut de l'overlay (v1.1.15) | ✅ les messages sous le panneau ne restent plus affichés indéfiniment (épinglage, ajout de compte) et ne réapparaissent plus après fermeture/réouverture : rétention 5 s (info/succès) et 8 s (avertissement/erreur), progression maintenue jusqu'au résultat, tout nouveau message relance l'échéance, `Collapse()` efface le statut. Testé en direct (fausse fenêtre « Riot Client » 1700×1000 sur second écran, overlay `hwnd=265956`, 100 %/96 DPI, clics `PostMessage`) : statut affiché en 380×352 = H0 + 36 DIP, effacement automatique mesuré 5 088 ms après le clic ; second message → effacé 5 040 ms après le dernier clic (6 145 ms après le premier) ; fermeture pendant un statut puis réouverture 901 ms après → panneau sans bandeau, aucun résidu à +2 s ni après l'échéance d'origine. `settings.json` restauré à l'identique (sha256 inchangé), aucun fichier du dépôt modifié. Build Debug 0/0, tests 65/65 ; chemins avertissement/erreur (8 s) et progression couverts par revue de code, non déclenchés en direct. |

### Détails de l'environnement validé

- Windows 11 Pro 26200, .NET SDK 8.0.403.
- Riot Client 142.0.0 (`C:\Riot Games\Riot Client`), session `PslV1`, UI Electron 1536×864.
- Comptes de test : compte A et compte B, tous deux connectés et capturés dans le coffre ; les identifiants personnels ne sont pas publiés dans ce document.
- Coffre : `%LOCALAPPDATA%\RiotSwitch`, 2 comptes (A et B), captures fraîches ; sauvegardes pré-switch et replace.

### Vérifications déjà réalisées

1. `dotnet build RiotSwitcher.sln -v minimal --nologo` → succès.
2. `dotnet test tests\RiotSwitcher.Core.Tests\RiotSwitcher.Core.Tests.csproj -v minimal --nologo --no-build` → 65 réussis (dont les tests de l'environnement de lancement du service, de l'ordre des comptes, de l'auto-update et des trois issues de vérification du compte après relance).
3. `RiotSwitch.Cli.exe status` → installation, session, compte, PUUID, API locale, garde-fou et coffre affichés correctement.
4. `RiotSwitch.Cli.exe doctor` → chemins, DPAPI, compte, sauvegardes et garde-fou affichés.
5. `RiotSwitch.Cli.exe capture` → compte courant enregistré, `list` le retrouve.
6. `RiotSwitch.exe --watch` → processus unique caché, aucune fenêtre, CPU 0 % au repos.
7. `POST /riot-client-lifecycle/v1/show` → 204, interface Riot Client ouverte ; `POST /riot-client-lifecycle/v1/hide` → 204, interface refermée sans perturber la partie en cours.
8. API locale : `GET /rso-auth/v1/authorization` renvoie le PUUID du compte courant ; `GET /rso-auth/v1/session` répond `authenticated`.
9. `RiotSwitch.exe --attach` : overlay attaché à la fenêtre `Riot Client` (hwnd `94440460`, PID `28248`) déplacée sur le second écran ; clic sur le bouton via message Windows ; panneau déplié (340×200 DIP) avec compte actuel, boutons et fermeture ; aucun vol de focus. Les captures de test (contenant le compte personnel) ont été supprimées après vérification.
10. `RiotSwitch.Cli.exe window` : détection de la fenêtre Riot Client confirmée (hwnd, PID, titre, position, topmost).
11. `RiotSwitch.exe --launch-riot --ephemeral` lancé depuis un shell avec `ELECTRON_RUN_AS_NODE=1` : le service a démarré avec un environnement nettoyé, l'UI Electron s'est chargée (`Ux reports successful load` à ~2,9 s), l'overlay a été créé, puis l'application s'est arrêtée sans laisser de processus RiotSwitch.
12. Switch B→A réel avec la session A ancienne : écriture de la cible, arrêt/relance du service et de l'UI, vérification API (cible non confirmée), rollback vers B. État final : session B valide, UI B ouverte, API connectée sur B, journal `switch-journal.json` absent, 2 comptes toujours présents. Code de sortie 5, message « Le client n'a pas confirmé le compte cible. Retour au compte précédent. » **Comportement modifié en v1.1.15 : ce cas (aucun compte confirmé, client resté sur l'écran de connexion) ne déclenche plus de rollback ; le client est laissé sur la page de connexion, session cible installée.**
13. **Switch nominal A↔B réussi** (09/11, ~19:55) après la procédure de capture propre :
    - B capturé après fermeture propre de l'UI (19:52), puis session live déplacée en sauvegarde pour forcer un écran de connexion ;
    - démarrage du service avec environnement nettoyé, connexion manuelle à A ;
    - `RiotSwitch.Cli.exe switch "Compte B" --yes` : sortie 0, compte B activé et vérifié dans le client Riot, API locale sur le compte B, UI B ouverte ;
    - `RiotSwitch.Cli.exe switch "Compte A" --yes` : sortie 0, retour au compte A vérifié, UI A ouverte, 2 comptes toujours présents.
14. Publish : `dist/` est republié après ces vérifications et les dernières retouches de docs (`powershell -ExecutionPolicy Bypass -File tools\publish.ps1`).
15. **Exception post-switch corrigée** : panneau déplié puis switch via l'overlay (`--attach`) ; la fenêtre Riot est fermée/relancée, l'overlay est recréé, le processus reste actif, aucune boîte d'exception, compte cible vérifié par l'API.
16. **Épinglage de l'overlay** : la punaise verrouille le **glisser** (protection contre les déplacements accidentels) tout en conservant l'ancrage à la fenêtre Riot — l'overlay épinglé continue de suivre les déplacements de la fenêtre. Comportement détaillé et mesures en v1.1.15 : voir le point 29.
17. **Ordre des comptes** : `SessionVault.MoveAccount` testé vers le haut/bas (bornes incluses) et `SortAccountsAlphabetically` testé sur trois comptes ; l'ordre est relu depuis `accounts.json` après rechargement et utilisé par l'overlay et les paramètres. Interface : boutons ▲ Monter / ▼ Descendre / Trier A → Z ; l'ordre est rafraîchi dans l'overlay à la fermeture des paramètres.
18. **Fenêtre Riot réduite dans la zone de notification (v1.1.6)** : lancement sans argument en mode zéro fond, overlay créé ; `ShowWindow(SW_HIDE)` → switcher toujours actif après 3 s ; `ShowWindow(SW_SHOWNOACTIVATE)` → overlay recréé (`handle=225381126`, `visible=True`), sans exception ni doublon.
19. **Fermeture puis réouverture complète du Riot Client (v1.1.7)** : fermeture de la fenêtre Riot (`CloseMainWindow`) → processus UX Riot disparu, service `RiotClientServices` toujours actif, switcher toujours vivant ; relance du raccourci Riot Games → nouvelle fenêtre Riot (`hwnd=109841380`), overlay recréé (`handle=31068410`, `visible=True`), sans exception. Testé aussi avec l'application `dist` 1.1.7 laissée en fonctionnement.
20. **Tag de version dans les paramètres (v1.1.8)** : label `v1.1.8` en haut à droite de la fenêtre Paramètres (`SettingsForm.versionTag`), build Release 0 avertissement / 0 erreur, tests 62/62 ; capture 636×799 vérifiée. Le titre de la fenêtre est corrigé : `AppInfo.SettingsTitle` contenait une chaîne doublement encodée (`RiotSwitch Ã¢â‚¬â€� ParamÃƒÂ¨tres`) et affiche désormais `RiotSwitch — Paramètres`.
21. **Overlay masqué quand le Riot Client n'est pas visible (v1.1.9)** : `RiotClientWindow.Find` ignore les fenêtres DWM cloaked (`DWMWA_CLOAKED`), celles dont moins de 25 % de la surface est dans la zone de travail du moniteur, et celles qui sont recouvertes par une autre application (`WindowFromPoint` + PID). `RiotWindowTracker` obtient un hook `EVENT_SYSTEM_FOREGROUND` et un timer de secours réduit à 2 s. Test synthétique avec une fausse fenêtre « Riot Client » (1536×864, processus factice) : overlay créé quand elle est visible, détruit quand elle est minimisée, cachée ou recouverte, recréé après restauration.
22. **Détection de visibilité assouplie (v1.1.10)** : le test du seul point central de la fenêtre Riot était trop strict — une petite fenêtre posée au centre (ou le GUI DSH) faisait disparaître l'overlay alors que la fenêtre Riot restait largement visible. Remplacé par un échantillonnage 5×5 : au moins 20 % des points doivent appartenir au client Riot ou à RiotSwitch, et le client au premier plan est accepté directement. Le comportement « fenêtre minimisée/cachée/recouverte » de la v1.1.9 est conservé. Build Release 0/0, tests 62/62.
23. **Veilleur par défaut, ultra léger (v1.1.11)** : `AppSettings.BackgroundMode=Watch` et `Autostart=true` par défaut ; radios veilleur en premier dans WelcomeForm/SettingsForm ; sans argument, l'application démarre le veilleur. `WatchContext` compacte la mémoire de travail (`GC.Collect` puis `EmptyWorkingSet`) : première passe 2 s après le démarrage, puis toutes les 10 s **uniquement si le WorkingSet dépasse 32 Mo et qu'aucun overlay n'est affiché**, avec un log unique. Mesure réelle (veilleur caché, Riot Client présent mais non visible) : 62,6 Mo à 1,5 s, 9,7 Mo à 3 s, 15 Mo à 13 s, 16,3 Mo à 25 s, privé 14–16 Mo ; CPU post-compactage ≈ 0,28 % d'un cœur (Gestionnaire des tâches : 0 %). Correction au passage de `RiotWindowTracker` : la comparaison handle null/`IntPtr.Zero` provoquait un log et un événement toutes les 2 s lorsqu'aucune fenêtre Riot n'était visible. Validation après redémarrage : lancement via le raccourci Startup `--watch` (PID 25488), WorkingSet ≈ 11 Mo à 3 s ; mise au premier plan du Riot Client réel (`hwnd=1641184`) → overlay créé (`handle=8063788`, `visible=True`).
24. **Overlay après ouverture réduite du Riot Client (v1.1.12)** : après un redémarrage ou une mise à jour, le client peut se retrouver minimisé alors que son processus tourne. `RiotClientWindow.FindMinimized()` (même titre/process, non topmost) le signale au tracker ; celui-ci restaure la fenêtre **une seule fois** via `ShowWindow(..., SW_RESTORE)`. Un `HashSet<IntPtr>` mémorise les handles déjà vus : si l'utilisateur minimise lui-même le client, aucune restauration n'a lieu et l'overlay reste masqué. Validation réelle : watcher démarré avec le client réduit → restauration et overlay (`handle=2556514`), minimisation manuelle → disparition sans réouverture, restauration manuelle → overlay recréé (`handle=13109592`). Build Release 0/0, tests 62/62.
25. **Stabilité de l'overlay au lancement du Riot Client (v1.1.13)** : le client Electron fait disparaître/réapparaître brièvement sa fenêtre pendant le rendu de la page, ce qui détruisait l'overlay. `RiotWindowTracker` garde désormais l'overlay pendant `AbsentGraceMs = 3500` ms après une disparition, puis ne le détruit que si la fenêtre n'est toujours pas revenue. Test réel : Riot Client complètement fermé, veilleur lancé, puis `RiotClientServices.exe` démarré ; log `14:22:22.068` « fenêtre Riot Client détectée hwnd=6555972 pid=34644 rect=(504,288,1552x872) », overlay `handle=4393300`, aucune « absente » pendant 12 s. Build Release 0/0, tests 62/62.
26. **Remontée du Riot Client lancé sans focus (v1.1.14)** : quand le client est lancé alors qu'une autre fenêtre (GUI DSH, navigateur, jeu) est au premier plan, l'overlay est bien créé mais peut rester derrière le client. `RiotClientWindow.FindPresent()` détecte la fenêtre Riot même recouverte ; `RiotWindowTracker.RaiseIfNotForeground()` la remonte une seule fois par handle via `AppNativeMethods.ForceForeground` (SetForegroundWindow, puis AttachThreadInput/BringWindowToTop en secours), uniquement pour un processus lancé après le veilleur. Test réel : Riot Client fermé, puis `RiotClientServices.exe` démarré pendant que le GUI DSH restait au premier plan ; log 14:42:26.267 « fenêtre Riot Client sans focus hwnd=5900768 pid=9264 ; remontée unique », `GetForegroundWindow` devient le Riot Client, overlay `handle=6293618` visible et clic au centre atteint l'overlay. Le doublon `Riot Client.lnk` du menu Démarrer a été retiré après sauvegarde ; il ne reste que `Client Riot.lnk`. Build Release 0/0, tests 62/62.
27. **Session cible expirée : plus de retour automatique au compte précédent (v1.1.15)** : `SwitchService.VerifyAccountAfterStartup` renvoie désormais un enum `AccountVerification` (`Confirmed`, `OtherAccount`, `NotConfirmed`). Quand l'API locale ne confirme aucun compte dans le délai (client resté sur l'écran de connexion après une session expirée ou révoquée), le switch renvoie `SwitchOutcome.ReconnectRequired`, efface le journal, marque le compte comme utilisé et enregistre l'erreur « Session expirée : reconnecte-toi dans le client Riot, puis ajoute à nouveau le compte. », **sans restaurer la sauvegarde précédente ni relancer le client**. Le rollback ne subsiste que si le client confirme un autre compte que la cible. Le délai de vérification est injectable dans le constructeur (`verificationTimeout`, 15 s par défaut) pour garder les tests rapides. Tests ajoutés : `Expired_target_session_leaves_client_on_login_page`, `Other_account_after_relaunch_rolls_back`, `Confirmed_target_account_succeeds_after_relaunch`. Build Debug 0/0, tests 65/65. Reste à confirmer en conditions réelles avec une session réellement expirée.
28. **Ordre Z et suivi immédiat de l'overlay (v1.1.15)** : deux défauts signalés en usage réel — l'overlay pouvait se retrouver sous la fenêtre Riot, et il suivait les déplacements avec jusqu'à 500 ms de retard (timer `_positionTimer`). Correctifs : `OverlayForm` installe des hooks `EVENT_OBJECT_LOCATIONCHANGE` et `EVENT_SYSTEM_FOREGROUND` filtrés sur le handle cible ; `EnsureAboveOwner()` réaffirme la place de l'overlay juste au-dessus de son owner (`GetWindow(GW_HWNDPREV)`, owner topmost synchronisé, `SetWindowPos` avec `SWP_NOACTIVATE | SWP_NOOWNERZORDER`) à l'affichage, au changement de cible, au tick de secours et quand le client redevient premier plan ; le repositionnement pur se fait par `SetWindowPos` sans redessin (`UpdateLayeredWindow` seulement si la taille de mise en page change). `RiotWindowTracker` ignore les `EVENT_OBJECT_LOCATIONCHANGE` (l'overlay gère la position ; évite un `Find()` complet à chaque déplacement). Test réel (veilleur Debug sur le client `hwnd=7408654`, PID 35596, Discorde premier plan) : overlay `handle=1444790` créé au-dessus du client (rangs Z 57 contre 72, exstyle `0x08090080` non topmost) ; déplacements programmatiques du client → overlay à jour en 1–2 ms (+120 px : 2 ms ; −60/+40 : 1 ms ; glissement de 20 pas de 6 px à 15 ms suivi exactement) ; overlay forcé sous le client (`SetWindowPos(overlay, riot, …)`) → réassertion automatique au tick de secours (≤ 700 ms, mesuré 122 ms) ; fenêtre de recouvrement à 92 % du client → « fenêtre Riot Client absente » après 3,5 s et destruction de l'overlay, puis recréation `handle=39521766` au-dessus du client (rang 53 contre 72) à la fin du recouvrement ; CPU 0 % d'un cœur sur 4 s, WorkingSet 69,1 Mo (trim sauté tant que l'overlay est affiché). Build Debug 0/0, tests 65/65. La création pendant que le client est déjà premier plan n'a pas pu être rejouée (impossible de voler le premier plan à Discorde), mais la logique ne dépend pas du premier plan ; reste à confirmer par l'utilisateur sur ses déplacements réels.
29. **Épinglage = verrouillage du glisser, suivi conservé (v1.1.15)** : la punaise figeait auparavant l'overlay sur une position écran absolue, ce qui le détachait de la fenêtre Riot dès qu'elle se déplaçait. Désormais l'épinglage ne verrouille que le glisser : `ComputeLayout()` positionne toujours l'overlay avec les offsets relatifs à la fenêtre, `TogglePin()` ne fait que basculer `overlayPinned` (les champs hérités `overlayPinnedRightPx`/`overlayPinnedTopPx` sont remis à zéro et ne servent plus au placement), et `OnMouseMove` ignore les mouvements tant que `OverlayPinned` est vrai. Test réel (veilleur `dist` 1.1.15, client `hwnd=39128150` PID 31064) : épinglé replié, déplacement du client +100,−40 → overlay à jour au même bord droit ; panneau ouvert épinglé, déplacement −160,+60 → panneau suivi exactement ; tentative de glisser de 60×40 pendant l'épinglage → aucun déplacement et offsets inchangés (`overlayPinned=true`) ; désépinglage → `overlayPinned=false`, puis glisser libre +50,+30 → overlay déplacé et `overlayOffsetRightDip`/`overlayOffsetTopDip` mis à jour ; fermeture par la croix et réouverture du panneau OK. Testé aussi en conditions de recouvrement (GUI DSH au premier plan → overlay masqué, réapparaît au retour du client). Build Debug 0/0, tests 65/65, dist republié en 1.1.15 (sans bump : version non publiée).
30. **Glisser borné à la fenêtre du client (v1.1.15)** : le glisser clampait la position au moniteur (`Screen.WorkingArea`), l'overlay pouvait donc sortir de la fenêtre Riot et flotter sur le bureau ou l'autre écran. Correctifs dans `OverlayForm` : `ComputeLayout()` clampe le bouton et le panneau à `GetWindowRect(_target.Handle)` avec `EdgeMarginDip = 8` de marge au lieu de la zone de travail ; `ComputeOffsetBounds()`/`ApplyDragOffsets()` bornent les offsets en DIP pendant le glisser (`Math.Clamp` entre `margin/scale` et `(client.Width - margin - anchorWidth)/scale`, idem en vertical) ; `ClampOffsetsToClientBounds()` ramène au premier mouvement une position mémorisée hors bornes sans sauter (le clamp d'affichage donne la même position) ; `CheckOutsideClick()` ignore les clics pendant un glisser, sinon le panneau se refermait quand le curseur dépassait le panneau bloqué par un bord. Testé en direct (veilleur Debug, fausse fenêtre « Riot Client » 1200×800 à (600,300), 100 %/96 DPI, fenêtre factice PID 36332, overlay JSON 3 comptes) : glisser du bouton 40×40 vers le bas-droite → (1752,1052) = bord droit/bas moins 8 px, vers le haut-gauche → (608,308) ; offsets sauvegardés bornés (1152/8) ; panneau déplié 380×316, glisser vers le bas-droite → (1412,776), vers le haut-gauche → (608,308), panneau resté ouvert (offsets 812/8) ; déplacement de la fenêtre à (100,100) → overlay (108,108) ; redimensionnement en 1000×700 à (600,300) → overlay (608,308). Les offsets d'origine de l'utilisateur (`overlayOffsetRightDip=35`, `overlayOffsetTopDip=103`) ont été restaurés après le test. Build Debug 0/0, tests 65/65, dist republié en 1.1.15 (sans bump : version non publiée).

31. **Rétention des messages de statut de l'overlay (v1.1.15)** : les messages affichés sous le panneau ne restent plus indéfiniment (bug signalé : épinglage et ajout de compte, message persistant puis réapparaissant après réduction/réouverture). `OverlayForm` centralise leur affichage dans `SetStatus(text, StatusKind)` avec une rétention par type : 5 s pour `Info`/`Success`, 8 s pour `Warning`/`Error`, aucune expiration pour `Progress` (remplacé par le résultat du switch). L'échéance absolue `_statusExpiresUtc` et le timer WinForms one-shot `_statusTimer` sont relancés à chaque message (`ExpireStatus` recale l'intervalle si le tick arrive avant l'échéance) ; `Collapse()` appelle `ClearStatus()` pour qu'un message ne réapparaisse pas à la réouverture ; `StopTimers()` arrête et libère les trois timers. Rendu inchangé : bandeau sous le panneau, couleur accentuée pendant `Progress`, et +36 DIP (`StatusHeightDip` 24 + `PaddingDip` 12) à la hauteur seulement si un statut est visible. Testé en direct (veilleur Debug 1.1.15, fausse fenêtre « Riot Client » 1700×1000 sur le second écran à (-2400,200), 100 %/96 DPI, overlay `hwnd=265956` PID 31260, clics `PostMessage`) : replié (-770,305,40×40) ; déplié 380×316 à (-1110,305) ; clic punaise à 20:13:16.771 → statut visible à 20:13:16.862 en 380×352 (= H0 + 36 DIP exactement, capture 02) puis disparition automatique à 20:13:21.858 → 380×316, soit une rétention mesurée de 5 088 ms ; re-clic punaise pour un second message → effacement 5 040 ms après le dernier clic (6 145 ms après le premier), l'échéance repart donc bien du message le plus récent ; fermeture du panneau pendant un statut (20:09:16.935, 40×40), réouverture 901 ms plus tard → 380×316 sans bandeau (capture 07), toujours sans statut à +2 s et après l'échéance du message d'origine. `settings.json` restauré à l'identique (sha256 inchangé), `accounts.json` et le dépôt non modifiés (HEAD 54c7ce49, mêmes 12 fichiers M avant/après, aucun commit). Non déclenchés en direct pour ne pas toucher aux données utilisateur : chemins `Warning`/`Error` (8 s) et `Progress` — couverts par la revue de code. Build Debug 0/0, tests 65/65.

### Mode de démarrage et lancement normal du Riot Client

- Depuis la v1.1.11, le mode **veilleur** est le mode par défaut (`BackgroundMode=Watch`, `Autostart=true`) : l'overlay apparaît à chaque lancement normal du Riot Client, et le veilleur démarre avec Windows. Il compacte sa mémoire de travail après le démarrage et à chaque retour au repos.
- Le mode **zéro fond** reste disponible explicitement (`--launch-riot --ephemeral`, raccourci « Riot Client (Switch) ») : aucun processus RiotSwitch ne reste quand le Riot Client est fermé, mais il faut passer par ce raccourci pour avoir l'overlay.
- Sur l'installation de test, les raccourcis Riot Client d'origine ont été restaurés, les paramètres sont en Watch/Autostart et le raccourci Startup pointe vers `dist\RiotSwitch.exe --watch`.

### Correctif issu du test overlay

- Bug critique trouvé dans `src/RiotSwitcher.App/WatchContext.cs` : le timer de sortie (`_exitTimer`) était initialisé après `_tracker.Start()`. Comme le tracker appelle `Check()` de façon synchrone, un `Changed` immédiat déclenchait `OnRiotWindowChanged`, puis `_exitTimer.Stop()` sur un champ encore `null` ; l'exception était avalée par le tracker et l'overlay n'était jamais créé.
- Correctif : création de `_exitTimer` avant `_tracker.Start()` ; logs de diagnostic ajoutés dans `Program`, `WatchContext` et `RiotWindowTracker`.
- Après correctif : build 0 avertissement/0 erreur, tests 42/42, overlay affiché et cliquable.

### Correctif issu du switch réel

- Cause du blocage : RiotSwitch démarrait `RiotClientServices.exe` depuis un shell qui définissait `ELECTRON_RUN_AS_NODE=1`. Le service transmettait cette variable à l'UX Electron, qui démarrait en mode Node, rejetait les arguments (`bad option: --app-port=...`) et sortait avec le code 9 ; le service passait en arrière-plan et écrasait le YAML cible par une session vide. Ce n'était ni le format de session ni l'API de vérification.
- Correctif : `RiotProcessController.BuildServiceStartInfo` lance le service avec `UseShellExecute=false`, `CreateNoWindow=true` et retire `ELECTRON_RUN_AS_NODE` / `ELECTRON_NO_ATTACH_CONSOLE` de l'environnement enfant ; tests de régression ajoutés.
- Preuve : avec la variable retirée, `Ux reports successful load` apparaît ~3 s après le démarrage ; le switch réel a ensuite exécuté le pipeline complet et le rollback a restauré B.

### Leçon : fraîcheur des sessions cibles

- Une session capturée ne doit pas être relancée entre sa capture et son utilisation comme cible : un lancement (y compris un rollback) rafraîchit/consomme le jeton et peut rendre la capture invalide.
- Le switch capture le compte courant **après fermeture propre de l'UI** ; c'est cette capture-là qui est fiable.
- Pour amorcer plusieurs comptes sans se déconnecter manuellement (ce qui peut invalider la session quittée), RiotSwitch a été testé avec la procédure « capture propre puis session live déplacée en sauvegarde » : on ferme proprement l'UI, on capture le compte, on retire la session live, puis on démarre le client sur l'écran de connexion pour le compte suivant. Les deux captures restent ainsi fraîches.
- Le test nominal A→B puis B→A a réussi avec cette procédure.

### Correctif : exception `OverlayForm` après un switch

- Symptôme : après un changement de compte lancé depuis l'overlay, une boîte « exception non gérée » affichait `Cannot access a disposed object. Object name: 'RiotSwitcher.App.OverlayForm'`.
- Cause : le panneau était ouvert, donc le timer `_outsideTimer` (vérification du clic extérieur/Échap) était actif. Pendant le switch, la fenêtre Riot se ferme et le veilleur détruit l'overlay ; un tick du timer accédait ensuite à `Handle` sur le formulaire disposé.
- Correctif : arrêt/destruction des timers dans `Dispose(bool)` (et non seulement `OnFormClosing`), gardes `IsDisposed/Disposing` dans les ticks et les méthodes de dessin/position, et journalisation des exceptions UI non gérées au lieu de la boîte WinForms.
- Validation : overlay ouvert et panneau déplié, puis switch complet vers l'autre compte (sortie 0, compte vérifié par l'API) ; le processus RiotSwitch reste actif, recrée l'overlay sur la nouvelle fenêtre Riot et aucune exception n'est affichée.

### Correctif : fermeture puis réouverture du Riot Client (v1.1.6 → v1.1.7)

- Symptôme : en mode zéro fond, après avoir fermé la fenêtre du Riot Client sans choisir « Quitter » dans la zone de notification, le switcher disparaissait ; à la réouverture du Riot Client, l'overlay n'était plus affiché.
- Première cause (v1.1.6) : `WatchContext.OnRiotWindowChanged(null)` appelait `Quit()` dès que la fenêtre disparaissait, alors que l'UX Riot peut rester chargée.
- Cause complète (v1.1.7) : fermer la fenêtre Riot fait quitter le processus UX Electron, mais le service `RiotClientServices` reste actif. Le test v1.1.6 ne vérifiait que `FindClientUi()` ; le switcher quittait donc encore.
- Correctif final : `WatchContext` garde une référence `IRiotProcessController` ; `IsRiotClientAlive()` renvoie vrai si `FindClientUi()` **ou** `FindService()` trouve un processus Riot. `ScheduleExitCheck()` programme une vérification, et `CheckExitPending()` attend la disparition réelle de l'UX et du service avant `Quit()`. Le timer de sortie reste arrêté si l'overlay existe ou pendant un switch.
- Validation v1.1.7 : lancement sans argument (mode zéro fond, `settings.json` en Launcher), overlay créé ; fermeture de la fenêtre Riot → `ui_count=0`, `service_count=1`, processus RiotSwitch toujours vivant ; réouverture par le raccourci Riot Games → nouvelle fenêtre Riot (`hwnd=109841380`) et overlay recréé (`handle=31068410`, `visible=True`), aucune exception.

### Auto-update GitHub Releases

- Client : `GitHubUpdateClient` interroge `GET https://api.github.com/repos/quentingimenez/RiotSwitch/releases/latest` (User-Agent, HTTPS, timeout 15 s), compare le tag `vX.Y.Z` à `AppInfo.Version`, exige les assets `RiotSwitch-win-x64.zip` et `RiotSwitch-win-x64.zip.sha256`.
- Téléchargement : streaming dans `%LOCALAPPDATA%\RiotSwitch\updates\<version>`, SHA-256 calculé pendant le transfert et comparé au fichier `.sha256` ; extraction protégée contre le zip-slip.
- UI : Paramètres → « Mises à jour » ; case « Vérifier automatiquement les mises à jour » (par défaut activée), « Vérifier maintenant », « Installer la mise à jour ». Vérification automatique au plus une fois par 24 h, également tentée au démarrage du veilleur.
- Installation : `UpdateApplier` refuse un dossier de build `\bin\`, écrit un script PowerShell qui attend la fin du processus, sauvegarde le dossier courant dans `%TEMP%`, copie le staging, relance `RiotSwitch.exe --watch` et journalise dans `%TEMP%\RiotSwitch-update.log`.
- CLI : `RiotSwitch.Cli.exe update` affiche la version courante, la version disponible et l'URL de release, ou « Aucune mise à jour disponible. ».
- Tests unitaires : parsing/comparaison de versions, release disponible/à jour, asset checksum absent, téléchargement + vérification SHA-256, checksum invalide, extraction normale, rejet zip-slip, persistance de `AutoCheckUpdates`/`LastUpdateCheckUtc`.

### Publication GitHub / CI

- Dépôt public créé : `https://github.com/quentingimenez/RiotSwitch` (branche `main`).
- CI `.github/workflows/ci.yml` : run vert sur le commit initial (restore, build Release, tests 62/62) ; sur `main`, publie et attache les artefacts téléchargeables **RiotSwitch-win-x64** (`dist/`) et **RiotSwitch-win-x64-singlefile** (`dist-singlefile/RiotSwitch.exe`), conservés 14 jours.
- Release `v1.0.0` : run vert, archive `RiotSwitch-win-x64.zip` (419 594 octets) et `RiotSwitch-win-x64.zip.sha256` publiées. L'archive extraite contient `RiotSwitch.exe` à la racine et `cli/RiotSwitch.Cli.exe` ; `--version` renvoie 1.0.0.
- Release `v1.1.0` : run vert, archive et SHA-256 publiés, CI verte ; contrôle `RiotSwitch.Cli.exe check-update` depuis l'archive v1.0.0 → « Mise à jour disponible : v1.1.0 ».
- Release `v1.1.1` : run vert, archive `RiotSwitch-win-x64.zip` (527 506 octets) + SHA-256 publiés ; checksum local identique, `FileVersion 1.1.1.0`, `ProductVersion 1.1.1+9ae84e9`, `--version` → `RiotSwitch 1.1.1` ; contrôle `check-update` depuis l'installation 1.1.0 → « Mise à jour disponible : v1.1.1 ».
- Release `v1.1.2` : icône agrandie (recadrage sur le contenu, seuil alpha 96, 2 % de marge ; remplissage 94–100 % selon la taille), archive `RiotSwitch-win-x64.zip` (555 674 octets) + SHA-256 publiés ; `FileVersion 1.1.2.0`, `ProductVersion 1.1.2+c338a07`, `--version` → `RiotSwitch 1.1.2` ; `check-update` depuis l'installation 1.1.1 → « Mise à jour disponible : v1.1.2 ».
- Release `v1.1.3` : run vert, quatre assets publiés — `RiotSwitch-win-x64.exe` (66 530 231 octets, self-contained single-file, sans runtime .NET), `RiotSwitch-win-x64.exe.sha256` (88 o), `RiotSwitch-win-x64.zip` (556 803 octets) et `RiotSwitch-win-x64.zip.sha256` (88 o). Téléchargement de contrôle : checksums exe et zip identiques (`Get-FileHash` SHA-256) ; exécutable portable testé en `--watch`, `FileVersion 1.1.3.0`. La variante portable détecte `AppInfo.IsPortableSingleFile` et désactive l'auto-update (mise à jour manuelle par retéléchargement de l'exe). CI : artefacts `RiotSwitch-win-x64` (555 399 o) et `RiotSwitch-win-x64-singlefile` (61 116 902 o) disponibles.
- Release `v1.1.4` : installateur Windows Inno Setup `RiotSwitch-Setup-x64.exe` (2 435 749 octets) + `.sha256` (90 o), en plus du zip, de l'exe portable et de leurs checksums. Installation silencieuse de contrôle : setup exit 0, `RiotSwitch.exe` installé en `FileVersion 1.1.4.0`, désinstalleur exit 0. Installation par utilisateur dans `%LOCALAPPDATA%\Programs\RiotSwitch` (pas d'admin), raccourcis menu Démarrer, données `%LOCALAPPDATA%\RiotSwitch` conservées à la désinstallation ; vérifie la présence de .NET 8 Desktop Runtime et propose la page de téléchargement sinon.
- Release `v1.1.5` : mode zéro fond par défaut (`BackgroundMode=Launcher`, `Autostart=false`, sans argument = lancement de Riot puis sortie avec lui) ; assets installateur, exe portable, zip et leurs SHA-256 publiés par le workflow.
- Release `v1.1.6` : run **42712626634** vert ; première correction de la fermeture de la fenêtre Riot. Assets publiés : `RiotSwitch-Setup-x64.exe` (2 437 027 o) + `.sha256` (90 o), `RiotSwitch-win-x64.exe` (66 530 579 o) + `.sha256` (88 o), `RiotSwitch-win-x64.zip` (558 857 o) + `.sha256` (88 o).
- Release `v1.1.7` : run **42713723862** vert ; correction complète — le switcher reste actif tant que l'UX **ou le service** Riot Client tourne, et recrée l'overlay quand Riot Client est rouvert. Assets publiés : `RiotSwitch-Setup-x64.exe` (2 437 462 o) + `.sha256` (90 o), `RiotSwitch-win-x64.exe` (66 530 601 o) + `.sha256` (88 o), `RiotSwitch-win-x64.zip` (559 280 o) + `.sha256` (88 o).
- Release `v1.1.8` : run **42715266552** vert ; tag de version `v1.1.8` affiché en haut à droite des Paramètres et titre `RiotSwitch — Paramètres` corrigé. Assets publiés : `RiotSwitch-Setup-x64.exe` (2 437 886 o) + `.sha256` (90 o), `RiotSwitch-win-x64.exe` (66 530 627 o) + `.sha256` (88 o), `RiotSwitch-win-x64.zip` (559 683 o) + `.sha256` (88 o).
- Release `v1.1.9` : run **42721568032** vert ; l'overlay ignore les fenêtres Riot non visibles ou recouvertes (DWM cloaked, surface visible ≥ 25 % de la zone de travail, centre non couvert par une autre application, hook `EVENT_SYSTEM_FOREGROUND`, timer de secours 2 s). Assets publiés : `RiotSwitch-Setup-x64.exe` (2 439 024 o) + `.sha256` (90 o), `RiotSwitch-win-x64.exe` (66 531 199 o) + `.sha256` (88 o), `RiotSwitch-win-x64.zip` (562 089 o) + `.sha256` (88 o).
- Release `v1.1.10` : run **42818335940** vert ; détection de visibilité assouplie (échantillonnage 5×5, au moins 20 % des points exposés) pour ne plus masquer l'overlay quand seule une petite fenêtre recouvre le centre du Riot Client. Assets publiés : `RiotSwitch-Setup-x64.exe` (2 439 738 o) + `.sha256` (90 o), `RiotSwitch-win-x64.exe` (66 531 304 o) + `.sha256` (88 o), `RiotSwitch-win-x64.zip` (563 295 o) + `.sha256` (88 o).
- Release `v1.1.12` : run **42830091692** vert (release) ; restauration unique d'un Riot Client ouvert réduit (`RiotClientWindow.FindMinimized` + `SW_RESTORE`, handles déjà vus mémorisés). Assets publiés : `RiotSwitch-Setup-x64.exe` (2 442 051 o) + `.sha256` (90 o), `RiotSwitch-win-x64.exe` (66 532 100 o) + `.sha256` (88 o), `RiotSwitch-win-x64.zip` (566 663 o) + `.sha256` (88 o).
- Release `v1.1.13` : run **42833799432** vert ; l'overlay survit aux disparitions transitoires de la fenêtre Riot pendant le rendu (`_absentSinceUtc` + `AbsentGraceMs=3500`), plus de destruction/recréation pendant le chargement. Assets publiés : `RiotSwitch-Setup-x64.exe` (2 442 657 o) + `.sha256` (90 o), `RiotSwitch-win-x64.exe` (66 532 280 o) + `.sha256` (88 o), `RiotSwitch-win-x64.zip` (567 261 o) + `.sha256` (88 o).
- Release `v1.1.14` : remontée unique du Riot Client lancé sans focus (`FindPresent` + `RaiseIfNotForeground` / `ForceForeground`) pour que l'overlay soit réellement visible ; timer de secours réduit à 1 s ; doublon `Riot Client.lnk` retiré du menu Démarrer. Test réel : Riot lancé derrière le GUI DSH → « remontée unique », fenêtre Riot au premier plan, overlay `handle=6293618` visible et cliquable. Assets publiés : `RiotSwitch-Setup-x64.exe` + `.sha256`, `RiotSwitch-win-x64.exe` + `.sha256`, `RiotSwitch-win-x64.zip` + `.sha256`.
- Release `v1.1.11` : run **42827862538** vert (release) ; veilleur par défaut (`Watch`/`Autostart`), compactage mémoire du veilleur (première passe à 2 s puis au-delà de 32 Mo sans overlay), correction `RiotWindowTracker`. Assets publiés : `RiotSwitch-Setup-x64.exe` (2 440 998 o) + `.sha256` (90 o), `RiotSwitch-win-x64.exe` (66 531 745 o) + `.sha256` (88 o), `RiotSwitch-win-x64.zip` (565 022 o) + `.sha256` (88 o) ; checksum du zip téléchargé vérifié (`86014b9a…`).
- Installation réelle : depuis l'application v1.0.0 extraite, Paramètres → « Installer la mise à jour » → téléchargement, vérification SHA-256, sauvegarde, remplacement des fichiers par `UpdateApplier`, relance du veilleur en 1.1.0 (`FileVersion 1.1.0.0`) ; journal `%TEMP%\RiotSwitch-update.log` et artefacts supprimés après validation.

- Workflows : `.github/workflows/ci.yml` (push/PR : restore, build Release, tests, artefacts `RiotSwitch-win-x64` et `RiotSwitch-win-x64-singlefile`) et `.github/workflows/release.yml` (tag `v*` : vérifie la version du code, publie l'application framework-dependent win-x64, crée l'archive + SHA-256, publie l'exe autonome + SHA-256 puis la release GitHub).

## Pré-requis pour la validation finale

- Le Riot Client est lancé normalement (pas élevé) et l'interface est visible.
- Deux comptes au moins sont accessibles.
- Aucune partie n'est en cours pendant les essais (le garde-fou doit être testé séparément, sans tuer la partie).
- Faire une capture du compte A et du compte B (connexion manuelle à chacun).

> Ne jamais lancer un switch pendant une partie. Le garde-fou est censé l'empêcher ; le test de ce garde-fou se fait en lançant une partie, en vérifiant que le switch est refusé, puis en fermant la partie.

## Checklist manuelle

### 1. Premier lancement

- [ ] Lancer `RiotSwitch.exe` sans argument.
- [ ] Vérifier l'assistant : texte français, choix du mode, démarrage Windows, raccourcis Bureau.
- [ ] Choisir « Veilleur en arrière-plan », cocher le démarrage Windows et les raccourcis.
- [ ] Vérifier la création de `%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup\RiotSwitch.lnk` et des deux raccourcis Bureau.
- [ ] Vérifier que l'application ne crée aucune fenêtre parasite et qu'aucune erreur n'apparaît.

### 2. Overlay attaché

- [ ] Ouvrir le Riot Client ; l'overlay doit apparaître en haut à droite de la fenêtre, sans voler le focus.
- [ ] Cliquer sur le bouton ⇄ : le panneau s'ouvre, le compte actuel est affiché.
- [ ] Cliquer en dehors ou appuyer sur Échap : le panneau se ferme.
- [ ] Déplacer la fenêtre du Riot Client : l'overlay suit.
- [x] L'overlay reste au-dessus de la fenêtre Riot quand elle revient au premier plan ou après un recouvrement (mise en dessous provoquée : réassertion en ≤ 700 ms).
- [x] Déplacement de la fenêtre Riot : l'overlay suit sans retard perceptible (mesuré 1–2 ms).
- [ ] Minimiser / restaurer : l'overlay suit ou disparaît correctement.
- [ ] Tester sur un second écran et avec une mise à l'échelle 125 % / 150 %.
- [ ] Glisser le bouton pour le déplacer, redémarrer l'application, vérifier que la position est conservée ; vérifier que le bouton puis le panneau ne peuvent pas sortir de la fenêtre du client (bords droit, gauche, haut, bas) et que le panneau reste ouvert pendant un glisser bloqué par un bord.
- [x] Épingler puis déplacer la fenêtre Riot : l'overlay épinglé suit la fenêtre et le glisser est neutralisé ; désépingler réactive le glisser (v1.1.15, voir point 29).
- [ ] Fermer le Riot Client : l'overlay disparaît ; le veilleur reste caché (mode Watch) ou quitte (mode zéro fond).

### 3. Ajout de comptes

- [ ] Connecté en A, cliquer « + Ajouter le compte actuel » ; vérifier le compte dans la liste avec le bon Riot ID.
- [ ] Se déconnecter, se connecter en B, ajouter B.
- [ ] Vérifier que les deux comptes apparaissent et que le compte actuel est marqué « Actuel ».
- [ ] Renommer un compte via Paramètres ; vérifier la persistance.
- [ ] Supprimer un compte ; vérifier que le bundle et l'entrée disparaissent.
- [ ] Vérifier `accounts.json` : aucun jeton, uniquement les métadonnées.

### 4. Switch réel A→B

- [x] Depuis A, lancer le switch vers B (test CLI ; l'overlay utilise le même `SwitchService`).
- [x] Le Riot Client se ferme, se relance, et le compte affiché est B.
- [x] Vérifier que l'API locale renvoie le PUUID de B (`status`).
- [x] Vérifier qu'aucun écran de connexion n'est demandé.
- [ ] Vérifier le journal `logs/app.log` : aucune valeur de jeton.
- [x] Refaire B→A et A→B (stabilité).
- [ ] Redémarrer Windows, vérifier que le mode veilleur redémarre et que l'overlay fonctionne.

### 5. Échec et rollback

- [ ] Provoquer un échec contrôlé (par exemple arrêter le service Riot au mauvais moment, ou simuler une session cible invalide en laboratoire).
- [ ] Vérifier que le compte précédent est restauré et que le message d'erreur est explicite.
- [ ] Vérifier que `switch-journal.json` est supprimé après un rollback réussi.
- [ ] Vérifier qu'aucun fichier Riot n'est resté à moitié écrit.

### 6. Garde-fou partie

- [ ] Lancer une partie (ou un entraînement) et vérifier que le switch est refusé avec le message « Une partie est en cours ».
- [ ] Fermer la partie ; vérifier que le switch redevient possible.
- [ ] Ouvrir uniquement le client League ; vérifier que la confirmation demandée est claire et que refuser annule le switch.

### 7. Modes et raccourcis

- [x] `--launch-riot --ephemeral` : démarre le Riot Client, affiche l'overlay, quitte quand le Riot Client se ferme ; aucun processus RiotSwitch restant.
- [ ] Raccourci « Riot Client (Switch) » : même comportement.
- [ ] `--settings` : ouvre les paramètres ; si un veilleur tourne, il les affiche dans l'instance existante.
- [ ] `--attach` : attache un overlay à une interface Riot Client déjà ouverte.
- [ ] `--version`, `--help`.

### 8. Mises à jour

- [ ] Paramètres → « Vérifier maintenant » avec la dernière release : « À jour » ou une version disponible s'affiche sans erreur.
- [ ] Désactiver « Vérifier automatiquement », enregistrer, relancer : aucune vérification automatique (vérifier `lastUpdateCheckUtc` dans `settings.json`).
- [x] Depuis une version publiée plus ancienne, installer la mise à jour depuis les paramètres : téléchargement, vérification SHA-256, remplacement des fichiers et relance du veilleur (validé v1.0.0 → v1.1.0).
- [ ] Vérifier qu'un dossier de build (`\bin\`) refuse l'installation automatique avec un message clair.
- [ ] Vérifier `%TEMP%\RiotSwitch-update.log` et l'absence de fichier `.part` résiduel.

### 9. Performances

- [ ] Mode veilleur sans Riot : aucune fenêtre, CPU 0 % au repos, mémoire mesurée.
- [ ] Overlay affiché : vérifier l'absence de clignotement et la réactivité du panneau.
- [ ] Pendant un switch : le client se ferme et se relance sans erreur.
- [ ] Vérifier qu'aucun fichier de log ne grossit indéfiniment (rotation 1 Mo × 3).

## Diagnostics utiles

```powershell
RiotSwitch.Cli.exe status
RiotSwitch.Cli.exe doctor
Get-Content "$env:LOCALAPPDATA\RiotSwitch\logs\app.log" -Tail 80
Get-Content "$env:LOCALAPPDATA\RiotSwitch\switch-journal.json" -ErrorAction SilentlyContinue
```

Sonde API locale (lecture seule) :

```powershell
node tools\probe-riot-api.js GET /rso-auth/v1/authorization
node tools\probe-riot-api.js POST /riot-client-lifecycle/v1/show
node tools\probe-riot-api.js POST /riot-client-lifecycle/v1/hide
```

## Critères d'acceptation

- Build et tests verts.
- Un switch A↔B fonctionne sans mot de passe et sans écran de connexion, vérifié par l'API locale.
- L'overlay n'apparaît que quand la fenêtre du Riot Client est visible.
- Le mode veilleur ne crée aucune fenêtre quand Riot est fermé ; le mode zéro fond ne laisse aucun processus.
- Le garde-fou bloque une partie en cours et demande confirmation pour le client League.
- Le rollback restaure le compte précédent en cas d'échec.
- Aucun secret (mot de passe, jeton) n'est stocké ou journalisé.
- La documentation permet à un utilisateur de refaire l'installation et la validation.
