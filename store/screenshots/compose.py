#!/usr/bin/env python3
"""Composes the store images from the raw captures.

Every composed image is the real screenshot in a rounded frame on black, with a subtle brand gradient, a
headline and one subline from `captions.json`. No device frames, no invented UI. The Play icon and the App
Store marketing icon come from `assets/ompanion.svg`, the Play feature graphic adds the glyph and the wordmark.

    python3 store/screenshots/compose.py --raw /tmp/ompanion-store/StoreShots/raw --repo .
    python3 store/screenshots/compose.py --contact-sheet /tmp/ompanion-store/StoreShots/contact-sheet.png

Needs Pillow (`python3 -m pip install pillow`) and, for the icons and the glyph, `rsvg-convert`
(`brew install librsvg`). Output sizes are the ones the stores accept today; see `store/screenshots/README.md`
for the citations, and rerun after a store changes them.
"""
from __future__ import annotations

import argparse
import json
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable

from PIL import Image, ImageDraw, ImageFont

HERE = Path(__file__).resolve().parent
BLACK = (4, 4, 5)
INK = (246, 246, 248)
MUTED = (150, 152, 158)
LIME = (196, 240, 66)
EMERALD = (34, 197, 94)
EDGE = (38, 40, 44)
SF = "/System/Library/Fonts/SFNS.ttf"

CAPTIONS = json.loads((HERE / "captions.json").read_text())
SHOT_ORDER = list(CAPTIONS["shots"])


@dataclass(frozen=True)
class Spec:
    """One store surface: the composed canvas and its other orientation, where the images belong."""

    name: str
    size: tuple[int, int]
    alternate: tuple[int, int]
    out: str
    suffix: str = ""

    @property
    def layout(self) -> str:
        return "portrait" if self.size[1] > self.size[0] else "landscape"


SPECS: dict[str, Spec] = {
    "ios-phone": Spec("ios-phone", (1320, 2868), (2868, 1320), "ios/fastlane/screenshots/en-US", "-iphone69"),
    "ios-ipad": Spec("ios-ipad", (2732, 2048), (2048, 2732), "ios/fastlane/screenshots/en-US", "-ipad13"),
    "play-phone": Spec("play-phone", (1080, 1920), (1920, 1080), "android/fastlane/metadata/android/en-US/images/phoneScreenshots"),
    "play-7in": Spec("play-7in", (1920, 1080), (1080, 1920), "android/fastlane/metadata/android/en-US/images/sevenInchScreenshots"),
    "play-10in": Spec("play-10in", (2560, 1440), (1440, 2560), "android/fastlane/metadata/android/en-US/images/tenInchScreenshots"),
}


def font(size: int, weight: str = "Regular") -> ImageFont.FreeTypeFont:
    face = ImageFont.truetype(SF, size)
    if weight != "Regular":
        face.set_variation_by_name(weight)
    return face


def glow(size: tuple[int, int], center: tuple[float, float], radius: float, alpha: int) -> Image.Image:
    """A lime-to-emerald radial glow on a transparent layer, the only colour in the composition."""
    width, height = size
    layer = Image.new("RGBA", size, (0, 0, 0, 0))
    gradient = Image.linear_gradient("L").rotate(35, expand=True).resize(size)
    paint = Image.composite(Image.new("RGB", size, LIME), Image.new("RGB", size, EMERALD), gradient)
    mask = Image.new("L", size, 0)
    draw = ImageDraw.Draw(mask)
    steps = 64
    cx, cy = center
    for step in range(steps, 0, -1):
        r = radius * step / steps
        draw.ellipse([cx - r, cy - r, cx + r, cy + r], fill=int(alpha * (1 - step / steps) ** 1.6))
    layer.paste(paint, (0, 0), mask)
    return layer


def rounded(image: Image.Image, radius: int) -> Image.Image:
    mask = Image.new("L", image.size, 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, image.size[0] - 1, image.size[1] - 1], radius=radius, fill=255)
    framed = image.convert("RGBA")
    framed.putalpha(mask)
    return framed


def fit(box: tuple[int, int], aspect: float) -> tuple[int, int]:
    """The largest `aspect` (width/height) rectangle inside `box`."""
    width, height = box
    if width / height > aspect:
        return int(height * aspect), height
    return width, int(width / aspect)


def accent_bar(width: int, height: int) -> Image.Image:
    bar = Image.new("RGB", (width, height), LIME)
    gradient = Image.linear_gradient("L").rotate(90, expand=True).resize((width, height))
    bar = Image.composite(Image.new("RGB", (width, height), LIME), Image.new("RGB", (width, height), EMERALD), gradient)
    return rounded(bar, height // 2)


def compose(canvas: tuple[int, int], layout: str, shot: Image.Image, caption: dict[str, str], radius_scale: float) -> Image.Image:
    width, height = canvas
    image = Image.new("RGB", canvas, BLACK)
    if layout == "portrait":
        accent = glow(canvas, (width * 0.5, height * 0.06), width * 1.15, 46)
        image.paste(accent, (0, 0), accent)
        margin = int(width * 0.086)
        # By the smaller of width and height, so a wide iPad canvas gets a headline the size a phone's reads at,
        # not one that takes a third of the image.
        headline_size = int(min(width * 0.1150, height * 0.050))
        subline_size = int(min(width * 0.0310, height * 0.0145))
        top = int(height * 0.045)
        text_end = draw_text(image, margin, top, headline_size, subline_size, caption, width - 2 * margin)
        box = (width - 2 * margin, height - text_end - int(height * 0.055))
        frame_size = fit(box, shot.width / shot.height)
        origin = (margin + (box[0] - frame_size[0]) // 2, text_end + int(height * 0.028))
    else:
        accent = glow(canvas, (width * 0.86, height * 0.12), width * 0.85, 42)
        image.paste(accent, (0, 0), accent)
        margin = int(width * 0.055)
        # A landscape canvas is short: one headline line keeps most of its height for the screen.
        headline_size = int(height * 0.070)
        subline_size = int(height * 0.028)
        top = int(height * 0.055)
        text_end = draw_text(image, margin, top, headline_size, subline_size, caption, width - 2 * margin, max_lines=1)
        box = (width - 2 * margin, height - text_end - int(height * 0.050))
        frame_size = fit(box, shot.width / shot.height)
        origin = (margin + (box[0] - frame_size[0]) // 2, text_end + int(height * 0.028))

    radius = int(frame_size[0] * radius_scale)
    framed = rounded(shot.convert("RGB").resize(frame_size, Image.LANCZOS), radius)
    image.paste(framed, origin, framed)
    border = ImageDraw.Draw(image)
    border.rounded_rectangle(
        [origin[0], origin[1], origin[0] + frame_size[0] - 1, origin[1] + frame_size[1] - 1],
        radius=radius,
        outline=EDGE,
        width=max(2, frame_size[0] // 420),
    )
    return image


def wrap(draw: ImageDraw.ImageDraw, text: str, face: ImageFont.FreeTypeFont, max_width: int) -> list[str]:
    """Greedy word wrap; the caption's own words decide the lines, so many are allowed."""
    lines: list[str] = []
    current = ""
    for word in text.split():
        candidate = f"{current} {word}".strip()
        if current and draw.textlength(candidate, font=face) > max_width:
            lines.append(current)
            current = word
        else:
            current = candidate
    if current:
        lines.append(current)
    return lines


def headline(draw: ImageDraw.ImageDraw, text: str, size: int, max_width: int, max_lines: int = 2) -> tuple[int, list[str]]:
    """The largest size at which the headline fits [max_lines] lines of [max_width]."""
    while size > 24:
        lines = wrap(draw, text, font(size, "Bold"), max_width)
        if len(lines) <= max_lines:
            return size, lines
        size = int(size * 0.88)
    return size, wrap(draw, text, font(size, "Bold"), max_width)


def draw_text(
    image: Image.Image, x: int, top: int, size: int, subline_size: int, caption: dict[str, str], max_width: int, max_lines: int = 2
) -> int:
    """Draws the headline, subline and accent bar; returns the y the frame may start at."""
    draw = ImageDraw.Draw(image)
    size, lines = headline(draw, caption["headline"], size, max_width, max_lines)
    face = font(size, "Bold")
    line_height = int(size * 1.12)
    for line in lines:
        draw.text((x, top), line, font=face, fill=INK)
        top += line_height
    top += int(size * 0.28)
    draw.text((x, top), caption["subline"], font=font(subline_size), fill=MUTED)
    top += int(subline_size * 2.0)
    bar_width = max(56, int(size * 1.5))
    bar_height = max(5, size // 9)
    bar = accent_bar(bar_width, bar_height)
    image.paste(bar, (x, top), bar)
    return top + bar_height


def feature_graphic(repo: Path, size: tuple[int, int] = (1024, 500)) -> Image.Image:
    """Play's feature graphic: the glyph and the wordmark as one group, tagline under the wordmark's left edge.

    The π stands on the wordmark's baseline like a letter: its bar at the cap height, its short left leg ending on
    the baseline, and its long right leg dropping below it the way the p of "ompanion" does."""
    width, height = size
    image = Image.new("RGB", size, BLACK)
    accent = glow(size, (width * 0.74, height * 0.5), width * 0.8, 34)
    image.paste(accent, (0, 0), accent)
    draw = ImageDraw.Draw(image)
    wordmark_face = font(int(height * 0.200), "Semibold")
    word = "ompanion"
    tagline_face = font(int(height * 0.066))
    cap_top, baseline_offset = cap_metrics(wordmark_face)
    cap_height = baseline_offset - cap_top
    # In assets/ompanion_glyph.svg the bar starts at y 283, the left leg ends at 651.9 and the right leg at 741.
    scale = cap_height / (651.9 - 283)
    glyph = trimmed_glyph(repo, round((741 - 283) * scale))
    gap = int(cap_height * 0.42)
    word_width = int(draw.textlength(word, font=wordmark_face))
    group_width = glyph.width + gap + word_width
    tagline_lines = wrap(draw, CAPTIONS["feature"]["tagline"], tagline_face, word_width + glyph.width)
    line_height = int(tagline_face.size * 1.25)
    # Room for the descender of the p above the tagline.
    tagline_gap = int(height * 0.150)
    # Cap top to the tagline's last line, centred as one block.
    block_height = cap_height + tagline_gap + line_height * len(tagline_lines)
    baseline = (height - block_height) // 2 + cap_height
    left = (width - group_width) // 2
    image.paste(glyph, (left, baseline - cap_height), glyph)
    text_left = left + glyph.width + gap
    draw.text((text_left, baseline), word, font=wordmark_face, fill=INK, anchor="ls")
    top = baseline + tagline_gap
    for line in tagline_lines:
        draw.text((text_left, top), line, font=tagline_face, fill=MUTED, anchor="ls")
        top += line_height
    return image


def cap_metrics(face: ImageFont.FreeTypeFont) -> tuple[int, int]:
    """The cap top and the baseline of `face`, measured from the text origin."""
    _, cap_top, _, _ = face.getbbox("H", anchor="ls")
    return cap_top, 0


def trimmed_glyph(repo: Path, target_height: int) -> Image.Image:
    """The π alone, cropped to its ink, `target_height` pixels tall; rendered large first for clean edges."""
    big = render_svg(repo / "assets" / "ompanion_glyph.svg", 2048)
    glyph = big.crop(big.getbbox())
    return glyph.resize((round(glyph.width * target_height / glyph.height), target_height), Image.LANCZOS)


def render_svg(source: Path, width: int) -> Image.Image:
    """rasterizes an SVG with rsvg-convert into a temp PNG of `width` pixels."""
    import subprocess
    import tempfile

    with tempfile.TemporaryDirectory() as tmp:
        target = Path(tmp) / "render.png"
        subprocess.run(
            ["rsvg-convert", "-w", str(width), "--keep-aspect-ratio", "-o", str(target), str(source)],
            check=True,
        )
        return Image.open(target).convert("RGBA").copy()


def write(image: Image.Image, path: Path, alpha: bool) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    image.convert("RGBA" if alpha else "RGB").save(path, "PNG", optimize=True)
    print(f"{path}  {image.size[0]}x{image.size[1]}  {'RGBA' if alpha else 'RGB'}")


def compose_class(spec: Spec, raw: Path, repo: Path) -> list[tuple[str, Path]]:
    written: list[tuple[str, Path]] = []
    # A run that failed before its first capture must not empty the class's directory: keep what is there.
    if not any((raw / spec.name / f"{shot}.png").exists() for shot in SHOT_ORDER):
        print(f"{spec.name}: no raw captures, leaving the composed images alone")
        return written
    for shot in SHOT_ORDER:
        source = raw / spec.name / f"{shot}.png"
        if not source.exists():
            continue
        with Image.open(source) as opened:
            shot_image = opened.convert("RGB")
            # A capture that came out the other way round keeps its own orientation: the sizes of both are
            # accepted, and a portrait device is what a portrait composition wants.
            landscape = shot_image.width > shot_image.height
            size = spec.size if landscape == (spec.layout == "landscape") else spec.alternate
            canvas = compose(size, "landscape" if landscape else "portrait", shot_image, CAPTIONS["shots"][shot], 0.030)
        target = repo / spec.out / f"{shot}{spec.suffix}.png"
        write(canvas, target, alpha=False)
        written.append((shot, target))
    return written


def contact_sheet(images: Iterable[Path], target: Path, columns: int = 4, tile: int = 360) -> None:
    items = [path for path in images if path.exists()]
    if not items:
        return
    rows = (len(items) + columns - 1) // columns
    sheet = Image.new("RGB", (columns * (tile + 24) + 24, rows * (tile + 62) + 24), (18, 18, 20))
    draw = ImageDraw.Draw(sheet)
    label = font(20)
    for index, path in enumerate(items):
        with Image.open(path) as opened:
            thumb = opened.convert("RGB")
            thumb.thumbnail((tile, tile), Image.LANCZOS)
        column = index % columns
        row = index // columns
        x = 24 + column * (tile + 24) + (tile - thumb.width) // 2
        y = 24 + row * (tile + 62) + (tile - thumb.height) // 2
        sheet.paste(thumb, (x, y))
        draw.text((24 + column * (tile + 24), 24 + row * (tile + 62) + tile + 14), path.name, font=label, fill=INK)
    write(sheet, target, alpha=False)


def verify(repo: Path) -> list[tuple[str, str, bool]]:
    """Checks every composed image against the stores' rules, returns (path, size, ok) rows."""
    import sys

    rows: list[tuple[str, str, bool]] = []
    for spec in SPECS.values():
        for shot in SHOT_ORDER:
            path = repo / spec.out / f"{shot}{spec.suffix}.png"
            if not path.exists():
                continue
            with Image.open(path) as opened:
                alpha = opened.mode in ("RGBA", "LA") or "transparency" in opened.info
                ok = opened.size in (spec.size, spec.alternate) and not alpha
                rows.append((str(path.relative_to(repo)), f"{opened.size[0]}x{opened.size[1]} {'RGBA' if alpha else 'RGB'}", ok))
    brands = [
        (repo / "android/fastlane/metadata/android/en-US/images/featureGraphic.png", (1024, 500), False),
        (repo / "android/fastlane/metadata/android/en-US/images/icon.png", (512, 512), True),
        (repo / "store/app-icon-1024.png", (1024, 1024), False),
    ]
    for path, size, alpha_allowed in brands:
        if not path.exists():
            continue
        with Image.open(path) as opened:
            alpha = opened.mode in ("RGBA", "LA") or "transparency" in opened.info
            ok = opened.size == size and (alpha_allowed or not alpha)
            rows.append((str(path.relative_to(repo)), f"{opened.size[0]}x{opened.size[1]} {'RGBA' if alpha else 'RGB'}", ok))
    for path, size, ok in rows:
        print(f"{'ok  ' if ok else 'FAIL'} {size:>12}  {path}")
    print(f"{sum(1 for _, _, ok in rows if ok)}/{len(rows)} images pass")
    if any(not ok for _, _, ok in rows):
        sys.exit(1)
    return rows


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--raw", default="/tmp/ompanion-store/StoreShots/raw", help="directory of raw captures, one per class")
    parser.add_argument("--repo", default=str(HERE.parents[1]), help="repository root the images are written into")
    parser.add_argument("--only", action="append", choices=sorted(SPECS), help="compose one class (repeatable)")
    parser.add_argument("--contact-sheet", help="write a contact sheet of everything composed")
    parser.add_argument("--skip-brands", action="store_true", help="skip the Play feature graphic and the icons")
    parser.add_argument("--verify", action="store_true", help="only check the composed images against the store rules")
    arguments = parser.parse_args()

    raw = Path(arguments.raw)
    repo = Path(arguments.repo).resolve()
    if arguments.verify:
        verify(repo)
        return
    written: list[Path] = []
    for name in arguments.only or sorted(SPECS):
        written += [path for _, path in compose_class(SPECS[name], raw, repo)]

    if not arguments.skip_brands:
        graphic = repo / "android/fastlane/metadata/android/en-US/images/featureGraphic.png"
        icon = repo / "android/fastlane/metadata/android/en-US/images/icon.png"
        marketing = repo / "store/app-icon-1024.png"
        write(feature_graphic(repo), graphic, alpha=False)
        write(render_svg(repo / "assets" / "ompanion.svg", 512), icon, alpha=True)
        write(render_svg(repo / "assets" / "ompanion.svg", 1024), marketing, alpha=False)
        written += [graphic, icon, marketing]

    if arguments.contact_sheet:
        contact_sheet(written, Path(arguments.contact_sheet))


if __name__ == "__main__":
    main()
