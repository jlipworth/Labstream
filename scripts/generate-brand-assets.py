#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["pillow>=10"]
# ///
"""Regenerate every Labstream brand/icon asset from one geometric source of truth.

The mark is a white capital L on a black tile. The L is Inter Black's own glyph outline
(rectilinear: 1490 cap height, 1006 advance-box width, 404 stem, 326 arm, in font units),
so no font file is needed to draw it. It is placed "optically": nudged halfway from the
bounding-box centre toward its centre of mass (right and up).

Outputs (all paths relative to the repo root):
  * Labstream/Platforms/Mobile/Resources/MobileAppIcon.icon   iPhone/iPad Icon Composer document
  * Labstream/Platforms/macOS/Resources/MacAppIcon.icon       Mac Icon Composer document
  * AppIcon.solidimagestack                                    visionOS Back/Front layers
  * TVAppIcon.brandassets                                      tvOS layered icons + Top Shelf
  * LabstreamGlyph.imageset                                    in-app vector mark (SVG)

Top Shelf's wordmark is set in Inter Bold (SIL OFL). The pinned Inter release is downloaded
once into ~/.cache/labstream/fonts and verified by SHA-256.

Usage:  scripts/generate-brand-assets.py [--check]
  --check  regenerate into a temp dir and fail if any committed asset differs.
"""
from __future__ import annotations

import argparse
import hashlib
import io
import json
import shutil
import sys
import tempfile
import urllib.request
import zipfile
from pathlib import Path

from PIL import Image, ImageChops, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parent.parent
CATALOG = Path("Labstream/Shared/Resources/Assets.xcassets")

# Inter Black "L" outline, font units.
CAP, WIDTH, STEM, ARM = 1490, 1006, 404, 326
# Approved proportion (variant B): cap height = 52% of the square tile; visionOS uses 46%
# so the L clears the circular mask.
SQUARE_HEIGHT = 0.52
VISION_HEIGHT = 0.46
TV_HEIGHT = 0.53  # of the 5:3 tile's height
OPTICAL_X, OPTICAL_Y = 0.088, 0.048  # fraction of L width / height

INK = (0, 0, 0)
PAPER = (255, 255, 255)
SUPERSAMPLE = 4

INTER_URL = "https://github.com/rsms/inter/releases/download/v4.1/Inter-4.1.zip"
INTER_SHA256 = "9883fdd4a49d4fb66bd8177ba6625ef9a64aa45899767dde3d36aa425756b11e"
INTER_BOLD = "extras/ttf/Inter-Bold.ttf"


def l_rects(cx: float, cy: float, h: float) -> tuple[tuple[float, ...], tuple[float, ...]]:
    """Stem and arm rectangles (x0, y0, x1, y1) of the optically centred L."""
    w = h * WIDTH / CAP
    stem, arm = h * STEM / CAP, h * ARM / CAP
    x = cx - w / 2 + OPTICAL_X * w
    y = cy - h / 2 - OPTICAL_Y * h
    return (x, y, x + stem, y + h), (x, y + h - arm, x + w, y + h)


def l_svg_path(cx: float, cy: float, h: float) -> str:
    (x, y, sx, _), (_, ay, ax, by) = l_rects(cx, cy, h)
    return (f"M{x:.2f} {y:.2f}H{sx:.2f}V{ay:.2f}H{ax:.2f}V{by:.2f}H{x:.2f}Z")


def svg(width: int, height: int, h: float) -> str:
    return (
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}" '
        f'viewBox="0 0 {width} {height}"><path fill="#FFFFFF" '
        f'd="{l_svg_path(width / 2, height / 2, h)}"/></svg>\n'
    )


def draw_l(img: Image.Image, cx: float, cy: float, h: float) -> None:
    draw = ImageDraw.Draw(img)
    for r in l_rects(cx, cy, h):
        draw.rectangle([round(r[0]), round(r[1]), round(r[2]) - 1, round(r[3]) - 1],
                       fill=PAPER + (255,) if img.mode == "RGBA" else PAPER)


def raster(size: tuple[int, int], *, background: tuple[int, int, int] | None, h_frac: float,
           cx_frac: float = 0.5) -> Image.Image:
    """Antialiased L, opaque on `background` or on transparency when it is None."""
    w, h = size
    big = (w * SUPERSAMPLE, h * SUPERSAMPLE)
    img = Image.new("RGBA", big, (0, 0, 0, 0)) if background is None else Image.new("RGB", big, background)
    if h_frac > 0:
        draw_l(img, big[0] * cx_frac, big[1] / 2, big[1] * h_frac)
    return img.resize(size, Image.Resampling.LANCZOS)


def save_png(img: Image.Image, path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    img.save(path, optimize=True)


def write_json(path: Path, data: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data, indent=2) + "\n")


XCODE_INFO = {"author": "xcode", "version": 1}


def icon_composer(path: Path) -> None:
    """Flat Icon Composer document: solid black fill + one non-glass white L layer."""
    if path.exists():
        shutil.rmtree(path)
    (path / "Assets").mkdir(parents=True)
    (path / "Assets" / "L.svg").write_text(svg(1024, 1024, 1024 * SQUARE_HEIGHT))
    write_json(path / "icon.json", {
        "fill": {"solid": "srgb:0.00000,0.00000,0.00000,1.00000"},
        "groups": [{
            "layers": [{"glass": False, "image-name": "L.svg", "name": "L"}],
            "shadow": {"kind": "none", "opacity": 0.5},
            "translucency": {"enabled": False, "value": 0.5},
        }],
        "supported-platforms": {"squares": "shared"},
    })


def top_shelf(size: tuple[int, int], font_bytes: bytes) -> Image.Image:
    """Mark tile + 'Labstream' wordmark on black with a faint graphite glow behind the mark."""
    w, h = size
    W, H = w * 2, h * 2  # 2x supersample (the @2x shelf is already 4640 px wide)
    img = Image.new("RGB", (W, H), INK)
    # Faint graphite (#1C1C1E at the centre) elliptical glow behind the mark, fading to black.
    gw, gh = W // 16, H // 16
    glow = Image.new("RGB", (gw, gh))
    for gy in range(gh):
        for gx in range(gw):
            d = (((gx - gw * 0.22) / (gw * 0.5)) ** 2 + ((gy - gh / 2) / (gh * 0.9)) ** 2) ** 0.5
            v = max(0.0, 1 - d) ** 1.5
            glow.putpixel((gx, gy), (round(28 * v), round(28 * v), round(30 * v)))
    glow = glow.resize((W, H), Image.Resampling.BICUBIC)
    img = ImageChops.lighter(img, glow)
    unit = H / 720
    tile = int(210 * unit)
    left = int(1920 * unit * 0.09)
    top = (H - tile) // 2
    radius = int(tile * 0.2237)
    tile_img = Image.new("RGBA", (tile, tile), (0, 0, 0, 0))
    td = ImageDraw.Draw(tile_img)
    td.rounded_rectangle([0, 0, tile - 1, tile - 1], radius=radius, fill=INK + (255,),
                         outline=(255, 255, 255, 41), width=max(1, int(1.5 * unit)))
    draw_l(tile_img, tile / 2, tile / 2, tile * SQUARE_HEIGHT)
    img.paste(tile_img, (left, top), tile_img)
    font = ImageFont.truetype(io.BytesIO(font_bytes), int(88 * unit))
    draw = ImageDraw.Draw(img)
    x = left + tile + int(60 * unit)
    draw.text((x, H / 2), "Labstream", font=font, fill=PAPER, anchor="lm")
    return img.resize(size, Image.Resampling.LANCZOS)


def generate(root: Path) -> None:
    cat = root / CATALOG
    # Icon Composer documents (iPhone/iPad + Mac), in platform-only synced folders.
    icon_composer(root / "Labstream/Platforms/Mobile/Resources/MobileAppIcon.icon")
    icon_composer(root / "Labstream/Platforms/macOS/Resources/MacAppIcon.icon")

    # In-app vector mark: same canvas/placement as the square icon, transparent background.
    glyph = cat / "LabstreamGlyph.imageset"
    if glyph.exists():
        shutil.rmtree(glyph)
    glyph.mkdir(parents=True)
    (glyph / "LabstreamGlyph.svg").write_text(svg(1024, 1024, 1024 * SQUARE_HEIGHT))
    write_json(glyph / "Contents.json", {
        "images": [{"filename": "LabstreamGlyph.svg", "idiom": "universal"}],
        "info": XCODE_INFO,
        "properties": {"preserves-vector-representation": True, "template-rendering-intent": "original"},
    })

    # visionOS solid image stack.
    stack = cat / "AppIcon.solidimagestack"
    save_png(raster((1024, 1024), background=INK, h_frac=0.0),
             stack / "Back.solidimagestacklayer/Content.imageset/Labstream-AppIcon-Back-1024.png")
    save_png(raster((1024, 1024), background=None, h_frac=VISION_HEIGHT),
             stack / "Front.solidimagestacklayer/Content.imageset/Labstream-AppIcon-Front-1024.png")

    # tvOS layered icons.
    tv = cat / "TVAppIcon.brandassets"
    for stack_name, files in {
        "App Icon.imagestack": {"": (400, 240), "@2x": (800, 480)},
        "App Icon - App Store.imagestack": {"": (1280, 768)},
    }.items():
        for suffix, size in files.items():
            save_png(raster(size, background=INK, h_frac=0.0),
                     tv / stack_name / f"Back.imagestacklayer/Content.imageset/back{suffix}.png")
            save_png(raster(size, background=None, h_frac=TV_HEIGHT),
                     tv / stack_name / f"Front.imagestacklayer/Content.imageset/front{suffix}.png")

    # Top Shelf images.
    with zipfile.ZipFile(io.BytesIO(fetch_inter())) as archive:
        font_bytes = archive.read(INTER_BOLD)
    for name, (w, h) in {"Top Shelf Image.imageset": (1920, 720), "Top Shelf Image Wide.imageset": (2320, 720)}.items():
        save_png(top_shelf((w, h), font_bytes), tv / name / "topshelf.png")
        save_png(top_shelf((w * 2, h * 2), font_bytes), tv / name / "topshelf@2x.png")


def fetch_inter() -> bytes:
    cache = Path.home() / ".cache/labstream/fonts/Inter-4.1.zip"
    if not cache.exists():
        cache.parent.mkdir(parents=True, exist_ok=True)
        with urllib.request.urlopen(INTER_URL, timeout=60) as response:  # noqa: S310 (pinned URL)
            cache.write_bytes(response.read())
    data = cache.read_bytes()
    if hashlib.sha256(data).hexdigest() != INTER_SHA256:
        cache.unlink()
        raise SystemExit(f"Inter download checksum mismatch; removed {cache}; re-run to retry")
    return data


OWNED = [
    "Labstream/Platforms/Mobile/Resources/MobileAppIcon.icon",
    "Labstream/Platforms/macOS/Resources/MacAppIcon.icon",
    str(CATALOG / "LabstreamGlyph.imageset"),
    str(CATALOG / "AppIcon.solidimagestack"),
    str(CATALOG / "TVAppIcon.brandassets"),
]


def check() -> int:
    with tempfile.TemporaryDirectory() as tmp:
        tmp_root = Path(tmp)
        for rel in OWNED:  # seed Contents.json skeletons the generator doesn't author
            src = ROOT / rel
            if src.exists():
                shutil.copytree(src, tmp_root / rel)
        generate(tmp_root)
        stale = []
        for rel in OWNED:
            for f in sorted((tmp_root / rel).rglob("*")):
                if f.is_file():
                    committed = ROOT / f.relative_to(tmp_root)
                    if not committed.exists() or committed.read_bytes() != f.read_bytes():
                        stale.append(str(f.relative_to(tmp_root)))
        if stale:
            print("Brand assets are stale; run scripts/generate-brand-assets.py:", *stale, sep="\n  ")
            return 1
    print("Brand assets match the generator.")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--check", action="store_true", help="fail if committed assets differ")
    args = parser.parse_args()
    if args.check:
        return check()
    generate(ROOT)
    print("Regenerated brand assets.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
