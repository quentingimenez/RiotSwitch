# Validation

Ce document liste les vérifications déjà effectuées et la checklist restante avant de considérer RiotSwitch comme prêt à l'emploi.

## État au 9 novembre 2026

| Élément | État |
| --- | --- |
| Build solution (Debug) | ✅ 0 avertissement, 0 erreur |
| Tests unitaires Core | ✅ 62/62 |
| CLI `status` / `doctor` / `window` (lecture seule, installation réelle) | ✅ |
| Capture des comptes A et B | ✅ compte A et compte B enregistrés dans le coffre, format PslV1 |
| Auto-update (version, GitHub Releases, SHA-256, zip-slip) | ✅ tests unitaires (62/62) ; vérification et installation réelles validées de la release v1.0.0 vers v1.1.0 |
| Publication GitHub + CI | ✅ dépôt public `quentingimenez/RiotSwitch`, CI verte, releases `v1.0.0` à `v1.1.6` ; v1.1.3 ajoute un exécutable autonome + SHA-256, v1.1.4 ajoute l'installateur Inno Setup + SHA-256, v1.1.5 passe le zéro fond en mode par défaut, v1.1.6 conserve le switcher quand la fenêtre Riot est réduite dans la zone de notification |
| Icône de l'application | ✅ logo « Twin Profiles » transparent intégré (`app.ico` multi-tailles + `Assets/logo-twin-profiles.png`), contenu agrandi dans v1.1.2 (recadrage serré sans ombre portée, 94–100 % du cadre selon la taille), icône vérifiée dans l'exe et les fenêtres |
| API locale : authentification lockfile + lecture du PUUID | ✅ |
| Mode veilleur caché (sans Riot) | ✅ aucune fenêtre, 0 % CPU au repos, WorkingSet ≈ 55 Mo / privé ≈ 12 Mo |
| Overlay visuel attaché | ✅ testé sur second écran : bouton 40×40, panneau déplié 340×200, clic sans vol de focus |
| Épinglage de l'overlay | ✅ punaise testée : position écran verrouillée (`overlayPinned`, `overlayPinnedRightPx/TopPx`), déplacement de la fenêtre Riot sans bouger l'overlay, désépinglage sans saut de position |
| Ordre des comptes | ✅ `MoveAccount` (▲/▼) et tri A → Z testés sur 3 comptes, persistance après rechargement, ordre partagé coffre/overlay/paramètres |
| `--launch-riot --ephemeral` | ✅ testé depuis un shell pollué (`ELECTRON_RUN_AS_NODE=1`) : UI ouverte, overlay créé, processus quitté avec le client |
| Switch via l'overlay (clic réel) | ✅ B→A puis A→B déclenchés en cliquant sur le bouton ⇄ puis sur la ligne du compte ; API locale vérifiée après chaque relance, journal nettoyé |
| Switch réel A↔B | ✅ validé le 09/11 vers 19:55 : A→B puis B→A, sortie 0, vérification API du PUUID, UI et service relancés |
| Rollback réel | ✅ provoqué par des sessions cibles expirées : retour au compte précédent, UI restaurée, journal effacé (avant correctif d'environnement, puis pipeline complet revalidé) |
| Mode zéro fond par défaut | ✅ `AppSettings.BackgroundMode = Launcher` et `Autostart=false` par défaut, `Normalize` retombe sur Launcher, sans argument l'application démarre Riot puis quitte avec lui ; `--watch` explicite conserve le veilleur persistant (build/tests 62/62). Test réel v1.1.6 : lancement sans argument, overlay créé ; fermeture de la fenêtre Riot vers la zone de notification → switcher toujours actif ; réouverture → overlay recréé |
| Premier lancement WelcomeForm | ⏳ à valider |
| Publish `dist/` | ✅ republié en 1.1.6 (`dist\RiotSwitch.exe`, `dist\cli\RiotSwitch.Cli.exe`) |

### Détails de l'environnement validé

- Windows 11 Pro 26200, .NET SDK 8.0.403.
- Riot Client 142.0.0 (`C:\Riot Games\Riot Client`), session `PslV1`, UI Electron 1536×864.
- Comptes de test : compte A et compte B, tous deux connectés et capturés dans le coffre ; les identifiants personnels ne sont pas publiés dans ce document.
- Coffre : `%LOCALAPPDATA%\RiotSwitch`, 2 comptes (A et B), captures fraîches ; sauvegardes pré-switch et replace.

### Vérifications déjà réalisées

1. `dotnet build RiotSwitcher.sln -v minimal --nologo` → succès.
2. `dotnet test tests\RiotSwitcher.Core.Tests\RiotSwitcher.Core.Tests.csproj -v minimal --nologo --no-build` → 62 réussis (dont les tests de l'environnement de lancement du service, de l'ordre des comptes et de l'auto-update).
3. `RiotSwitch.Cli.exe status` → installation, session, compte, PUUID, API locale, garde-fou et coffre affichés correctement.
4. `RiotSwitch.Cli.exe doctor` → chemins, DPAPI, compte, sauvegardes et garde-fou affichés.
5. `RiotSwitch.Cli.exe capture` → compte courant enregistré, `list` le retrouve.
6. `RiotSwitch.exe --watch` → processus unique caché, aucune fenêtre, CPU 0 % au repos.
7. `POST /riot-client-lifecycle/v1/show` → 204, interface Riot Client ouverte ; `POST /riot-client-lifecycle/v1/hide` → 204, interface refermée sans perturber la partie en cours.
8. API locale : `GET /rso-auth/v1/authorization` renvoie le PUUID du compte courant ; `GET /rso-auth/v1/session` répond `authenticated`.
9. `RiotSwitch.exe --attach` : overlay attaché à la fenêtre `Riot Client` (hwnd `94440460`, PID `28248`) déplacée sur le second écran ; clic sur le bouton via message Windows ; panneau déplié (340×200 DIP) avec compte actuel, boutons et fermeture ; aucun vol de focus. Les captures de test (contenant le compte personnel) ont été supprimées après vérification.
10. `RiotSwitch.Cli.exe window` : détection de la fenêtre Riot Client confirmée (hwnd, PID, titre, position, topmost).
11. `RiotSwitch.exe --launch-riot --ephemeral` lancé depuis un shell avec `ELECTRON_RUN_AS_NODE=1` : le service a démarré avec un environnement nettoyé, l'UI Electron s'est chargée (`Ux reports successful load` à ~2,9 s), l'overlay a été créé, puis l'application s'est arrêtée sans laisser de processus RiotSwitch.
12. Switch B→A réel avec la session A ancienne : écriture de la cible, arrêt/relance du service et de l'UI, vérification API (cible non confirmée), rollback vers B. État final : session B valide, UI B ouverte, API connectée sur B, journal `switch-journal.json` absent, 2 comptes toujours présents. Code de sortie 5, message « Le client n'a pas confirmé le compte cible. Retour au compte précédent. »
13. **Switch nominal A↔B réussi** (09/11, ~19:55) après la procédure de capture propre :
    - B capturé après fermeture propre de l'UI (19:52), puis session live déplacée en sauvegarde pour forcer un écran de connexion ;
    - démarrage du service avec environnement nettoyé, connexion manuelle à A ;
    - `RiotSwitch.Cli.exe switch "Compte B" --yes` : sortie 0, compte B activé et vérifié dans le client Riot, API locale sur le compte B, UI B ouverte ;
    - `RiotSwitch.Cli.exe switch "Compte A" --yes` : sortie 0, retour au compte A vérifié, UI A ouverte, 2 comptes toujours présents.
14. Publish : `dist/` est republié après ces vérifications et les dernières retouches de docs (`powershell -ExecutionPolicy Bypass -File tools\publish.ps1`).
15. **Exception post-switch corrigée** : panneau déplié puis switch via l'overlay (`--attach`) ; la fenêtre Riot est fermée/relancée, l'overlay est recréé, le processus reste actif, aucune boîte d'exception, compte cible vérifié par l'API.
16. **Épinglage de l'overlay** : panneau ouvert, clic sur la punaise → `overlayPinned=true` et coordonnées écran enregistrées ; déplacement de la fenêtre Riot de +80 px sans modifier le rect de l'overlay ; clic sur la punaise → `overlayPinned=false` en conservant la position. Le bouton replié et le panneau restent alignés sur le même bord droit.
17. **Ordre des comptes** : `SessionVault.MoveAccount` testé vers le haut/bas (bornes incluses) et `SortAccountsAlphabetically` testé sur trois comptes ; l'ordre est relu depuis `accounts.json` après rechargement et utilisé par l'overlay et les paramètres. Interface : boutons ▲ Monter / ▼ Descendre / Trier A → Z ; l'ordre est rafraîchi dans l'overlay à la fermeture des paramètres.
18. **Fenêtre Riot réduite dans la zone de notification (v1.1.6)** : lancement sans argument en mode zéro fond, overlay créé ; `ShowWindow(SW_HIDE)` → switcher toujours actif après 3 s ; `ShowWindow(SW_SHOWNOACTIVATE)` → overlay recréé (`handle=225381126`, `visible=True`), sans exception ni doublon.

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

### Correctif : fermeture de la fenêtre Riot vers la zone de notification (v1.1.6)

- Symptôme : en mode zéro fond, après avoir fermé la fenêtre du Riot Client sans choisir « Quitter » dans la zone de notification, le switcher disparaissait ; à la réouverture du Riot Client, l'overlay n'était plus affiché.
- Cause : dans `WatchContext.OnRiotWindowChanged(null)`, le switcher appelait `Quit()` dès que la fenêtre disparaissait, alors que le processus UI Riot Client reste chargé quand la fenêtre est réduite dans la zone de notification.
- Correctif : `WatchContext` garde une référence `IRiotProcessController` et ne quitte plus tant que `FindClientUi()` trouve un processus `Riot Client` ; `ScheduleExitCheck()` programme une nouvelle vérification, et `CheckExitPending()` attend la disparition réelle du processus UI avant de terminer. Le timer de sortie reste arrêté si l'overlay existe ou pendant un switch.
- Validation : lancement sans argument (mode zéro fond, `settings.json` en Launcher), Riot Client ouvert, overlay créé ; `ShowWindow(hwnd, 0)` pour simuler la réduction en zone de notification → processus RiotSwitch toujours vivant après 3 s ; `ShowWindow(hwnd, 4)` → overlay recréé (`handle=225381126`, `visible=True`), aucun doublon, aucune exception.

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
- Release `v1.1.6` : run **42712626634** vert ; correctif de la fermeture de la fenêtre Riot vers la zone de notification (le switcher reste actif et recrée l'overlay à la réouverture). Assets publiés : `RiotSwitch-Setup-x64.exe` (2 437 027 o) + `.sha256` (90 o), `RiotSwitch-win-x64.exe` (66 530 579 o) + `.sha256` (88 o), `RiotSwitch-win-x64.zip` (558 857 o) + `.sha256` (88 o).
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
- [ ] Minimiser / restaurer : l'overlay suit ou disparaît correctement.
- [ ] Tester sur un second écran et avec une mise à l'échelle 125 % / 150 %.
- [ ] Glisser le bouton pour le déplacer, redémarrer l'application, vérifier que la position est conservée.
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
