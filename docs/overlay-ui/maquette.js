/* ==========================================================================
   RiotSwitch — maquette overlay : rendu des planches + tokens
   Aucune dépendance. Fonctionne en file:// (ouverture directe du HTML).
   ========================================================================== */

(function () {
  "use strict";

  /* ------------------------------------------------------------------------
     Icônes — tracés 24 × 24, rendues en SVG (en production : GDI+).
     ------------------------------------------------------------------------ */
  const ICONS = {
    switch:
      '<path d="M4 8h14"/><path d="M15 5l3 3-3 3"/><path d="M20 16H6"/><path d="M9 13l-3 3 3 3"/>',
    pin:
      '<path d="M12 17v5"/><path d="M9 10.76a2 2 0 0 1-1.11 1.79l-1.78.9A2 2 0 0 0 5 15.24V16a1 1 0 0 0 1 1h12a1 1 0 0 0 1-1v-.76a2 2 0 0 0-1.11-1.79l-1.78-.9A2 2 0 0 1 15 10.76V7a1 1 0 0 1 1-1 2 2 0 0 0 0-4H8a2 2 0 0 0 0 4 1 1 0 0 1 1 1z"/>',
    pinFilled:
      '<path fill="currentColor" stroke="currentColor" stroke-width="1" d="M9 10.76a2 2 0 0 1-1.11 1.79l-1.78.9A2 2 0 0 0 5 15.24V16a1 1 0 0 0 1 1h12a1 1 0 0 0 1-1v-.76a2 2 0 0 0-1.11-1.79l-1.78-.9A2 2 0 0 1 15 10.76V7a1 1 0 0 1 1-1 2 2 0 0 0 0-4H8a2 2 0 0 0 0 4 1 1 0 0 1 1 1z"/><path d="M12 17v5"/>',
    close: '<path d="M6 6l12 12"/><path d="M18 6 6 18"/>',
    plus: '<path d="M12 5v14"/><path d="M5 12h14"/>',
    sliders:
      '<path d="M4 7h6"/><path d="M14 7h6"/><circle cx="12" cy="7" r="2"/><path d="M4 17h10"/><path d="M18 17h2"/><circle cx="16" cy="17" r="2"/>',
    refresh: '<path d="M20 12a8 8 0 1 1-2.34-5.66"/><path d="M20 4v5h-5"/>',
    check: '<path d="M20 6 9 17l-5-5"/>',
    alert:
      '<path d="M10.3 4.1 2.6 17.9A2 2 0 0 0 4.3 21h15.4a2 2 0 0 0 1.7-3.1L13.7 4.1a2 2 0 0 0-3.4 0z"/><path d="M12 9v5"/><path d="M12 17.5h.01"/>',
    xcircle:
      '<circle cx="12" cy="12" r="9"/><path d="M9 9l6 6"/><path d="M15 9l-6 6"/>',
    info: '<circle cx="12" cy="12" r="9"/><path d="M12 11v5"/><path d="M12 8h.01"/>'
  };

  function icon(name, size, strokeWidth) {
    const sw = strokeWidth || 1.7;
    return (
      '<svg width="' + size + '" height="' + size + '" viewBox="0 0 24 24" fill="none" ' +
      'stroke="currentColor" stroke-width="' + sw + '" stroke-linecap="round" ' +
      'stroke-linejoin="round" aria-hidden="true">' + ICONS[name] + "</svg>"
    );
  }

  function esc(value) {
    return String(value)
      .replace(/&/g, "&amp;")
      .replace(/</g, "&lt;")
      .replace(/>/g, "&gt;")
      .replace(/"/g, "&quot;");
  }

  /* ------------------------------------------------------------------------
     Données de démonstration
     ------------------------------------------------------------------------ */
  const ACCOUNTS = [
    { name: "QuentinG", id: "QuentinG#EUW", last: "09/11 21:42" },
    { name: "Smurf", id: "SmurfLoL#EUW", last: "09/11 18:07" },
    { name: "Compte test", id: "TestRiot#EUW", last: "06/11 20:31" },
    { name: "Alt NA", id: "AltNA#NA1", last: "05/11 14:12" },
    { name: "Pote", id: "Pote#EUW", last: "02/11 22:40" },
    { name: "LoR", id: "LoR#EUW", last: "29/10 10:05" },
    { name: "Ranked", id: "Ranked#EUW", last: "24/10 16:55" }
  ];

  const STATUS = {
    success: { icon: "check", text: "QuentinG ajouté." },
    info: {
      icon: "info",
      text: "Position verrouillée : l’overlay suit la fenêtre mais ne peut plus être déplacé."
    },
    warning: {
      icon: "alert",
      text: "League of Legends est ouvert. Ferme le jeu puis réessaie — le changement de compte nécessite un client Riot fermé."
    },
    error: {
      icon: "xcircle",
      text: "Changement impossible : session expirée. Reconnecte-toi avec ce compte."
    },
    progress: { icon: "refresh", text: "Changement vers Smurf…" }
  };

  /* ------------------------------------------------------------------------
     Panneau « après » (proposition)
     ------------------------------------------------------------------------ */
  function panelAfter(cfg) {
    const o = Object.assign(
      {
        accounts: ACCOUNTS.slice(0, 5),
        current: ACCOUNTS[0],
        hover: null,
        pinned: false,
        status: null,
        scrolled: false
      },
      cfg || {}
    );

    const start = o.scrolled ? 1 : 0;
    const visible = o.accounts.slice(start, start + 5);
    const current = o.current || null;

    const connected = current
      ? '<div class="connected">' +
        '<span class="ico">' + icon("check", 13, 2.1) + "</span>" +
        '<span class="label">Connecté</span>' +
        '<span class="dot">·</span>' +
        '<span class="who">' + esc(current.id) + "</span>" +
        "</div>"
      : '<div class="connected is-off">' +
        '<span class="ico">' + icon("info", 13, 1.8) + "</span>" +
        '<span class="label">Client Riot non détecté</span>' +
        "</div>";

    let listBody = "";
    if (o.accounts.length === 0) {
      listBody =
        '<div class="empty">' +
        '<div class="empty-title">Aucun compte enregistré</div>' +
        '<div class="empty-sub">Connecte-toi dans le client Riot, puis clique sur « Ajouter ».</div>' +
        "</div>";
    } else {
      listBody = visible
        .map(function (account, index) {
          const isCurrent = current !== null && account === current;
          const isHover = o.hover === start + index;
          const rowClasses = "row" + (isCurrent ? " current" : "") + (isHover ? " is-hover" : "");
          return (
            '<div class="' + rowClasses + '">' +
            '<div class="l1"><span class="name">' + esc(account.name) + "</span>" +
            (isCurrent ? '<span class="badge">Actuel</span>' : "") +
            "</div>" +
            '<div class="l2"><span class="riot-id">' + esc(account.id) + "</span>" +
            '<span class="date">' + esc(account.last) + "</span></div>" +
            "</div>"
          );
        })
        .join("");
    }

    let scrollbar = "";
    if (o.accounts.length > 5) {
      const thumb = (100 * 5) / o.accounts.length;
      const top = o.scrolled
        ? (100 * start) / (o.accounts.length - 5) * (1 - 5 / o.accounts.length)
        : 0;
      scrollbar =
        '<div class="scrollbar" aria-hidden="true">' +
        '<span class="thumb" style="top:' + top.toFixed(2) + "%;height:" + thumb.toFixed(2) + '%"></span>' +
        "</div>";
    }

    const footer =
      '<div class="footer">' +
      '<button type="button" class="btn primary">' + icon("plus", 14, 1.9) + "<span>Ajouter</span></button>" +
      '<button type="button" class="btn">' + icon("sliders", 14, 1.8) + "<span>Paramètres</span></button>" +
      '<button type="button" class="btn">' + icon("refresh", 14, 1.8) + "<span>Actualiser</span></button>" +
      "</div>";

    let status = "";
    if (o.status && STATUS[o.status]) {
      const st = STATUS[o.status];
      status =
        '<div class="status ' + o.status + '">' +
        icon(st.icon, 14, 1.8) +
        "<span>" + esc(st.text) + "</span>" +
        "</div>";
    }

    return (
      '<div class="panel after">' +
      '<div class="header">' +
      '<span class="title">Comptes Riot</span>' +
      '<button type="button" class="icon-btn ' + (o.pinned ? "is-active" : "") + '" aria-label="Épingler">' +
      icon(o.pinned ? "pinFilled" : "pin", 16, 1.7) +
      "</button>" +
      '<button type="button" class="icon-btn" aria-label="Fermer">' +
      icon("close", 16, 1.9) +
      "</button>" +
      "</div>" +
      connected +
      '<div class="divider"></div>' +
      '<div class="list">' + listBody + scrollbar + "</div>" +
      footer +
      status +
      "</div>"
    );
  }

  /* ------------------------------------------------------------------------
     Panneau « avant » — reconstitution fidèle de la v1.1.15
     ------------------------------------------------------------------------ */
  function panelBefore(cfg) {
    const o = Object.assign(
      { accounts: ACCOUNTS.slice(0, 5), current: ACCOUNTS[0] },
      cfg || {}
    );

    const shown = o.accounts.slice(0, 5);
    const listHeight = shown.length === 0 ? 68 : Math.max(shown.length, 1) * 52;
    const currentHeight = o.current ? 64 : 0;
    const listTop = 52 + currentHeight;
    const footerY = listTop + listHeight;
    const totalHeight = footerY + 32 + 12;

    let currentBlock = "";
    if (o.current) {
      currentBlock =
        '<div class="b-label">ACTUEL</div>' +
        '<div class="b-name">' + esc(o.current.name) + "</div>" +
        '<div class="b-id">' + esc(o.current.id) + "</div>";
    }

    let rows = "";
    shown.forEach(function (account, index) {
      const isCurrent = o.current !== null && account === o.current;
      const initial = account.name.trim().charAt(0).toUpperCase() || "?";
      rows +=
        '<div class="b-row' + (isCurrent ? " current" : "") + '" style="top:' + (listTop + index * 52) + 'px">' +
        '<span class="b-avatar">' + esc(initial) + "</span>" +
        '<span class="b-rname">' + esc(account.name) + "</span>" +
        '<span class="b-rid">' + esc(account.id) + "</span>" +
        '<span class="b-date">' + esc(account.last) + "</span>" +
        "</div>";
    });

    const empty =
      '<div class="b-empty" style="top:' + (listTop + 14) + 'px">' +
      "Aucun compte enregistré.<br>Connecte-toi dans le client Riot, puis clique sur « Ajouter »." +
      "</div>";

    return (
      '<div class="panel before" style="height:' + totalHeight + 'px">' +
      '<div class="b-title">Comptes Riot</div>' +
      '<div class="b-pin"><span class="head"></span><span class="stem"></span><span class="base"></span></div>' +
      '<div class="b-close">×</div>' +
      currentBlock +
      (shown.length ? rows : empty) +
      '<div class="b-footer" style="top:' + footerY + 'px">' +
      '<span class="b-btn"><span class="b-ico">+</span>Ajouter</span>' +
      '<span class="b-btn"><span class="b-ico">⚙</span>Paramètres</span>' +
      '<span class="b-btn"><span class="b-ico">↻</span>Actualiser</span>' +
      "</div>" +
      "</div>"
    );
  }

  /* ------------------------------------------------------------------------
     Planches (boards)
     ------------------------------------------------------------------------ */
  function figure(inner, caption, boardClass) {
    return (
      '<figure class="shot"><div class="board' + (boardClass ? " " + boardClass : "") + '">' +
      inner +
      '<figcaption class="cap">' + caption + "</figcaption>" +
      "</div></figure>"
    );
  }

  function buttonTile(label, cls) {
    return (
      '<div class="btn-state">' +
      '<div class="state-tile">' +
      '<span class="switch-btn ' + cls + '" role="img" aria-label="Bouton RiotSwitch">' +
      icon("switch", 26, 2.2) +
      "</span></div>" +
      '<span class="state-label">' + label + "</span>" +
      "</div>"
    );
  }

  const BOARDS = {
    boutons: function () {
      return figure(
        '<div class="btn-states">' +
          buttonTile("Repos", "") +
          buttonTile("Survol", "hover") +
          buttonTile("Appui", "pressed") +
          "</div>",
        "<b>Bouton replié</b> — 40 × 40 DIP, rayon 10. Le dégradé rouge et les flèches ⇄ restent l’identité du switcher ; l’icône est redessinée plus fine (2,2 px). Cible de clic 40 px, au-dessus du minimum WCAG 2.5.8 (24 px)."
      );
    },

    avant: function () {
      return figure(
        panelBefore({ accounts: ACCOUNTS.slice(0, 5) }),
        "<b>Avant — v1.1.15</b> — 5 comptes, 380 × 420 DIP. Avatar à initiale, bloc « ACTUEL » de 64 px, accent #D13639 à 3,72:1 (échec AA), textes de 8,5 à 12 pt."
      );
    },

    apres: function () {
      return figure(
        panelAfter({ accounts: ACCOUNTS.slice(0, 5) }),
        "<b>Après — proposition</b> — 5 comptes, 380 × 409 DIP. Rail d’accent + badge « Actuel » au lieu de l’avatar, accent texte #FF9C9C (8,9:1, AAA), noms 14 px, ID et dates 12 px tabulaires."
      );
    },

    vide: function () {
      return figure(
        panelAfter({ accounts: [], current: ACCOUNTS[0] }),
        "<b>État vide</b> — coffre vide, client Riot connecté. Le bandeau « Connecté » reste la seule information de contexte ; l’action « Ajouter » est à un clic."
      );
    },

    survol: function () {
      return figure(
        panelAfter({ accounts: ACCOUNTS.slice(0, 3), hover: 1 }),
        "<b>Survol d’une ligne</b> — fond surface-2, rayon 8. Le clic bascule de compte ; les 5 lignes visibles et la molette ne changent pas."
      );
    },

    epingle: function () {
      return figure(
        panelAfter({ accounts: ACCOUNTS.slice(0, 3), pinned: true }),
        "<b>Épinglé</b> — la punaise devient pleine + accent : deux différences (forme et couleur), pas la couleur seule (WCAG 1.4.1). Le glisser de l’overlay reste verrouillé."
      );
    },

    defilement: function () {
      return figure(
        panelAfter({ accounts: ACCOUNTS, scrolled: true }),
        "<b>Défilement</b> — 7 comptes, 5 lignes visibles. Barre de 3 px visible dès le 6<sup>e</sup> compte ; curseur #75758A sur piste #2A2A35 = 3,15:1 (WCAG 1.4.11). Molette inchangée."
      );
    },

    statuts: function () {
      const order = [
        ["info", "Information"],
        ["success", "Succès"],
        ["warning", "Avertissement"],
        ["error", "Erreur"],
        ["progress", "Progression"]
      ];
      const rows = order
        .map(function (entry) {
          const kind = entry[0];
          const label = entry[1];
          const st = STATUS[kind];
          return (
            '<div class="status-row">' +
            '<span class="lab">' + label + "</span>" +
            '<div class="status-chip ' + kind + '">' +
            icon(st.icon, 14, 1.8) +
            "<span>" + esc(st.text) + "</span>" +
            "</div></div>"
          );
        })
        .join("");
      return figure(
        '<div class="status-table">' + rows + "</div>",
        "<b>Messages</b> — 5 types, icône + couleur sémantique (jamais la couleur seule). Texte sur 2 lignes maximum ; le panneau grandit d’au plus 40 DIP."
      );
    },

    "statut-avert": function () {
      return figure(
        panelAfter({ accounts: ACCOUNTS.slice(0, 3), status: "warning" }),
        "<b>Avertissement en situation</b> — message long sur 2 lignes, icône triangle, ambre #F4C36B (10,9:1, AAA). Les messages ne sont plus tronqués à une ligne."
      );
    },

    "statut-succes": function () {
      return figure(
        panelAfter({ accounts: ACCOUNTS.slice(0, 3), status: "success" }),
        "<b>Succès en situation</b> — message court sur une ligne, vert #7BE0A3 (11,1:1, AAA), coche explicite."
      );
    },

    contexte: function () {
      const windowHtml =
        '<div class="riot-window">' +
        '<div class="riot-titlebar"><span class="riot-brand">RIOT CLIENT</span>' +
        '<span class="riot-dots"><i></i><i></i><i></i></span></div>' +
        '<div class="riot-main">' +
        '<div class="riot-rail"><i class="on"></i><i></i><i></i><i></i></div>' +
        '<div class="riot-content">' +
        '<div class="riot-hero"><div class="riot-bars"><i></i><i></i><i></i></div></div>' +
        '<div class="riot-grid"><div class="riot-card"></div><div class="riot-card"></div><div class="riot-card"></div></div>' +
        "</div></div>" +
        '<div class="riot-overlay">' + panelAfter({ accounts: ACCOUNTS.slice(0, 5) }) + "</div>" +
        "</div>";
      return figure(
        windowHtml,
        "<b>En situation</b> — panneau ouvert sur le client Riot (simulation). Positionné sous la barre de titre ; il reste déplaçable et se replie au clic extérieur ou via Échap."
      );
    },

    icones: function () {
      const list = [
        ["switch", "Flèches"],
        ["pin", "Épingler"],
        ["pinFilled", "Épinglé"],
        ["close", "Fermer"],
        ["plus", "Ajouter"],
        ["sliders", "Paramètres"],
        ["refresh", "Actualiser"],
        ["check", "Succès"],
        ["info", "Information"],
        ["alert", "Avertissement"],
        ["xcircle", "Erreur"]
      ];
      const cells = list
        .map(function (entry) {
          return (
            '<div class="icon-cell">' +
            icon(entry[0], 20, 1.7) +
            '<span class="icon-label">' + entry[1] + "</span>" +
            "</div>"
          );
        })
        .join("");
      return figure(
        '<div class="icon-grid">' + cells + "</div>",
        "<b>Icônes</b> — tracés simples (1,6–2,2 px, bouts ronds), dessinés en GDI+ comme aujourd’hui : aucune police d’icônes à installer."
      );
    },

    anatomie: function () {
      const panel = panelAfter({
        accounts: ACCOUNTS.slice(0, 7),
        status: "warning"
      });
      const markers = [
        [1, -20, 21],
        [2, 382, 21],
        [3, -20, 62],
        [4, -20, 112],
        [5, 382, 112],
        [6, 382, 218],
        [7, -20, 372],
        [8, -20, 434]
      ]
        .map(function (marker) {
          return (
            '<span class="marker" style="left:' + marker[1] + "px;top:" + marker[2] + 'px">' +
            marker[0] +
            "</span>"
          );
        })
        .join("");
      const legend = [
        ["1", "Titre", "15 px / 600, 40 px de haut"],
        ["2", "Épingler · Fermer", "cibles 28 × 28, hover surface-2"],
        ["3", "Bandeau connecté", "24 px, une ligne, vert sémantique"],
        ["4", "Rangée active", "rail 3 px + badge « Actuel »"],
        ["5", "Métadonnées", "Riot ID et date 12 px tabulaires"],
        ["6", "Défilement", "3 px, visible dès 6 comptes"],
        ["7", "Footer", "3 boutons 36 px, action primaire en accent"],
        ["8", "Statut", "icône + couleur, 2 lignes max"]
      ]
        .map(function (row) {
          return "<div><b>" + row[0] + " ·</b> " + row[1] + " — " + row[2] + "</div>";
        })
        .join("");
      return figure(
        '<div class="anatomy">' + panel + markers + "</div>" +
          '<div class="anatomy-legend">' + legend + "</div>",
        "<b>Anatomie du panneau</b> — les 8 zones de la proposition. Les numéros sont posés sur la maquette ; la légende donne la règle de chacune."
      );
    }
  };

  /* ------------------------------------------------------------------------
     Design system : palette + ratios WCAG calculés
     ------------------------------------------------------------------------ */
  const SURFACE_1 = "#17171E";

  const SWATCHES = [
    { name: "text-1", hex: "#F2F2F7", usage: "Texte principal, noms, titre", kind: "text", against: SURFACE_1, againstName: "surface-1" },
    { name: "text-2", hex: "#C4C4D0", usage: "Bandeau connecté, libellés", kind: "text", against: SURFACE_1, againstName: "surface-1" },
    { name: "text-3", hex: "#A6A6B8", usage: "Riot ID, dates, aides", kind: "text", against: SURFACE_1, againstName: "surface-1" },
    { name: "red-300", hex: "#FF9C9C", usage: "Accent texte, badge, action primaire", kind: "text", against: SURFACE_1, againstName: "surface-1" },
    { name: "green-300", hex: "#7BE0A3", usage: "Succès, « Connecté »", kind: "text", against: SURFACE_1, againstName: "surface-1" },
    { name: "amber-300", hex: "#F4C36B", usage: "Avertissement", kind: "text", against: SURFACE_1, againstName: "surface-1" },
    { name: "error-300", hex: "#FF8585", usage: "Erreur", kind: "text", against: SURFACE_1, againstName: "surface-1" },
    { name: "surface-1", hex: "#17171E", usage: "Fond du panneau", kind: "surface", against: "#0A0A0C", againstName: "fond Riot" },
    { name: "surface-2", hex: "#1F1F28", usage: "Boutons, survol des lignes", kind: "surface", against: SURFACE_1, againstName: "surface-1" },
    { name: "surface-3", hex: "#262631", usage: "Survol des boutons", kind: "surface", against: SURFACE_1, againstName: "surface-1" },
    { name: "surface-4", hex: "#2E2E3A", usage: "Appui des boutons", kind: "surface", against: SURFACE_1, againstName: "surface-1" },
    { name: "red-row", hex: "#2A181D", usage: "Fond de la ligne active", kind: "surface", against: SURFACE_1, againstName: "surface-1" },
    { name: "red-badge", hex: "#3A2027", usage: "Fond du badge « Actuel »", kind: "surface", against: SURFACE_1, againstName: "surface-1" },
    { name: "line-1", hex: "#2A2A35", usage: "Séparateur, bord de champ", kind: "deco", against: SURFACE_1, againstName: "surface-1" },
    { name: "line-2", hex: "#3A3A48", usage: "Bord au survol", kind: "deco", against: SURFACE_1, againstName: "surface-1" },
    { name: "red-badge-line", hex: "#5A2A32", usage: "Bord du badge", kind: "deco", against: "#3A2027", againstName: "badge" },
    { name: "red-500", hex: "#E23B41", usage: "Rail actif, dégradé du bouton", kind: "ui", against: SURFACE_1, againstName: "surface-1" },
    { name: "red-400", hex: "#F05258", usage: "Survol du bouton", kind: "ui", against: SURFACE_1, againstName: "surface-1" },
    { name: "scroll-thumb", hex: "#75758A", usage: "Curseur de défilement", kind: "ui", against: "#2A2A35", againstName: "piste" },
    { name: "scroll-track", hex: "#2A2A35", usage: "Piste de défilement", kind: "deco", against: SURFACE_1, againstName: "surface-1" }
  ];

  function luminance(hex) {
    const value = hex.replace("#", "");
    const channels = [0, 2, 4].map(function (offset) {
      const channel = parseInt(value.slice(offset, offset + 2), 16) / 255;
      return channel <= 0.03928 ? channel / 12.92 : Math.pow((channel + 0.055) / 1.055, 2.4);
    });
    return 0.2126 * channels[0] + 0.7152 * channels[1] + 0.0722 * channels[2];
  }

  function contrast(fg, bg) {
    const a = luminance(fg);
    const b = luminance(bg);
    const light = Math.max(a, b);
    const dark = Math.min(a, b);
    return (light + 0.05) / (dark + 0.05);
  }

  function ratioLabel(ratio) {
    return ratio.toFixed(2).replace(".", ",") + ":1";
  }

  function swatchBadge(row, ratio) {
    if (row.kind === "text") {
      if (ratio >= 7) return '<span class="badge-ok aaa">AAA</span>';
      if (ratio >= 4.5) return '<span class="badge-ok aa">AA</span>';
      return '<span class="badge-ok deco">ÉCHEC</span>';
    }
    if (row.kind === "ui") {
      return ratio >= 3
        ? '<span class="badge-ok aaa">UI ✓</span>'
        : '<span class="badge-ok deco">ÉCHEC</span>';
    }
    return '<span class="badge-ok deco">' + (row.kind === "surface" ? "surface" : "décoratif") + "</span>";
  }

  function renderSwatches(container) {
    container.innerHTML = SWATCHES.map(function (row) {
      const ratio = contrast(row.hex, row.against);
      return (
        '<div class="swatch">' +
        '<span class="chip-color" style="background:' + row.hex + '"></span>' +
        '<span class="s-main"><span class="s-name">' + row.name + "</span>" +
        '<span class="s-usage">' + row.usage + " · sur " + row.againstName + "</span></span>" +
        '<span class="s-hex">' + row.hex + "</span>" +
        '<span class="s-ratio">' + ratioLabel(ratio) + swatchBadge(row, ratio) + "</span>" +
        "</div>"
      );
    }).join("");
  }

  /* ------------------------------------------------------------------------
     Montage
     ------------------------------------------------------------------------ */
  function mount() {
    document.querySelectorAll("[data-board]").forEach(function (host) {
      const name = host.getAttribute("data-board");
      if (BOARDS[name]) host.innerHTML = BOARDS[name]();
    });
    document.querySelectorAll("[data-swatches]").forEach(function (host) {
      renderSwatches(host);
    });
  }

  window.RS = {
    ACCOUNTS: ACCOUNTS,
    icon: icon,
    panelAfter: panelAfter,
    panelBefore: panelBefore,
    boards: BOARDS,
    buildBoard: function (name) {
      return BOARDS[name] ? BOARDS[name]() : "";
    },
    renderSwatches: renderSwatches,
    contrast: contrast
  };

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", mount);
  } else {
    mount();
  }
})();
