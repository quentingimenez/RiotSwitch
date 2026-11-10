# Guide d'utilisation de RiotSwitch

> Guide détaillé — le [README](../README.md) résume l'essentiel ; ce document couvre l'installation, l'usage, la ligne de commande, la confidentialité et le dépannage.

RiotSwitch garde plusieurs comptes Riot Games connectés et permet de passer de l'un à l'autre depuis un petit overlay attaché au Riot Client, sans se déconnecter et se reconnecter à la main.

## Installation

### Prérequis

- Windows 10 ou 11 en 64 bits.
- Riot Client installé (League of Legends, VALORANT, etc.).
- .NET 8 Desktop Runtime (ou le SDK .NET 8 pour compiler). Le binaire publié est framework-dependent.
- Être connecté à chaque compte au moins une fois pour l'enregistrer dans le coffre.

### Depuis GitHub Releases (recommandé)

Télécharge `RiotSwitch-win-x64.zip` depuis la dernière [release GitHub](https://github.com/quentingimenez/RiotSwitch/releases), vérifie le fichier `.sha256` fourni, puis extrais l'archive dans un dossier stable (par exemple `%LOCALAPPDATA%\Programs\RiotSwitch`) et lance `RiotSwitch.exe`. Le binaire est framework-dependent : le [.NET 8 Desktop Runtime](https://dotnet.microsoft.com/download/dotnet/8.0) doit être installé.

Les releases sont construites automatiquement par GitHub Actions à chaque tag `v*` : archive `RiotSwitch-win-x64.zip` + empreinte SHA-256.

### Installateur Windows

Chaque release fournit **`RiotSwitch-Setup-x64.exe`**, un installateur Inno Setup : installation par utilisateur (aucun droit administrateur), raccourcis dans le menu Démarrer, désinstalleur propre et conservation de tes comptes/sauvegardes dans `%LOCALAPPDATA%\RiotSwitch` lors d'une désinstallation.

L'installateur vérifie la présence de **.NET 8 Desktop Runtime (x64)** et propose la page de téléchargement s'il manque. Il ferme proprement un éventuel veilleur RiotSwitch avant de remplacer les fichiers.

### Exécutable autonome (sans installation)

Chaque release fournit aussi **`RiotSwitch-win-x64.exe`**, un exécutable autonome d'environ 64 Mo : il embarque le runtime .NET, donc **aucune installation du .NET 8 Desktop Runtime n'est nécessaire**. Télécharge-le, vérifie le `.sha256` associé et lance-le directement.

Cette variante portable ne propose pas l'auto-update (pour mettre à jour, retélécharge l'exécutable depuis la dernière release) ; l'auto-update reste disponible pour l'installation en dossier issue du zip.

### Depuis la CI (build récent)

Chaque push sur `main` produit aussi un artefact téléchargeable, sans attendre une release :

1. Ouvre l'onglet **Actions** → dernier run **CI** vert.
2. En bas du résumé du run, télécharge l'artefact **RiotSwitch-win-x64** (dossier complet) ou **RiotSwitch-win-x64-singlefile** (exécutable autonome seul).
3. Pour l'artefact dossier, extrais l'archive : `RiotSwitch.exe` se trouve à la racine, avec ses dépendances et le CLI dans `cli/`. L'artefact singlefile contient directement `RiotSwitch.exe`.

L'artefact CI est conservé 14 jours et n'est pas signé comme une release ; pour une installation durable, préfère l'archive de release ci-dessus.

### Depuis les sources

```powershell
cd RiotSwitch
powershell -ExecutionPolicy Bypass -File tools\publish.ps1
```

Le dossier `dist\` contient `RiotSwitch.exe`, ses dépendances, le CLI dans `dist\cli\` et le README. Copie le dossier `dist` où tu veux (par exemple `%LOCALAPPDATA%\Programs\RiotSwitch`) et lance `RiotSwitch.exe`.

Pour compiler et tester toi-même :

```powershell
dotnet build RiotSwitcher.sln
dotnet test tests\RiotSwitcher.Core.Tests\RiotSwitcher.Core.Tests.csproj
powershell -ExecutionPolicy Bypass -File tools\publish.ps1
```

La solution s'organise en `src/RiotSwitcher.Core` (session, coffre DPAPI, API locale, processus, switch), `src/RiotSwitcher.App` (overlay WinForms/GDI+, veilleur, paramètres), `src/RiotSwitcher.Cli` (diagnostic et scripts), `tests/RiotSwitcher.Core.Tests`, `tools/` (publication, sonde API locale) et `docs/` (architecture et validation) ; le détail des composants est décrit dans [architecture.fr.md](architecture.fr.md).

## Premier lancement

1. Lance `RiotSwitch.exe`. L'assistant de premier lancement s'ouvre.
2. Choisis le mode :
   - **Veilleur en arrière-plan (par défaut)** : RiotSwitch reste discret en mémoire (aucune fenêtre), démarre avec Windows et affiche l'overlay dès que la fenêtre du Riot Client apparaît. Il est optimisé pour rester très léger : WorkingSet d'environ 10–16 Mo au repos après compactage (privé ≈ 14–16 Mo) et CPU quasi nul (≈0,3 % d'un cœur en mesure précise, 0 % affiché dans le Gestionnaire des tâches).
   - **Zéro fond** : RiotSwitch ne tourne pas tant que le Riot Client n'est pas lancé. Le raccourci « Riot Client (Switch) » (fourni par l'installateur) démarre le Riot Client et le veilleur ensemble ; le veilleur quitte avec le Riot Client. **Important :** si tu lances le Riot Client par son raccourci habituel, RiotSwitch ne démarre pas et l'overlay n'apparaît pas.
3. Ouvre le Riot Client et connecte-toi au premier compte.
4. Clique sur le bouton ⇄ en haut à droite, puis sur « + Ajouter le compte actuel » : le compte connecté est ajouté au coffre.
5. Déconnecte-toi, connecte-toi au second compte, puis ajoute-le de la même façon.
6. Les deux comptes apparaissent dans le panneau : un clic suffit pour basculer.

> Le premier ajout doit être fait depuis chaque compte, une fois connecté. RiotSwitch ne peut pas fabriquer une session à partir d'un mot de passe : il capture la session existante.

## Overlay

- **Bouton replié** : petit carré arrondi en haut à droite de la fenêtre du Riot Client (déplaçable, sans jamais sortir de la fenêtre du client).
- **Panneau** : compte actuel, liste des comptes, dates de dernière utilisation, bouton « + Ajouter », « Paramètres » et « Actualiser ».
- **Changement de compte** : un clic sur une ligne bascule sur ce compte. RiotSwitch ferme proprement le Riot Client, remplace le fichier de session, relance le client, puis vérifie via l'API locale (`/rso-auth/v1/authorization`) que le compte réellement connecté est bien celui demandé. La séquence interne complète est décrite dans [architecture.fr.md](architecture.fr.md).
- **Nouvelle interface (v1.1.16)** : panneau compact (380 DIP) et contrasté — palette conforme WCAG AA/AAA, rail d'accent + badge texte « Actuel » à la place de l'avatar à initiale, en-tête et footer resserrés, statuts colorés avec icône (2 lignes maximum), barre de défilement visible au-delà de 5 comptes, états de survol et d'appui sur tous les contrôles. Maquette, spécification et captures dans [`overlay-ui/`](overlay-ui/).
- **Texte net (v1.1.17)** : le panneau est rendu en `ClearTypeGridFit` — glyphes accrochés aux sous-pixels — au lieu de l'antialiasing grayscale non accroché de GDI+, qui rendait les petites tailles floues à côté du texte DirectWrite du Riot Client. Vérifié par capture écran 1:1 et comparaison hors écran (voir [validation.fr.md](validation.fr.md), point 32).
- **Ordre des comptes** : Paramètres → « Comptes enregistrés » → sélectionne un compte puis « ▲ Monter » / « ▼ Descendre », ou « Trier A → Z ». L'ordre est enregistré dans le coffre et utilisé par l'overlay.
- **Épinglage** : l'icône punaise dans l'en-tête du panneau verrouille l'overlay à sa place **relative à la fenêtre Riot** — il continue de suivre la fenêtre quand elle se déplace, mais ne peut plus être déplacé à la souris par erreur. Clique à nouveau sur la punaise pour le libérer.
- **Déplacement limité à la fenêtre du client** : en glissant le bouton ou le panneau, l'overlay reste toujours entièrement à l'intérieur de la fenêtre du Riot Client (marge de 8 DIP sur chaque bord). Il s'arrête aux bords même si le curseur continue au-delà, et le panneau ne se referme pas pendant le glisser. Une position mémorisée hors de la fenêtre (fenêtre redimensionnée ou ancienne version) est ramenée automatiquement dans la zone visible, sans saut.
- **Toujours au-dessus du client** : l'overlay reste juste au-dessus de la fenêtre du Riot Client, y compris quand elle revient au premier plan après avoir été recouverte ; un hook d'événements Windows le replace au-dessus du client si son ordre Z dérive. Il passe en revanche derrière les autres applications quand le client perd le focus.
- **Suivi immédiat** : l'overlay suit le déplacement de la fenêtre Riot en 1–2 ms (hook `EVENT_OBJECT_LOCATIONCHANGE` filtré sur la fenêtre cible), sans attendre le timer de secours de 500 ms et sans redessiner tant que seule la position change.
- **Messages de statut temporisés** : les messages affichés sous le panneau (épinglage, ajout de compte, résultat de switch, avertissement) disparaissent seuls — 5 s pour une information ou un succès, 8 s pour un avertissement ou une erreur — et un changement de compte affiche sa progression jusqu'au résultat. Un nouveau message remplace le précédent et relance son délai ; fermer le panneau efface le message, il ne réapparaît pas à la réouverture.
- **Fermeture du panneau** : clic en dehors ou touche Échap.
- **Version affichée** : la version courante (par exemple `v1.1.17`) est affichée en haut à droite de la fenêtre des paramètres.
- **Visibilité et restauration** : l'overlay n'apparaît que lorsque la fenêtre du Riot Client est visible ; il disparaît avec elle. Au lancement, il tolère 3,5 s de disparition transitoire pendant le rendu de la page avant de se masquer, pour éviter les clignotements. Si le Riot Client démarre sans focus (derrière le navigateur ou une autre fenêtre), le veilleur le remonte **une seule fois** par lancement pour que l'overlay soit réellement visible. Si le client s'ouvre **réduit** (par exemple juste après un redémarrage ou une mise à jour), le veilleur le restaure une seule fois pour afficher l'overlay ; si tu le minimises toi-même ensuite, l'overlay se masque et il ne le rouvre pas. En mode zéro fond, fermer la fenêtre Riot vers la zone de notification ne quitte pas le switcher : il reste actif tant que Riot Client tourne (UX visible/fermée ou service en arrière-plan) et recrée l'overlay à la réouverture. Il ne s'arrête que lorsque Riot Client quitte réellement.

## Ligne de commande

### Modes de `RiotSwitch.exe`

```text
RiotSwitch.exe                  # mode par défaut : veilleur en arrière-plan
RiotSwitch.exe --watch          # veilleur caché persistant, sans fenêtre ni icône de notification
RiotSwitch.exe --launch-riot    # démarre le Riot Client (ou rouvre son interface) puis le veilleur
RiotSwitch.exe --launch-riot --ephemeral
                                # zéro fond : lance Riot Client et quitte quand il se ferme
RiotSwitch.exe --settings       # ouvre les paramètres (ou les affiche dans l'instance déjà lancée)
RiotSwitch.exe --attach         # attache un veilleur à l'interface Riot Client déjà ouverte (diagnostic)
RiotSwitch.exe --version
RiotSwitch.exe --help
```

Huit modes au total : sans argument (veilleur en arrière-plan par défaut), `--watch`, `--launch-riot`, `--launch-riot --ephemeral` (zéro fond), `--settings`, `--attach`, `--version` et `--help`.

### CLI de diagnostic

Le CLI est prévu pour le dépannage et les tests, pas pour l'usage quotidien. Il se trouve dans le sous-dossier `cli\` de l'installation (par exemple `dist\cli\RiotSwitch.Cli.exe`) :

```powershell
RiotSwitch.Cli.exe list
RiotSwitch.Cli.exe status
RiotSwitch.Cli.exe doctor
RiotSwitch.Cli.exe window
RiotSwitch.Cli.exe capture --label "Compte principal"
RiotSwitch.Cli.exe switch "Compte principal" --product league_of_legends
RiotSwitch.Cli.exe restore <fichier.rsw>
RiotSwitch.Cli.exe update          # vérifie les mises à jour GitHub Releases
```

Codes de sortie du CLI : `0` succès, `1` erreur, `2` partie en cours, `3` cible/session invalide, `4` accès refusé, `5` vérification échouée (dont reconnexion manuelle requise).

> `--yes` confirme uniquement la fermeture du client League of Legends ; il ne permet jamais de contourner le blocage d'une partie en cours.

## Mises à jour

RiotSwitch vérifie les nouvelles versions via l'API GitHub Releases de `quentingimenez/RiotSwitch` :

- **Vérification automatique** : au démarrage du veilleur et dans les paramètres, au maximum une fois toutes les 24 h. Désactivable avec la case « Vérifier automatiquement les mises à jour » (Paramètres → Mises à jour). La dernière vérification est enregistrée dans `settings.json`.
- **Vérification manuelle** : bouton « Vérifier maintenant » dans les paramètres, ou commande `RiotSwitch.Cli.exe update`.
- **Installation** : bouton « Installer la mise à jour » (affiché quand une version est disponible). L'archive est téléchargée dans `%LOCALAPPDATA%\RiotSwitch\updates`, son empreinte SHA-256 est vérifiée, puis un script remplace les fichiers après l'arrêt du veilleur et relance `RiotSwitch.exe --watch`. La mise à jour n'est proposée que pour une installation publiée (pas depuis un dossier `bin` de développement).
- **Désactivation complète** : décoche la case et enregistre. Aucune requête réseau de mise à jour n'est alors effectuée ; l'installation manuelle reste possible en téléchargeant l'archive depuis GitHub.
- **Données échangées** : seules des données non sensibles transitent — version courante, version disponible et téléchargement de l'archive publique. Les sessions Riot, le coffre et les comptes ne sont jamais envoyés.

## Données et confidentialité

- **Coffre** : `%LOCALAPPDATA%\RiotSwitch\`
  - `accounts.json` : métadonnées des comptes (libellé, Riot ID, PUUID, région), jamais de jetons.
  - `%LOCALAPPDATA%\RiotSwitch\sessions\<puuid>.rsw` : fichier de session Riot chiffré (DPAPI, utilisateur Windows courant).
  - `backups\` : sauvegardes chiffrées, 5 maximum.
  - `logs\app.log` : journal sans jetons (les valeurs sensibles sont masquées).
  - `settings.json` : préférences de l'application.
  - `switch-journal.json` : journal de reprise d'un switch interrompu (supprimé après succès).
- RiotSwitch capture le fichier de session Riot **entier** pour chaque compte, le chiffre et le stocke dans son coffre. Il fonctionne sans mot de passe : seuls les fichiers de session Riot sont conservés, chiffrés avec DPAPI (utilisateur Windows courant).
- Le fichier de session live `%LOCALAPPDATA%\Riot Games\Riot Client\Data\RiotGamesPrivateSettings.yaml` reste en clair : c'est le fichier utilisé par Riot lui-même. RiotSwitch ne le rend pas plus lisible qu'il ne l'est déjà.
- Aucun mot de passe, code OTP ou jeton n'est stocké par RiotSwitch.
- Aucune donnée de session ne part sur Internet : la seule communication réseau locale est une requête HTTPS vers `127.0.0.1`, sur le port du lockfile du Riot Client.
- Aucune télémétrie et aucun envoi de données de session. La seule requête réseau sortante est la vérification des mises à jour GitHub Releases, désactivable dans les paramètres.

## Garde-fous et limites

- **Partie en cours** : le switch est bloqué si `League of Legends`, `VALORANT`, `VALORANT-Win64-Shipping` ou `LoR` tourne. Si seul le client League est ouvert, une confirmation est demandée avant de le fermer.
- **Session expirée** : si Riot a invalidé la session d'un compte, le switch échoue avec un écran de connexion. RiotSwitch **ne revient pas automatiquement au compte précédent** : le client reste sur la page de connexion, avec la session cible installée. Reconnecte-toi une fois avec ce compte puis réenregistre-le (« + Ajouter le compte actuel »). Le rollback automatique ne subsiste que si le client confirme un autre compte que la cible.
- **Mises à jour Riot** : le format du fichier de session peut changer. RiotSwitch refuse les formats inconnus ou les sessions DPoP plutôt que d'écrire un fichier incohérent. Une nouvelle version du projet peut être nécessaire.
- **Client Riot élevé** : si le Riot Client tourne en administrateur, RiotSwitch (non élevé) peut ne pas pouvoir l'arrêter. Lance les deux au même niveau de privilèges, sans élever inutilement.
- **Pas d'injection** : le bouton n'est pas injecté dans Electron ; c'est une fenêtre overlay attachée à la fenêtre du client. Cela évite de modifier l'asar, de casser l'intégrité et de déclencher l'anti-triche. RiotSwitch ne modifie jamais les exécutables, l'asar, la configuration d'installation ou les fichiers de paramètres du Riot Client.
- **Un seul Riot Client à la fois** : RiotSwitch gère l'unicité de son propre veilleur ; il ne permet pas d'avoir deux sessions Riot simultanées.

### Avertissement

> RiotSwitch n'est pas un produit Riot Games et n'est pas approuvé par Riot. Le partage de compte et certaines automatisations sont encadrés par les conditions d'utilisation de Riot ; ce projet est destiné à basculer entre **tes propres comptes** sur **ta propre machine**. Il ne stocke pas tes identifiants et ne contourne pas l'authentification : il réutilise des sessions que tu as créées normalement. En cas de doute, vérifie les conditions d'utilisation Riot applicables à ton pays et n'utilise pas l'outil si tu n'es pas à l'aise avec ce risque.

## Dépannage

| Symptôme | Piste |
| --- | --- |
| L'overlay n'apparaît pas | Vérifie que la fenêtre du Riot Client est ouverte (pas seulement le service en arrière-plan). Lance `RiotSwitch.exe --attach` et regarde le journal. |
| « Accès refusé » pendant le switch | Le Riot Client tourne probablement en administrateur. Ferme-le et relance-le normalement, ou lance RiotSwitch avec les mêmes droits. |
| « API locale indisponible » | Le service Riot n'est pas lancé ou le lockfile est absent. Ouvre le Riot Client ; `RiotSwitch.Cli.exe doctor` affiche les chemins et l'état. |
| Le switch échoue et revient au compte précédent | Le client a confirmé un autre compte que la cible. Consulte `%LOCALAPPDATA%\RiotSwitch\logs\app.log` et `switch-journal.json` ; le rollback est automatique. |
| Session invalide / écran de connexion | Le switch laisse le client sur l'écran de connexion, sans retour automatique au compte précédent. Reconnecte-toi une fois au compte, puis « + Ajouter le compte actuel ». |
| Le panneau est mal positionné | Paramètres → « Réinitialiser la position de l'overlay ». |

## Voir aussi

- [Architecture](architecture.fr.md) — composants, formats de données, séquence de switch et décisions de conception.
- [Validation](validation.fr.md) — état de validation détaillé (build 0 avertissement/0 erreur, tests 65/65, correctifs par version), checklist manuelle et diagnostics utiles.
- [Spécification de l'overlay](overlay-ui/spec-overlay.fr.md) — refonte de l'interface, tokens, mesures WCAG et plan de test.
- [README](../README.md) — résumé de l'essentiel et liens vers les autres documents.
