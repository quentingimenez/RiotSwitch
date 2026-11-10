"""Rend les captures PNG de la maquette via Chrome headless puis rogne la transparence.

Usage (depuis n'importe quel dossier) :
    python rendre-captures.py

Dépendances : Google Chrome (chemin ci-dessous) et Pillow.
Les captures sortent dans ./captures en @2x, rognées au contenu alpha.
"""
from pathlib import Path
import subprocess

from PIL import Image

ROOT = Path(__file__).resolve().parent
CHROME = Path(r"C:\Program Files\Google\Chrome\Application\chrome.exe")
OUT = ROOT / "captures"

VIEWS = [
    ("01-boutons", "boutons"),
    ("02-avant", "avant"),
    ("03-apres", "apres"),
    ("04-vide", "vide"),
    ("05-survol", "survol"),
    ("06-epingle", "epingle"),
    ("07-defilement", "defilement"),
    ("08-statuts", "statuts"),
    ("09-statut-avertissement", "statut-avert"),
    ("10-statut-succes", "statut-succes"),
    ("11-contexte", "contexte"),
    ("12-icones", "icones"),
    ("13-anatomie", "anatomie"),
]


def render(name: str, view: str) -> None:
    raw = OUT / f"_{view}.png"
    url = (ROOT / "capture.html").as_uri() + f"?vue={view}"
    subprocess.run(
        [
            str(CHROME),
            "--headless=new",
            "--disable-gpu",
            "--hide-scrollbars",
            "--force-device-scale-factor=2",
            "--default-background-color=00000000",
            "--window-size=1400,1700",
            "--virtual-time-budget=2000",
            f"--screenshot={raw}",
            url,
        ],
        check=True,
        capture_output=True,
    )
    image = Image.open(raw).convert("RGBA")
    bbox = image.getchannel("A").getbbox()
    if bbox:
        image = image.crop(bbox)
    target = OUT / f"{name}.png"
    image.save(target, optimize=True)
    raw.unlink(missing_ok=True)
    print(f"{target.name}: {image.size[0]} x {image.size[1]} px (@2x)")


def main() -> None:
    OUT.mkdir(exist_ok=True)
    for name, view in VIEWS:
        render(name, view)


if __name__ == "__main__":
    main()
