# Spécification — refonte de l’overlay RiotSwitch

> Version 1 — 10/11/2026. Compagnon de `maquette.html` (maquette 1:1) et de
> `standards-references.md` (sources et chiffres). Périmètre : bouton replié et
> panneau déplié de l’overlay ; `SettingsForm` reste inchangé.
>
> **Statut : implémenté** dans `src/RiotSwitcher.App/OverlayForm.cs` le 10/11/2026.
> Revue indépendante appliquée : états d’appui sur épingler/fermer/footer, ombre
> du panneau restaurée, statuts longs coupés à 2 lignes avec ellipse.
> Captures du rendu GDI+ réel (hors écran) : `captures/implementation/` (22 rendus).

## 1. Objet et périmètre

**Dans le périmètre** : le bouton replié, le panneau de comptes, son en-tête, le
bandeau du compte connecté, les lignes de compte, l’état vide, le défilement, le
footer d’actions, les 5 messages de statut et tous les états de survol/appui.

**Hors périmètre** : la fenêtre de paramètres, le positionnement de l’overlay,
la persistance (coffre DPAPI, YAML Riot), le service de switch, les timings, la
capture de session, l’architecture.

**Contraintes techniques inchangées** : fenêtre WinForms *layered* dessinée en
GDI+, `WS_EX_NOACTIVATE` (pas de focus clavier), interaction souris uniquement,
largeur panneau **380 DIP**, **5 lignes visibles**, échelle via `ScaleTransform`,
aucune animation, aucun paquet ni ressource ajoutés.

## 2. Décisions et justification

| Problème constaté | Décision | Preuve / règle |
|---|---|---|
| Avatar à initiale redondant avec le nom | Supprimé ; ligne active = rail 3 px + badge texte « Actuel » | WCAG 1.4.1 (la couleur ne porte pas seule l’information) |
| Bloc « ACTUEL » de 64 px qui répète la ligne active | Remplacé par un bandeau « ✓ Connecté · RiotID » de 24 px | densité ; même information, 40 DIP gagnés |
| Accent #D13639 à 3,72:1 (échec AA) | Accent texte #FF9C9C à **8,9:1** (AAA) | WCAG 1.4.3 / 1.4.6 |
| Textes de 8,5 à 9,5 pt, peu lisibles en GDI+ | Échelle 15 / 14 / 12 px ; badge 10,5 px | Fluent 2 (plancher 12 px), XAG 102 |
| Aucun retour au survol sur boutons, pin, fermeture | Survol + appui sur tous les éléments interactifs | Material 3 state layers 8 % / 10 % |
| Défilement invisible au-delà de 5 comptes | Barre 3 px visible dès 6 comptes | WCAG 1.4.11 (3:1), convention bureau |
| Statuts gris uniformes, tronqués à 1 ligne | 5 types icône + couleur + texte, 2 lignes max | WCAG 1.4.1, XAG 102 |

## 3. Tokens

### 3.1 Couleurs

Ratios WCAG 2.2 mesurés sur `surface-1` (#17171E) sauf mention. AAA = ≥ 7:1,
AA = ≥ 4,5:1, UI = ≥ 3:1 (1.4.11).

| Token | Hex | Usage | Ratio |
|---|---|---|---|
| `surface-1` | #17171E | fond du panneau | — |
| `surface-2` | #1F1F28 | boutons, survol des lignes | — |
| `surface-3` | #262631 | survol des boutons | — |
| `surface-4` | #2E2E3A | appui des boutons | — |
| `line-1` | #2A2A35 | séparateur, bord de bouton | 1,26:1 (décoratif) |
| `line-2` | #3A3A48 | bord au survol | 1,6:1 (décoratif) |
| `text-1` | #F2F2F7 | titre, noms, texte principal | **15,98:1** AAA |
| `text-2` | #C4C4D0 | bandeau connecté, libellés, statut info | **10,32:1** AAA |
| `text-3` | #A6A6B8 | Riot ID, dates, icônes au repos | **7,44:1** AAA |
| `red-300` | #FF9C9C | accent texte, badge, action primaire | **8,9:1** AAA |
| `red-500` | #E23B41 | rail actif, dégradé du bouton | 4,25:1 sur blanc (non textuel) |
| `red-400` | #F05258 | survol du bouton | — |
| `red-600` | #A8232B | bas du dégradé | — |
| `red-700` | #8E1C24 | appui | — |
| `red-row` | #2A181D | fond de la ligne active | texte 15,09:1 dessus |
| `red-row-hover` | #322027 | survol de la ligne active | — |
| `red-badge` / `red-badge-line` | #3A2027 / #5A2A32 | fond / bord du badge | 7,41:1 (red-300 dessus) |
| `green-300` | #7BE0A3 | succès, « Connecté » | **11,07:1** AAA |
| `amber-300` | #F4C36B | avertissement | **10,92:1** AAA |
| `error-300` | #FF8585 | erreur | **7,6:1** AAA |
| `scroll-thumb` / `scroll-track` | #75758A / #2A2A35 | défilement | **3,15:1** (≥ 3:1) |

Les teintes opaques (`red-row`, `red-badge`) remplacent toute superposition
alpha : GDI+ ne compose pas les groupes et la fenêtre layered n’offre pas de
transparence par pixel fiable.

### 3.2 Typographie

Segoe UI. Poids 600 = `FontStyle.Bold` (ou « Segoe UI Semibold » avec repli
Bold). Conversion GDI+ : `pt = px × 0,75`.

| Rôle | Taille / interligne | Poids | GDI+ |
|---|---|---|---|
| Titre du panneau | 15 / 20 px | 600 | 11,25 pt Bold |
| Nom de compte | 14 / 18 px | 600 | 10,5 pt Bold |
| Nom connecté (bandeau) | 12 / 24 px | 600 | 9 pt Bold |
| Riot ID | 12 / 16 px | 400 | 9 pt |
| Date | 12 / 16 px, chiffres tabulaires | 400 | 9 pt |
| Boutons du footer | 12 / 16 px | 400 | 9 pt |
| Badge « Actuel » | 10,5 / 16 px | 600 | 7,875 pt Bold |
| Libellé « Connecté » | 11 / 24 px | 600 | 8,25 pt Bold |
| Statut | 12 / 16 px | 400 | 9 pt |

Aucun texte porteur sous 12 px ; seuls le badge (10,5) et le libellé du bandeau
(11) descendent en dessous, avec des ratios ≥ 7:1.

### 3.3 Espacements et rayons

- Grille de **4 px** (Fluent 2) : 4, 8, 10, 12, 16.
- Padding du panneau : haut **10**, côtés **16**, bas **12**.
- Rayons : panneau **12**, boutons/lignes/icônes **8** (icônes 6), badge **5**,
  rail **2**, barre de défilement **2**.
- Bouton replié : **40 × 40**, rayon **10**.

### 3.4 Dimensions du panneau

Largeur **380 DIP** (bordure dessinée à 0,5 px comprise). Hauteur :

```
H = 153 + listH + statusBlock
listH      = 0 compte ? 64 : min(N,5) × 48 + (min(N,5) − 1) × 4
statusBlock = statut ? 8 + lignes × 16 : 0      (lignes = 1 ou 2)
```

| Cas | listH | statut | H |
|---|---|---|---|
| Vide | 64 | — | **217** |
| 1 compte | 48 | — | **201** |
| 3 comptes | 152 | — | **305** |
| 3 comptes + message 1 ligne | 152 | 24 | **329** |
| 3 comptes + message 2 lignes | 152 | 40 | **345** |
| 5 comptes | 256 | — | **409** |
| 5 comptes + message 2 lignes | 256 | 40 | **449** |
| 6 ou 7 comptes | 256 | — | **409** (+ barre de défilement) |

Repères verticaux depuis le haut du panneau :

| Élément | y |
|---|---|
| En-tête (40 px) | 11 → 51 |
| Bandeau connecté (24 px) | 53 → 77 |
| Séparateur (1 px) | 82 |
| Liste (lignes de 48, pas de 52) | 92 … 92 + listH |
| Footer (36 px) | 92 + listH + 12 |
| Statut | footerBas + 8 |

Le cadre utile va de x = 17 à x = 363 (346 px de large) : bordure 1 px + padding
16. La barre de défilement occupe x = 370 → 373.

## 4. Composants

### 4.1 Bouton replié

- Fenêtre repliée 40 × 40 ; bouton dessiné dans le rect (0, 0, 40, 40), rayon 10.
- Dégradé 160° : `#E23B41` → `#C22F37` (55 %) → `#A8232B`, ombre portée
  (rect arrondi décalé de +2/+4, noir alpha 90–110, technique actuelle) + liseré
  interne blanc alpha 20 % en haut.
- Icône ⇄ : deux lignes horizontales et quatre têtes de flèche, pinceau blanc
  2,2 px, bouts ronds — géométrie actuelle conservée, recentrée dans le bouton.
- États (aucun focus clavier) :

| État | Dégradé | Ombre |
|---|---|---|
| Repos | #E23B41 → #C22F37 → #A8232B | +2/+4, alpha 90 |
| Survol | #F05258 → #D23A42 → #B02A32 | +3/+5, alpha 105 |
| Appui | #C22F37 → #9E1F27 → #8E1C24 | +1/+2 + ligne interne sombre en haut |

Le bouton n’a pas d’état épinglé : l’épinglage est porté par le panneau.

### 4.2 Panneau

**En-tête (40 px)** — titre « Comptes Riot » à x = 17, 15 px/600. Deux cibles
28 × 28 à y = 17 : épingler à x = 305, fermer à x = 335, rayon 6. Survol des deux
cibles : fond `surface-2`, icône `text-1` ; appui `surface-3` ; épinglé :
fond `red-badge`, icône pleine `red-300` (forme + couleur).

**Bandeau connecté (24 px)** — à x = 17 : coche 13 px `green-300`, libellé
« Connecté » 11 px/600 `green-300`, point « · » `text-3`, puis Riot ID 12 px/600
`text-2`. Si aucun client : icône info, « Client Riot non détecté » en `text-2`
(variante `is-off`). Jamais tronqué : ellipse sur le Riot ID.

**Séparateur** — 1 px `line-1`, de x = 17 à 363, à y = 82.

**Lignes (48 px, pas de 52)** — x = 17, largeur 346, rayon 8, fond transparent.
- Ligne active : fond `red-row`, rail `red-500` de 3 × 30 px à x = rowX + 4,
  y + 9 (rayon 2) ; badge « Actuel » après le nom (écart 8) : 10,5/16, 600,
  `red-300` sur `red-badge`, bord `red-badge-line`, padding 0 6, rayon 5.
- Survol : `surface-2` ; survol de la ligne active : `red-row-hover`.
- Textes : nom à (x + 14, y + 7), 14/18, largeur disponible moins badge ;
  Riot ID à (x + 14, y + 26), 12/16, ellipse ; date alignée à droite
  (rowRight − 10), 12/16, chiffres tabulaires, placeholder « — ».
- Clic sur la ligne = bascule de compte (comportement inchangé), y compris
  pendant un switch si l’état `_busy` le permet aujourd’hui.

**État vide** — zone de 64 px de haut (listH = 64), titre « Aucun compte
enregistré » 13/18 `text-1`, sous-titre 12/16 `text-3` :
« Connecte-toi dans le client Riot, puis clique sur « Ajouter ». »

**Défilement** — uniquement si N > 5. Piste `scroll-track` 3 px à x = 370,
hauteur = listH ; curseur `scroll-thumb` 3 px, hauteur
`max(24, listH × 5 / N)`, position proportionnelle à l’index de défilement.
La molette conserve sa vitesse et son bornage actuels.

**Footer** — 36 px de haut, à y calculé ; trois boutons de
(346 − 2 × 8) / 3 = **110 px** de large, écart 8, rayon 8, fond `surface-2`,
bord `line-1`. Contenu centré : icône 14 px `text-2` + écart 6 + libellé 12 px
`text-1`. Survol : fond `surface-3`, bord `line-2` ; appui : `surface-4`.
« Ajouter » est l’action primaire, signalée par élévation neutre (aucun rouge) :
fond `surface-3`, bord `line-2`, icône et libellé `text-1` ; survol et appui
`surface-4`. Les deux autres boutons restent sur `surface-2` / `surface-3`.

**Statut** — sous le footer, marge haute 8. Icône 14 px à x = 17, texte à
x = 37, largeur 326, 12/16, **2 lignes maximum**. Couleur par type :

| Type | Icône | Couleur | Exemple |
|---|---|---|---|
| Information | cercle + i | `text-2` / icône `text-3` | « Position verrouillée : l’overlay suit la fenêtre mais ne peut plus être déplacé. » |
| Succès | coche | `green-300` | « QuentinG ajouté. » |
| Avertissement | triangle + ! | `amber-300` | « League of Legends est ouvert. Ferme le jeu puis réessaie — le changement de compte nécessite un client Riot fermé. » |
| Erreur | cercle + × | `error-300` | « Changement impossible : session expirée. Reconnecte-toi avec ce compte. » |
| Progression | flèche circulaire | `red-300` | « Changement vers Smurf… » |

L’icône et le texte portent le sens ; la couleur ne fait que renforcer.

### 4.3 États et interactions

| Zone | Survol | Appui | Action |
|---|---|---|---|
| Bouton replié | dégradé clair | enfoncement | déplier |
| Ligne | `surface-2` | — | basculer de compte |
| Épingler | fond `surface-2` | `surface-3` | verrouiller le glisser |
| Fermer | fond `surface-2` | `surface-3` | replier |
| Bouton footer | `surface-3` | `surface-4` | Ajouter / Paramètres / Actualiser |
| Molette | — | — | défiler la liste |
| Glisser (panneau non épinglé) | — | — | déplacer, borné à 8 DIP des bords |
| Clic extérieur / Échap | — | — | replier |

Le survol se met à jour à chaque `WM_MOUSEMOVE` ; un changement d’état déclenche
un seul `Invalidate()` (pas de timer, pas d’animation). Le clavier reste hors
périmètre, comme aujourd’hui.

## 5. Correspondance avec `OverlayForm.cs`

### 5.1 Constantes

| Constante | Avant | Après |
|---|---|---|
| `ButtonSizeDip` | 40 | 40 (inchangé) |
| `PanelWidthDip` | 380 | 380 (inchangé) |
| `VisibleRows` | 5 | 5 (inchangé) |
| `RowHeightDip` | 52 | 48 + `RowGapDip` = 4 |
| `HeaderHeightDip` | 52 | 40 |
| `CurrentHeightDip` | 64 | 24 (`ConnectedHeightDip`) |
| `FooterButtonHeightDip` | 32 | 36 |
| `StatusHeightDip` | 24 | calculé (8 + 16 × lignes) |
| `PaddingDip` | 12 | 10 / 16 / 12 |
| rayons | 9 | 12 panneau, 8 contrôles, 5 badge |

### 5.2 Méthodes

- `DrawButton` : dégradé 3 arrêts + ombre et états ; conserver la géométrie des
  flèches.
- `DrawPanel` : rayon 12, bordure `line-1`, ombre inchangée dans son principe.
- `DrawHeader` : nouvelle hauteur, titre 11,25 pt, deux cibles de 28 × 28 avec
  survol, punaise pleine si épinglée, fermeture 15 pt.
- `DrawCurrentAccount` → `DrawConnected` : bandeau de 24 px, coche + libellé
  vert + Riot ID ; variante « non détecté ».
- `DrawAccounts` : suppression de l’avatar ; rail et badge pour la ligne
  active ; nom 10,5 pt, ID et date 9 pt ; états de survol ; état vide ;
  barre de défilement si N > 5.
- `DrawFooter` : hauteur 36, boutons de 110 px, icônes 14 px, action primaire en
  `red-300`, survols.
- `DrawStatus` : icône 14 px + texte 12/16 sur 2 lignes, couleur selon
  `StatusKind`, hauteur mesurée (`MeasureString` / `StringFormat`).
- `ComputeLayout` : appliquer la formule du §3.4 et les repères verticaux.
- Nouveaux champs : `_hoverRow`, `_hoverButton`, `_hoverPin`, `_hoverClose`,
  `_scrollIndex` (si absent), et hit-tests associés.

### 5.3 Notes GDI+

- `AntiAliasGridFit` conservé ; la fenêtre layered ne peut pas utiliser ClearType
  → tailles minimales §3.2.
- Teintes opaques obligatoires pour les fonds translucides (pas d’alpha en
  composition de groupe).
- `StringFormat` : `Trimming = EllipsisCharacter`, `NoWrap` pour les lignes,
  `StringAlignment.Far` pour la date ; la mesure du nom sert à placer le badge.
- DPI : toutes les valeurs en DIP via le `ScaleTransform` existant ; tester
  100, 125, 150, 200 et 250 %.
- Pas de fichier image ni de police d’icônes : les icônes sont des tracés GDI+
  (mêmes formes que la maquette).

## 6. Accessibilité et limites

- Contraste : tous les textes porteurs sont ≥ 7:1 (AAA) ; les composants
  (rail, badge, barre de défilement) ≥ 3:1 (1.4.11) ; les bordures de bouton et
  le séparateur sont décoratifs, l’identification venant du texte et de l’icône
  (1.4.11 s’applique aux éléments nécessaires à la compréhension) ; les états
  combinent forme + texte + couleur (1.4.1).
- Cibles : bouton replié 40 × 40, boutons 36 px de haut, pin/fermer 28 × 28 —
  toutes ≥ 24 × 24 px (2.5.8 AA) ; 44 × 44 (2.5.5 AAA) non visé.
- Messages : texte explicite + icône, jamais une pastille de couleur seule ;
  les 5 couleurs sont ≥ 7:1 sur le panneau.
- APCA : contrôle complémentaire non normatif (Lc ≥ 90 texte courant, ≥ 75
  secondaire, ≥ 45 icônes).
- Limites assumées et documentées : fenêtre non activable → pas de focus clavier
  utilisable (2.4.7 / 2.4.11 hors périmètre) ; rendu GDI+ → pas d’arbre UI
  Automation ni de rôle d’accessibilité (4.1.3 / 1.3.1 non satisfaits). Le texte
  et l’icône restent l’alternative visuelle, et le journal existant conserve
  l’historique des actions.
- Écarts mineurs : badge 10,5 px et libellé « Connecté » 11 px sous le plancher
  Fluent de 12 px, justifiés par leur rôle secondaire et leurs ratios ≥ 7:1.

## 7. Ce qui ne change pas

- Paramètres (`SettingsForm.cs`) : intact.
- Comportements : clic bouton = déplier ; clic ligne = basculer ; clic extérieur
  et Échap = replier ; pin = verrouiller le glisser ; position mémorisée.
- Données et ordre des comptes, Riot ID, dernière utilisation, rétention des
  statuts.
- Largeur 380 DIP, 5 lignes visibles, molette, fenêtre non activable.
- Architecture : aucun paquet, aucune ressource, aucun timer, même fichier
  `OverlayForm.cs`.

## 8. Plan de test

| Cas | Attendu |
|---|---|
| 0 compte | H = 217, état vide lisible, footer cliquable |
| 1, 3, 5 comptes | H = 201 / 305 / 409 ; pas de barre de défilement |
| 6, 7, 12 comptes | H = 409 ; barre visible, molette bornée, curseur proportionnel |
| Compte courant absent | Pas de rail ni badge ; bandeau « non détecté » si client absent |
| Noms 1 / 30 caractères, accents, emoji | Ellipse, date intacte, badge non chevauché |
| 5 statuts, court / long | Couleur + icône ; 2 lignes max ; H ajustée |
| Survols | Ligne, footer, pin, fermer ; aucun clignotement |
| Épinglé | Icône pleine, couleur accent, glisser verrouillé |
| Échap / clic extérieur | Repli, état conservé au rouvrir |
| DPI 100 → 250 % | Proportions et alignements corrects |
| Contraste | Ratios du §3.1 (script de calcul dans les références) |

## 9. Fichiers de la maquette

| Fichier | Rôle |
|---|---|
| `maquette.html` | présentation complète (11 sections), à ouvrir dans un navigateur |
| `maquette.css` | tokens et styles 1:1 |
| `maquette.js` | rendu des planches, palette calculée, données de démo |
| `capture.html` | page technique de capture (`?vue=…`) |
| `captures/*.png` | 13 captures @2x rognées |
| `captures/implementation/*.png` | 22 rendus du GDI+ réel (hors écran) : états, survols, appuis, statuts, noms longs, échelles 1,25/1,5 |
| `rendre-captures.py` | régénère les captures (Chrome headless + Pillow) |
| `standards-references.md` | sources, chiffres et critères détaillés |
| `spec-overlay.fr.md` | le présent document |

Régénération : `python rendre-captures.py` depuis `docs/overlay-ui/`
(Chrome installé au chemin par défaut, Pillow requis).

## 10. Références

- WCAG 2.2 — <https://www.w3.org/TR/WCAG22/> ; notes : <https://www.w3.org/WAI/WCAG22/Understanding/>
- APCA — <https://git.apcacontrast.com/documentation/APCAeasyIntro> (non normatif)
- Fluent 2 — <https://fluent2.microsoft.design/> ; typographie Windows : <https://learn.microsoft.com/en-us/windows/apps/design/style/typography>
- Material 3 — <https://m3.material.io/foundations/interaction/states/state-layers>
- Xbox Accessibility Guidelines 101/102 — <https://learn.microsoft.com/en-us/gaming/accessibility/guidelines>
- Game Accessibility Guidelines — <https://gameaccessibilityguidelines.com/full-list/>
- Daltonisme — <https://www.nei.nih.gov/eye-health-information/eye-conditions-and-diseases/color-blindness>
- Détail et ratios recalculés : `standards-references.md`.
