# Références UI & accessibilité — overlay RiotSwitch

> Brief de standards pour la refonte de l'overlay (panneau sombre 380 DIP, interaction souris, fenêtre non activable, bouton 40×40, liste de comptes, messages de statut). Relevé du 10 novembre 2026. Sources primaires avec URL ; chiffres tels que publiés ; toute valeur non confirmée est marquée « à vérifier ».

## 1. WCAG 2.2 — contraste, taille de cible, focus

Spécification : <https://www.w3.org/TR/WCAG22/> · Notes « Understanding » : <https://www.w3.org/WAI/WCAG22/Understanding/>

Ces critères sont rédigés pour le Web ; ils sont la référence usuelle pour les interfaces desktop (Microsoft les reprend pour Windows : texte ≥ 4,5:1). Applicabilité à un overlay non activable : voir §7.

| Critère | Niveau | Exigence chiffrée |
|---|---|---|
| 1.4.3 Contraste (minimum) — <https://www.w3.org/WAI/WCAG22/Understanding/contrast-minimum.html> | AA | Texte 4,5:1 ; texte « large » 3:1. Large = ≥ 18 pt (24 px) ou ≥ 14 pt gras (≈ 18,5 px) ; note W3C : 1 pt = 1,333 px. |
| 1.4.6 Contraste (renforcé) — <https://www.w3.org/WAI/WCAG22/Understanding/contrast-enhanced.html> | AAA | 7:1 texte normal ; 4,5:1 texte large. |
| 1.4.11 Contraste non textuel — <https://www.w3.org/WAI/WCAG22/Understanding/non-text-contrast.html> | AA | 3:1 pour composants d'interface, états et objets graphiques contre les couleurs adjacentes ; composants inactifs exemptés. |
| 2.5.8 Taille de cible (minimum) — <https://www.w3.org/WAI/WCAG22/Understanding/target-size-minimum.html> | AA | Cible ≥ 24 × 24 px CSS ; 5 exceptions (dont « Spacing » : un cercle de 24 px centré sur la cible ne doit intersecter aucune autre cible). |
| 2.5.5 Taille de cible (renforcée) — <https://www.w3.org/WAI/WCAG22/Understanding/target-size-enhanced.html> | AAA | 44 × 44 px CSS (cité par la note de 2.5.8 comme « 44 by 44 CSS pixel measure »). |
| 2.4.7 Focus visible — <https://www.w3.org/WAI/WCAG22/Understanding/focus-visible.html> | AA | Indicateur de focus visible dans au moins un mode ; contraste ≥ 3:1 via 1.4.11. |
| 2.4.11 Focus non masqué (minimum) — <https://www.w3.org/WAI/WCAG22/Understanding/focus-not-obscured-minimum.html> | AA | L'élément focalisé n'est pas entièrement masqué par du contenu auteur. |
| 1.4.1 Utilisation de la couleur — <https://www.w3.org/WAI/WCAG22/Understanding/use-of-color.html> | A | « Color is not used as the only visual means of conveying information, indicating an action, prompting a response, or distinguishing a visual element. » |
| 3.3.1 Erreurs — <https://www.w3.org/WAI/WCAG22/Understanding/error-identification.html> / 3.3.3 — <https://www.w3.org/WAI/WCAG22/Understanding/error-suggestion.html> | AA | Erreur détectée = identifiée et décrite en texte ; suggestion de correction fournie si connue. |
| 4.1.3 Messages de statut — <https://www.w3.org/WAI/WCAG22/Understanding/status-messages.html> | AA | Vise le contenu « implemented using markup languages » : un overlay GDI+ n'expose pas, par défaut, d'arbre d'accessibilité ⇒ écart documenté (§7). |

## 2. APCA — candidat de contraste pour WCAG 3 (non normatif)

Source : <https://git.apcacontrast.com/documentation/APCAeasyIntro> · Brouillon WCAG 3 : <https://www.w3.org/TR/wcag-3.0/>. Citation de la source : « APCA as the candidate for WCAG 3 is still in development. » Ce n'est donc pas encore une exigence WCAG ; l'utiliser comme garde-fou de lisibilité en complément de WCAG 2.2.

| Niveau Lc | Usage recommandé par APCA |
|---|---|
| 90 | Préféré pour le texte courant en colonnes (police ≥ 14 px / graisse 400). |
| 75 | Minimum pour colonnes de texte (≥ 18 px / 400). |
| 60 | Minimum pour texte de contenu non courant (≥ 24 px / 400 ou 16 px / 700). |
| 45 | Grand texte lourd (≥ 36 px / 400 ou 24 px / 700) et pictogrammes fins. |
| 30 | Minimum absolu pour tout texte, y compris placeholder et désactivé ; grands éléments non textuels sémantiques. |
| 15 | Minimum absolu pour non-texte discernable ≥ 5 px ; en dessous, invisible pour beaucoup. |

Échelle Lc de 0 à ±106 ; en mode sombre, APCA cite un maximum préliminaire de Lc −90 pour les grandes polices (à vérifier, mention « préliminaire » dans la source).

**Pourquoi le rouge sombre sur fond sombre est pénalisé** : WCAG 2.x ne compare que les luminances (4,5:1 ou 3:1) ; APCA modélise la perception (échelle 0 à ±106) avec des exposants différents pour le clair-sur-sombre et le sombre-sur-clair, et un écrasement (« clamp ») des luminances très basses. Sur un panneau `#292929`, un rouge sombre Fluent `#b10e1c` ne fait que **2,04:1** (calcul WCAG) ; un rouge clair `#eeacb2` atteint **7,74:1**. Le Lc exact de chaque paire se vérifie avec le calculateur officiel APCA — non reproduit ici (pas de valeur inventée).

## 3. Fluent 2 / Windows 11 — langage visuel de la maquette

### 3.1 Typographie (Segoe UI Variable)

Sources : <https://learn.microsoft.com/en-us/windows/apps/design/style/typography> · <https://fluent2.microsoft.design/typography>

- Police **Segoe UI Variable** : axe `wght` 100–700 (Light 300, Semilight 350, Regular 400, Semibold 600, Bold 700), axe `opsz` automatique 8–36 pt.
- Minimums officiels : « 14px Semibold, 12px Regular » — en dessous, illisible dans certaines langues.
- Casse de phrase (sentence case), 50–60 caractères par ligne (jamais < 20 ni > 60).
- Rampe Windows 11 (taille/interligne, epx) : Small **12/16** regular · Text **14/20** regular · Text semibold **14/20** · Text **18/24** · Text semibold **18/24** · Display semibold **20/28**, **28/36**, **40/52**, **68/92**.
- Rampe Fluent 2 web utile ici : Caption 1 **12/16** · Body 1 **14/20** · Body 1 Strong **14/20** semibold · Subtitle 2 **16/22** semibold · Subtitle 1 **20/26** semibold · Title 3 **24/32** · Large Title **40/52** · Display **68/92**.

### 3.2 Espacements, rayons, géométrie

Sources : <https://fluent2.microsoft.design/layout> · <https://learn.microsoft.com/en-us/windows/apps/design/signature-experiences/geometry> · tokens Fluent UI : <https://github.com/microsoft/fluentui/tree/master/packages/tokens/src/global>

- Base **4 px** ; rampe Fluent 2 : 0, 2, 4, 6, 8, 10, 12, 16, 20, 24, 28, 32, 36, 40, 48, 52, 56 px.
- Tokens d'espacement : none 0 · xxs 2 · xs 4 · sNudge 6 · s 8 · mNudge 10 · m 12 · l 16 · xl 20 · xxl 24 · xxxl 32 px.
- Rayons : none 0 · small **2** · medium **4** · large **6** · xlarge **8** · 2xlarge **12** · 3xlarge **16** · 4xlarge **24** · 5xlarge **32** · 6xlarge **40** · circular 10000 px.
- Géométrie Windows 11 : conteneurs de premier niveau, flyouts, dialogs et **overlays = 8 px** (`OverlayCornerRadius=8px`) ; contrôles in-page (Button, CheckBox, ComboBox, TextBox, ListView) et ToolTip = **4 px** (`ControlCornerRadius=4px`) ; arêtes droites = 0 px ; fenêtres snapped/maximized non arrondies.
- Cibles tactiles citées par Fluent 2 : iOS et Web **44×44**, Android **48×48**.

### 3.3 Neutres du thème sombre Fluent 2 et contrastes calculés

Source des tokens : <https://github.com/microsoft/fluentui/blob/master/packages/tokens/src/alias/darkColor.ts> (valeurs hexadécimales officielles). Ratios WCAG 2.x recalculés par nos soins (formule de luminance relative sRGB) sur le fond de panneau `#292929`.

| Token | Hex | Rôle | Contraste sur #292929 |
|---|---|---|---|
| colorNeutralBackground1 | `#292929` | fond de panneau | — |
| colorNeutralBackground1Hover | `#3d3d3d` | survol de ligne / bouton | — |
| colorNeutralBackground1Pressed | `#1f1f1f` | appui | — |
| colorNeutralBackground1Selected | `#383838` | sélection | — |
| colorNeutralBackground2 | `#1f1f1f` | surface de second niveau | — |
| colorNeutralBackground3 | `#141414` | surface la plus basse | — |
| colorNeutralForeground1 | `#ffffff` | texte principal | **14,55:1** |
| colorNeutralForeground2 | `#d6d6d6` | texte secondaire | **10,01:1** |
| colorNeutralForeground3 | `#adadad` | texte tertiaire / icônes | **6,48:1** |
| colorNeutralForeground4 | `#999999` | texte discret | **5,11:1** |
| colorNeutralForegroundDisabled | `#5c5c5c` | texte désactivé | **2,18:1** (exempté car inactif, mais < 3:1 de XAG 102) |
| colorNeutralStroke1 | `#666666` | bordure standard | **2,53:1** ⇒ insuffisant pour 1.4.11 |
| colorNeutralStroke2 | `#525252` | bordure discrète | **1,86:1** |
| colorNeutralStroke3 | `#3d3d3d` | séparateur | **1,34:1** |
| colorNeutralStrokeAccessible | `#adadad` | bordure accessible | **6,48:1** (sur #1f1f1f : 7,34:1) |
| colorNeutralShadowAmbient / Key | `rgba(0,0,0,0.24)` / `rgba(0,0,0,0.28)` | ombre d'overlay | — |

Lecture : `colorNeutralForeground3` (#adadad) est le plus sombre des textes Fluent qui reste ≥ 4,5:1 ; les bordures `Stroke1/2/3` sont toutes < 3:1 et ne doivent pas être la seule limite visible d'un contrôle interactif (utiliser `StrokeAccessible` ou un contenu contrasté). Ces hex ne figurent pas dans les pages de documentation Fluent 2 consultées ; les tokens open source font foi.

### 3.4 Cibles et texte (Windows)

- Cible tactile : « **7.5mm square range (40x40 pixels on a 135 PPI display at a 1.0x scaling plateau)** » — <https://learn.microsoft.com/en-us/windows/apps/design/input/guidelines-for-targeting>.
- Texte : ≥ 4,5:1, exceptions logos, texte incident et texte inactif — <https://learn.microsoft.com/en-us/windows/apps/design/accessibility/accessible-text-requirements>.
- Daltonisme : « About **8 percent of men and 0.5 percent of women** are red-green colorblind, so avoid using these combinations as the sole differentiator » — <https://learn.microsoft.com/en-us/windows/apps/design/style/color>.

### 3.5 Lisibilité sur fond sombre (synthèse)

- **Interligne** : les rampes Fluent 2 vont de ≈ 1,25× (32/40) à ≈ 1,43× (14/20) ; XAG 101 exige ≥ **1,5** pour les blocs de texte — retenir 1,5 dès qu'un paragraphe dépasse deux lignes.
- **Blanc pur** : `#ffffff` sur `#292929` = **14,55:1** (token `colorNeutralForeground1`) ; pour du texte long, préférer `#d6d6d6` (**10,01:1**) afin de limiter l'éblouissement (halation) — recommandation de conception, WCAG n'exige que ≥ 4,5:1.
- **Taille minimale** : 12 px regular / 14 px semibold (Fluent), jamais < 12 px ; 18 px @1080p si la cible XAG PC est retenue (voir §7).
- **Largeur de ligne** : 50–60 caractères (Fluent) et ≤ 80 caractères (XAG 101).

## 4. Material 3 — référence transversale (state layers, typographie, cible)

Sources : <https://m3.material.io/foundations/interaction/states/state-layers> · <https://developer.android.com/develop/ui/compose/designsystems/material3> (§ Typography scale) · <https://developer.android.com/guide/topics/ui/accessibility/apps>

- State layers (voile de couleur du contenu, opacité fixe) : survol **0,08** · focus **0,10** · appui **0,10** · drag **0,16** · désactivé **0,38**. Tokens : `0.08 hover`, `0.1 focus`, `0.1 pressed`, `0.16 dragged`, `0.38 disabled`.
- « The size of state layers is **40dp** while the interactive target size is **48dp** » — le visuel peut être 40 dp, la cible reste 48 dp.
- Échelle typographique M3 (taille/interligne) : Display Large 57/64 · Display Medium 45/52 · Display Small 36/44 · Headline Large 32/40 · Headline Medium 28/36 · Headline Small 24/32 · Title Large 22/28 · Title Medium 16/24 · Title Small 14/20 · **Body Large 16/24 · Body Medium 14/20 · Body Small 12/16 · Label Large 14/20 · Label Medium 12/16 · Label Small 11/16**.
- Cible tactile Android : ≥ **48 dp × 48 dp** (« at least 48dpx48dp. Larger is even better. ») ; pour une entrée précise (souris/trackpad), une cible plus petite est admise.

## 5. Références jeu / accessibilité les plus pertinentes

### 5.1 Xbox Accessibility Guidelines (XAG) v3.2 — <https://learn.microsoft.com/en-us/gaming/accessibility/guidelines>

**XAG 101 Text display** — <https://learn.microsoft.com/en-us/gaming/accessibility/xbox-accessibility-guidelines/101>
- Tailles minimales par défaut au lancement : Console **26 px @1080p**, **52 px @4K** ; PC/VR **18 px @1080p**, **36 px @4K** ; Mobile/Xbox Game Streaming **18 px @100 DPI**, **36 px @200 DPI**, **72 px @400 DPI** (mise à l'échelle linéaire selon le DPI).
- Icônes et glyphes ≥ la même taille minimale ; mise à l'échelle du texte jusqu'à **200 %** (ex. console 26 px → 52 px @1080p).
- Au moins une police **sans serif** ; largeur de ligne ≤ **80** caractères (40 en CJK) ; interligne ≥ **1,5** ; espacement des paragraphes ≥ **2 ×** l'interligne ; interlettrage ≥ **0,12 ×** la taille de police ; intermot ≥ **0,16 ×** la taille de police ; casse de phrase.
- Mesure en px = hauteur du corps = descender + x-height + ascender ; un pixel d'outline ne compte que si son contraste avec le fond est > **2:1**.

**XAG 102 Contrast** — <https://learn.microsoft.com/en-us/gaming/accessibility/xbox-accessibility-guidelines/102>
- Texte standard et éléments visuels importants : **4,5:1** ; texte et éléments « large scale » : **3:1** (large = console **52 px @1080p** / **104 px @4K** ; PC/VR **36 px @1080p** / **72 px @4K**).
- Texte sur éléments inactifs : **3:1** ; placeholder et texte saisi : **4,5:1** (**3:1** en large).
- Mode contraste élevé fourni : **7:1** pour tous les éléments d'interface ; logos exemptés.

### 5.2 Game Accessibility Guidelines — <https://gameaccessibilityguidelines.com/full-list/>

Qualitatives (aucun chiffre publié) : « Provide high contrast between text/UI and background », « Use simple clear text formatting », « Use an easily readable default font size », « Ensure no essential information is conveyed by a fixed colour alone », « Ensure interactive elements / virtual controls are large and well spaced », et en avancé « Allow the font size to be adjusted ».

### 5.3 Daltonisme et encodage redondant de l'état

- Prévalence rouge-vert : ~**8 %** des hommes et **0,5 %** des femmes (Microsoft, §3.4) ; la deuteranomalie est la forme rouge-vert la plus courante (NEI : <https://www.nei.nih.gov/eye-health-information/eye-conditions-and-diseases/color-blindness>).
- La couleur seule ne doit jamais porter l'information (WCAG 1.4.1, §1) : associer **couleur + icône + libellé** (« Échec : compte introuvable »), jamais une pastille rouge/verte seule.
- Éviter rouge/vert comme seul différenciateur (Microsoft) : formes et icônes distinctes, texte explicite.

## 6. Contrôles chiffrés à repasser sur la maquette

| Élément de l'overlay | Exigence minimale | Valeur cible proposée | Source |
|---|---|---|---|
| Texte principal (liste de comptes) | 4,5:1 | 14 px/20 `#ffffff` sur `#292929` = **14,55:1** | WCAG 1.4.3 + Fluent |
| Texte secondaire (sous-titre de compte) | 4,5:1 | 12–14 px `#d6d6d6` = **10,01:1** | WCAG 1.4.3 + Fluent |
| Texte tertiaire (statut, hint) | 4,5:1 | `#adadad` = **6,48:1** ; ne pas descendre à `#999999` sous 12 px | WCAG 1.4.3 + Fluent |
| Bordure du bouton 40×40 | 3:1 (1.4.11) | `#adadad` = 6,48:1, **pas** `#666666` (2,53:1) | WCAG 1.4.11 |
| Zone cliquable du bouton | 24×24 px (AA) | **40×40 px** = 7,5 mm à 135 PPI ; 44×44 seulement si AAA | WCAG 2.5.8/2.5.5 + Windows |
| Hauteur de ligne de compte | état layer 40 dp, cible 48 dp | ≥ 40 px visuel, **48 px** de cible haute ; espacement ≥ 8 px entre lignes | Material 3 |
| Survol / appui | changement non seulement de couleur | +8 % survol, +10 % appui (voile couleur contenu) → `#292929` + blanc 8 % ≈ `#3a3a3a` (proche de `#3d3d3d` Fluent) | Material 3 + Fluent |
| Message de statut (succès/échec) | 4,5:1 + canal non coloré | couleur + icône + texte ≥ 4,5:1 ; **7:1** en contraste élevé | WCAG 1.4.1 + XAG 102 |
| Espacements internes du panneau | multiples de 4 px | 8/12/16 px (padding), 4 px entre icône et libellé | Fluent 2 |
| Rayons | — | panneau **8 px**, boutons/champs **4 px**, pastilles circulaires | Géométrie Windows 11 |

**Couleurs d'état Fluent 2 thème sombre** (danger = cranberry, warning = orange, success = green ; <https://github.com/microsoft/fluentui/blob/master/packages/tokens/src/alias/darkColorPalette.ts>) et ratios calculés sur `#292929` : danger `#dc626d` = **4,16:1** (insuffisant pour du texte 14 px, OK en large 3:1) → utiliser `#eeacb2` (**7,74:1**) ; warning `#faa06b` = **7,14:1** ; success `#54b054` = **5,34:1** ; aplat danger `#c50f1f` + texte blanc = **6,07:1** ; aplat success `#107c10` + blanc = **5,37:1** ; aplat warning `#f7630c` + blanc = **3,11:1** (large seulement).

## 7. Limites et écarts assumés (fenêtre non activable, souris uniquement)

- Pas de focus clavier réellement utilisable ⇒ 2.4.7 / 2.4.11 non applicables en pratique ; conserver en revanche un retour survol/appui visible et ≥ 3:1 (1.4.11).
- Overlay dessiné en GDI+ : pas d'arbre UI Automation ni de rôle d'accessibilité par défaut ⇒ 4.1.3 (messages de statut) et 1.3.1 ne peuvent pas être satisfaits techniquement ; écart à documenter, avec alternative visuelle (texte + icône) et journal.
- XAG 101 recommande 18 px minimum sur PC/VR ; Fluent 2 recommande Body 14/20. Tension à arbitrer pour une maquette : 14/20 (défaut Windows), **16 px** pour les textes critiques, 18 px si la cible XAG PC est prioritaire (choix de conception, pas un seuil normatif).

## À retenir pour la maquette

1. **Texte principal** : 14 px/20 `#ffffff` sur `#292929` = **14,55:1** (WCAG AA 4,5:1 ; AAA 7:1 atteint aussi).
2. **Texte secondaire** : 12–14 px `#d6d6d6` = **10,01:1** ; **jamais en dessous de `#adadad` (6,48:1)** pour du texte utile ; paragraphe long : `#d6d6d6` plutôt que blanc pur.
3. **Bordures** : `#666666` ne fait que **2,53:1** → seuil non textuel de **3:1 (1.4.11)** raté ; utiliser `#adadad` (**6,48:1**).
4. **Bouton 40×40** : dépasse le minimum AA **24×24 px (2.5.8)** et correspond à **7,5 mm à 135 PPI** (Microsoft) ; **44×44** seulement pour viser AAA (2.5.5).
5. **Typographie** : 3 styles max — Caption 1 **12/16**, Body 1 **14/20**, Subtitle 2 **16/22** semibold ; taille plancher **12 px regular / 14 px semibold**.
6. **Espacements** : grille de **4 px** (8/12/16 px) ; interlettrage ≥ **0,12 ×** et interligne ≥ **1,5** si on suit XAG 101.
7. **Rayons** : panneau **8 px** (`OverlayCornerRadius`), boutons/champs **4 px** (`ControlCornerRadius`), pastilles `circular`.
8. **États** : survol **+8 %**, appui **+10 %**, désactivé **0,38** d'opacité (Material 3) ; désactivé Fluent `#5c5c5c` = **2,18:1**, à réserver au non-essentiel ; danger Fluent `#dc626d` = **4,16:1** insuffisant → `#eeacb2` = **7,74:1**.
9. **Cible des lignes de compte** : **40 px** de visuel minimum (state layer 40 dp), **48 px** de cible (Android), **≥ 8 px** d'espacement entre cibles.
10. **Messages de statut** : couleur + icône + texte (1.4.1), jamais rouge/vert seuls (**8 %** des hommes, **0,5 %** des femmes), **≥ 4,5:1** et **7:1** en mode contraste élevé (XAG 102) ; APCA viser **Lc 75–90** pour le corps de texte (non normatif).
