"""Prépare l'icône de l'application à partir du Twin Profiles transparent.

Le PNG source a beaucoup de marge transparente : on recadre le contenu avec
une petite respiration, puis on produit un .ico multi-tailles pour Windows.
"""
from __future__ import annotations

from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "branding" / "logo-twin-profiles-transparent.png"
ASSETS = ROOT / "src" / "RiotSwitcher.App" / "Assets"
OUT_ICO = ASSETS / "app.ico"
OUT_PNG = ASSETS / "logo-twin-profiles.png"

# Tailles standard Windows + tailles utiles aux barres des tâches à 125/150 %.
ICON_SIZES = [
    (16, 16),
    (20, 20),
    (24, 24),
    (32, 32),
    (40, 40),
    (48, 48),
    (64, 64),
    (128, 128),
    (256, 256),
]


def square_crop(image: Image.Image, pad_ratio: float = 0.10) -> Image.Image:
    alpha = image.getchannel("A").point(lambda value: 255 if value > 8 else 0)
    bbox = alpha.getbbox()
    if bbox is None:
        raise SystemExit("Le PNG source est entièrement transparent.")

    left, top, right, bottom = bbox
    width = right - left
    height = bottom - top
    side = max(width, height)
    padding = int(round(side * pad_ratio))
    side += padding * 2

    canvas = Image.new("RGBA", (side, side), (0, 0, 0, 0))
    canvas.alpha_composite(
        image.crop(bbox),
        ((side - width) // 2, (side - height) // 2),
    )
    return canvas


def main() -> None:
    ASSETS.mkdir(parents=True, exist_ok=True)
    source = Image.open(SOURCE).convert("RGBA")
    icon = square_crop(source).resize((1024, 1024), Image.Resampling.LANCZOS)
    icon.save(OUT_PNG)
    icon.save(OUT_ICO, format="ICO", sizes=ICON_SIZES)
    print("ICO", OUT_ICO)
    print("PNG", OUT_PNG)
    print("Tailles", ", ".join(f"{w}x{h}" for w, h in ICON_SIZES))


if __name__ == "__main__":
    main()
