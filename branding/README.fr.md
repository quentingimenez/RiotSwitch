# Identité visuelle

Logo choisi : **Twin Profiles**, version sans fond.

- Source : `logo-twin-profiles-transparent.png` (PNG RGBA 1024×1024, fond transparent).
- Icône Windows de l'application : `../src/RiotSwitcher.App/Assets/app.ico`
  (16, 20, 24, 32, 40, 48, 64, 128 et 256 px), générée par `make_app_icon.py`.
- Le PNG 1024 recadré utilisé par l'app est aussi dans
  `../src/RiotSwitcher.App/Assets/logo-twin-profiles.png`.

Pour régénérer l'icône après une modification du logo :

```powershell
python branding/make_app_icon.py
```

Le script recadre le contenu avec une petite marge, puis produit le `.ico`
multi-tailles et le PNG de l'icône. Les anciennes planches de propositions
restent dans `branding/proposals/` (ignoré par Git).
