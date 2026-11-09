# Architecture

Ce document décrit l'implémentation de RiotSwitch : composants, formats de données, séquence de switch et décisions de conception.

## Vue d'ensemble

```
┌──────────────────────────────┐
│          RiotSwitch.exe       │
│  (WinForms, aucune console)   │
│                               │
│  Program / WatchContext       │
│   ├─ RiotWindowTracker        │  surveille la fenêtre du Riot Client
│   ├─ OverlayForm              │  bouton + panneau attachés au client
│   ├─ SettingsForm / Welcome   │  configuration
│   └─ ShortcutService          │  raccourcis Bureau / démarrage
│                               │
│  Core (bibliothèque)          │
│   ├─ RiotPaths / Locator      │  chemins réels de l'installation
│   ├─ RiotSessionReader        │  lecture du YAML de session
│   ├─ RiotLocalApi             │  vérification via l'API locale
│   ├─ SessionVault / Dpapi     │  coffre chiffré DPAPI
│   ├─ RiotProcessController    │  fermeture / relance des processus
│   ├─ GameGuard                │  garde-fou parties en cours
│   └─ SwitchService            │  orchestration + rollback + journal
│                               │
│  CLI (RiotSwitch.Cli.exe)     │  status / doctor / capture / switch
└──────────────────────────────┘
```

Aucun processus Windows, service, pilote, icône de notification ou injection Electron n'est utilisé. L'application est un simple exécutable WinForms.

## Modes d'exécution

### Mode veilleur (`--watch`, par défaut)

- Un seul processus caché (mutex `Local\RiotSwitch.Watch`).
- Une fenêtre message-only permet aux autres instances de demander l'ouverture des paramètres ou la fermeture.
- `RiotWindowTracker` combine `SetWinEventHook` (création/destruction/affichage/déplacement de fenêtres) et un timer de secours de 5 secondes.
- Tant qu'aucune fenêtre du Riot Client n'est visible, aucun overlay n'existe : pas de fenêtre, pas de dessin, pas d'activité CPU mesurable.
- Dès que la fenêtre apparaît, l'overlay est créé et attaché comme fenêtre possédée par le Riot Client (il suit ses déplacements et disparaît avec elle).

### Mode zéro fond (`--launch-riot --ephemeral`)

- RiotSwitch démarre le Riot Client puis s'exécute en mode veilleur.
- Quand la fenêtre du Riot Client disparaît, le veilleur quitte (`exitOnClientClose` + délai de grâce de 30 s au démarrage pour laisser le client s'ouvrir).
- Aucun processus RiotSwitch ne reste une fois le Riot Client fermé.

### Autres modes

- `--settings` : ouvre les paramètres, ou les fait apparaître dans l'instance déjà lancée via un message Windows.
- `--attach` : attache un veilleur de diagnostic à une interface Riot Client déjà ouverte.
- `--version`, `--help`.

## Détection de la fenêtre Riot Client

`RiotClientWindow.Find()` énumère les fenêtres de premier niveau et retient celles qui :

- sont visibles et non minimisées ;
- ont le titre exact `Riot Client` ;
- appartiennent au processus `Riot Client` (Electron) ;
- mesurent au moins 1000×700.

Le splash screen est topmost et plus petit ; s'il est topmost, une taille minimale de 1400×800 est exigée. La plus grande fenêtre valide est retenue. Le service `RiotClientServices.exe` n'a pas de fenêtre et ne déclenche donc jamais l'overlay.

## Overlay

- Fenêtre WinForms `WS_EX_LAYERED | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE`, sans bordure, sans entrée dans la barre des tâches.
- Owner = fenêtre du Riot Client (`SetWindowLongPtr(GWLP_HWNDPARENT)`), donc l'overlay passe derrière le client quand il perd le focus et se ferme avec lui.
- Rendu GDI+ dans un bitmap 32 bpp, présenté par `UpdateLayeredWindow` : pas de clignotement, pas d'animation, coins arrondis et ombre dessinés.
- Aucune activation de fenêtre (`ShowWithoutActivation`) : cliquer sur le bouton ne vole pas le focus au client Riot ; les paramètres s'ouvrent dans une vraie boîte de dialogue.
- Géométrie exprimée en DIP, mise à l'échelle via `GetDpiForWindow` (100–250 %), position clampée au moniteur courant.
- Position persistée dans `settings.json` ; bouton déplaçable par glisser ; panneau refermé par clic extérieur ou Échap.
- Épinglage : l'icône punaise de l'en-tête enregistre le bord droit et le haut de l'overlay en coordonnées écran (`overlayPinned`, `overlayPinnedRightPx`, `overlayPinnedTopPx`). Tant que l'overlay est épinglé, il ignore les déplacements de la fenêtre Riot et le glisser est désactivé. Le désépinglage reconvertit la position en offsets relatifs au client pour éviter tout saut.
- Le panneau est volontairement simple : pas de liste virtualisée, pas d'images distantes, pas de dépendance réseau.

## Lecture et validation de la session

`RiotSessionReader` ne désérialise pas tout le YAML (le format Riot évolue). Il extrait de façon ciblée :

- `psl.authorization.riot-client` (format PslV1, format actuel) ;
- `id_token` (JWT) et `refresh_token` (JWE) ;
- `is_dpop_bound` ;
- `riot-login.persist` ;
- `rso-authenticator.tdid` (cookie) ;
- l'ancien format `riot-login.persist.session.cookies` / `ssid` (LegacyCookies, best-effort).

L'`id_token` est décodé en base64url (sans vérification de signature, inutile ici) pour lire le PUUID (`sub`), le Riot ID (`acct.game_name#acct.tag_line`), la locale, le pays, la région et l'expiration. Une session est switchable si elle n'est pas DPoP, qu'elle est persistante et qu'elle contient les éléments requis par son format.

## Coffre

```
%LOCALAPPDATA%\RiotSwitch\
  accounts.json          # métadonnées, en clair, sans jetons
  sessions\<puuid>.rsw   # bundle chiffré DPAPI
  backups\               # sauvegardes chiffrées, 5 max
  logs\app.log           # journal, valeurs sensibles masquées
  settings.json          # préférences
  switch-journal.json    # état de reprise d'un switch (supprimé après succès)
```

Un bundle `.rsw` est composé de :

```
"RSW1" | version (1 octet) | SHA-256 tronqué (8 octets) | DPAPI(payload)
payload = ZIP contenant :
  manifest.json
  session/RiotGamesPrivateSettings.yaml
  profile/...                # optionnel : profil Electron de secours
```

DPAPI utilise `CurrentUser` et une entropie applicative (`RiotSwitch:v1:session`). Le bundle ne peut donc être ouvert que par le même utilisateur Windows sur la même machine. Le manifeste contient l'ID de compte, le PUUID, le Riot ID, le format, la date de capture, le SHA-256 et la taille du YAML, ainsi que la liste des fichiers de profil éventuels.

Les écritures de `accounts.json` et du YAML live passent par `AtomicFile` : fichier temporaire dans le même dossier, flush, `File.Replace`/`Move` avec réessais, et sauvegarde `.bak` pour les comptes.

L'ordre des comptes est celui de la liste `accounts.json` : c'est l'ordre choisi par l'utilisateur. `SessionVault.MoveAccount` déplace une entrée et `SessionVault.SortAccountsAlphabetically` applique un tri stable (nom affiché, Riot ID, identifiant) ; les deux passent par le verrou inter-processus et la sauvegarde atomique. L'overlay et les paramètres affichent cette liste sans retrier par date d'utilisation, afin que le réglage soit partagé.

## Séquence de switch

```
Switch(request)
 ├─ 1. résoudre le compte cible dans le coffre (PUUID / libellé / Riot ID)
 ├─ 2. vérifier que la session cible est complète et switchable
 ├─ 3. lire la session live actuelle
 ├─ 4. si le compte cible est déjà connecté -> AlreadyCurrent
 ├─ 5. GameGuard.Check()
 │     ├─ partie en cours (League/Valorant/LoR) -> refus
 │     └─ client League seul -> confirmation
 ├─ 6. verrou Local\RiotSwitch.Switch + signal Local\RiotSwitch.Switching
 ├─ 7. journaliser le début du switch
 ├─ 8. fermer l'UI Riot (WM_CLOSE, attente 10 s, puis kill si nécessaire)
 ├─ 9. relire le YAML APRÈS fermeture (flush des jetons)
 ├─ 10. capturer la session courante dans le coffre + backup
 ├─ 11. arrêter la pile Riot (crash handler, service, UI restante)
 ├─ 12. si confirmé, fermer le client League
 ├─ 13. revérifier le garde-fou avant écriture
 ├─ 14. écrire le YAML cible atomiquement
 ├─ 15. restaurer le profil Electron si le bundle en contient un
 ├─ 16. relancer le service Riot (et le produit choisi si demandé)
 ├─ 17. attendre la fenêtre (60 s)
 ├─ 18. vérifier le PUUID via l'API locale (15 s)
 ├─ 19. succès -> marquer le compte, effacer le journal
 └─ échec -> rollback : restaurer la sauvegarde, relancer le Riot Client
```

Le switch est refusé si une autre instance en effectue déjà un (mutex) ou si un jeu tourne. Un switch vers le compte déjà connecté ne fait rien.

### Vérification réelle du compte

Le fichier YAML prouve seulement ce qui a été écrit, pas ce que le client a réellement chargé. Après la relance, `RiotLocalApi` interroge :

```
GET https://127.0.0.1:<port>/rso-auth/v1/authorization
Authorization: Basic riot:<mot de passe du lockfile>
```

et compare `subject` (PUUID) au compte cible. Si le client affiche un autre compte, ou si l'API ne répond pas dans les 15 secondes, le switch est considéré comme échoué et un rollback est déclenché. Le mot de passe du lockfile n'est jamais journalisé.

### Environnement du service et de l'UX

Le service `RiotClientServices.exe` transmet son environnement à l'UX Electron. Si RiotSwitch est lancé depuis un shell qui définit `ELECTRON_RUN_AS_NODE=1` (certaines IDE, harnais ou outils Node), l'UX démarre en mode Node, rejette les arguments du type `--app-port=...` (`bad option`) et sort avec le code 9 : le client reste sans interface. Le service, lui, continue en arrière-plan et peut écraser le YAML avec une session vide.

`RiotProcessController.BuildServiceStartInfo` construit donc un `ProcessStartInfo` avec `UseShellExecute=false`, `CreateNoWindow=true`, et retire `ELECTRON_RUN_AS_NODE` et `ELECTRON_NO_ATTACH_CONSOLE` de l'environnement avant de démarrer le service. Cette précaution est couverte par des tests unitaires. Elle ne modifie pas l'environnement global de la machine ni celui des autres applications.

### Journal et reprise

`switch-journal.json` est écrit avant la fermeture du client et mis à jour à chaque étape (client fermé, service arrêté, cible écrite). Si l'application est interrompue au milieu d'un switch, le journal permet de savoir où en est l'opération et de décider d'un rollback ou d'une reprise au prochain démarrage.

## Garde-fou

`GameGuard` classe les processus :

- blocage dur : `League of Legends`, `VALORANT`, `VALORANT-Win64-Shipping`, `LoR` ;
- confirmation : `LeagueClient`, `LeagueClientUx`, `LeagueClientUxRender` (le switch ferme le client League) ;
- sinon autorisé.

Le garde-fou est vérifié avant la mutation et revérifié juste avant l'écriture du fichier de session.

## Décisions de conception

### Pourquoi un overlay et pas une injection Electron ?

L'injection réelle (patch de l'asar, proxy DLL, CDP) permet d'insérer un bouton dans le DOM du client, mais :

- le Riot Client vérifie l'intégrité de ses ressources ;
- les mises à jour remplaceraient le patch ;
- l'anti-triche et les conditions d'utilisation Riot rendent l'opération risquée ;
- l'injection modifie des fichiers Riot, ce qui est difficile à réparer et à expliquer à l'utilisateur.

L'overlay attaché donne la même expérience (bouton au-dessus du client, panneau de comptes) sans toucher aux fichiers Riot. Il est plus robuste face aux mises à jour, même s'il n'est pas « à l'intérieur » de la fenêtre.

### Pourquoi remplacer le fichier entier plutôt que réécrire des champs ?

Le format du fichier de session a changé plusieurs fois (ancien bloc `ssid`, nouveau bloc `psl` avec jetons JWE/DPoP). Réécrire un sous-ensemble suppose de connaître le parseur exact et le format de chaque version. Le remplacement du fichier entier est agnostique au format : on capture ce que Riot a écrit, on le remet tel quel. Le lecteur ne sert qu'à extraire les métadonnées et à vérifier que la session est complète.

### Pourquoi ne pas stocker les mots de passe ?

Un mot de passe stocké devrait être chiffré, mais resterait un secret réutilisable et contournerait l'authentification à deux facteurs. La session existante est déjà un secret, mais elle est limitée dans le temps, révocable et liée à l'utilisateur. RiotSwitch ne peut pas créer de session à partir d'un mot de passe, ce qui est aussi une protection : il ne peut agir que sur des comptes déjà connectés sur cette machine.

### Pourquoi l'API locale pour vérifier ?

Le YAML est écrit par RiotSwitch, pas par Riot ; il ne suffit donc pas à prouver que le client a accepté la session. L'API locale du service Riot expose le PUUID réellement authentifié (`/rso-auth/v1/authorization`). C'est la seule source de vérité fiable et elle fonctionne même quand l'interface Electron est fermée. La requête reste strictement locale (localhost, certificat auto-signé, authentification par lockfile).

### Profil Electron de secours

Dans la majorité des cas, le fichier de session suffit. Si un jour une session ne se reconnecte pas correctement, RiotSwitch peut capturer et restaurer le profil Electron (`Network/Cookies`, `Cookies-journal`, `Local Storage/leveldb`) dans le même bundle chiffré. Cette option est désactivée par défaut ; elle n'est pas nécessaire au fonctionnement actuel et n'a pas encore été validée sur une session réelle. Elle ne touche jamais `Local State`, `Preferences`, `Config` ou `RiotClientSettings.yaml`, qui contiennent des réglages machine.

## Mises à jour et publication

- **Source de vérité** : `GitHubUpdateClient` interroge `/repos/quentingimenez/RiotSwitch/releases/latest`. Le tag doit être `vX.Y.Z` ; les assets attendus sont `RiotSwitch-win-x64.zip` et `RiotSwitch-win-x64.zip.sha256`. La version courante vient de `AppInfo.Version`.
- **Téléchargement** : archive téléchargée en streaming dans `%LOCALAPPDATA%\RiotSwitch\updates\<version>`, SHA-256 calculé au fil de l'eau puis comparé au checksum publié. Le déplacement final n'a lieu qu'après fermeture des flux. L'extraction passe par `ZipSafeExtractor`, qui rejette toute entrée sortant du dossier de staging (zip-slip).
- **Vérification automatique** : `AutoCheckUpdates` (true par défaut) et `LastUpdateCheckUtc` sont dans `settings.json`. Le veilleur et les paramètres respectent un cache de 24 h ; la case des paramètres permet de désactiver complètement la vérification.
- **Installation** : `UpdateApplier` refuse un dossier de développement contenant `\bin\`, écrit un script PowerShell qui attend la fin du processus courant, sauvegarde le dossier d'installation dans `%TEMP%`, copie le staging, relance `RiotSwitch.exe --watch` et journalise dans `%TEMP%\RiotSwitch-update.log`.
- **CI/CD** : `.github/workflows/ci.yml` compile et teste sur `windows-latest` à chaque push/PR ; `.github/workflows/release.yml` se déclenche sur un tag `v*`, vérifie la cohérence version/tag, publie le binaire framework-dependent win-x64, génère l'archive et son SHA-256, puis crée la release GitHub. Les workflows n'ont besoin que de `contents: write` pour la release.

## Limites connues

- Les sessions Riot expirent ou peuvent être révoquées ; un switch sur une session expirée échoue proprement et demande une reconnexion.
- Les formats DPoP (`is_dpop_bound: true`) ne sont pas pris en charge ; ils sont refusés plutôt que cassés.
- Le format exact du YAML peut changer avec une mise à jour de Riot ; le lecteur est tolérant mais devra peut-être être adapté.
- Le client Riot peut tourner élevé (administrateur) sur certaines installations ; RiotSwitch ne s'auto-élève pas.
- Le seuil mémoire du veilleur est mesuré autour de 55 Mo de WorkingSet (~12 Mo privés) ; c'est le coût du runtime .NET/WinForms, pas de l'overlay (qui n'existe pas quand le client est fermé).
- L'overlay n'est pas dans le DOM du client : il ne suit pas le rendu interne, seulement la fenêtre. Il est ancré à la fenêtre et passe derrière elle quand elle passe derrière.
