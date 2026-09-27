#!/usr/bin/env python3
"""Composes the store images from the raw captures.

Every image is its own composition, described in `layouts.json`: where the light falls, where the device
stands, which parts of the capture are lifted out and magnified, and where the words go. The words are in
`captions.json`. Every pixel of the app in an image is a pixel of a raw capture: a device shows the whole
capture, a zoom shows a rectangle of it cut on element or row boundaries, magnified with a Lanczos filter.

The family, shared with the website:

- OLED black, and one light: the π gradient (lime `#C4F042` at the hottest cells → emerald `#22C55E` → deep
  emerald `#0E4A25` where it dissolves) as an ordered 4×4 Bayer dither of square cells, each cell either full
  colour or black; wide pools are lit on every other row. From afar it reads as a glow, up close as terminal
  pixels. The hero stands the π glyph itself, built from those cells, behind the device.
- SF Pro Bold for the headline (-0.04 em, leading 1.02), one phrase of it in solid lime; SF Mono uppercase with
  wide tracking for the numbered label; SF Pro Regular in the app's grey for the subline.
- No lines, rims, borders or boxes: separation comes from tone, light and black shadow, as in the app.

    python3 store/screenshots/compose.py --raw /tmp/ompanion-store/StoreShots/raw --repo .
    python3 store/screenshots/compose.py --verify
    python3 store/screenshots/compose.py --review /tmp/ompanion-store/StoreShots/review

Needs Pillow (`python3 -m pip install pillow`) and `rsvg-convert` (`brew install librsvg`) for the icons and the
π. Output sizes are the ones the stores accept today; see `store/screenshots/README.md` for the citations.
"""
from __future__ import annotations

import argparse
import itertools
import json
import math
import random
import subprocess
import sys
import tempfile
from dataclasses import dataclass
from functools import cache
from pathlib import Path
from typing import Iterable

from PIL import Image, ImageDraw, ImageFilter, ImageFont

HERE = Path(__file__).resolve().parent
BLACK = (0, 0, 0)
INK = (237, 237, 237)
MUTED = (143, 143, 143)
LIME = (196, 240, 66)
EMERALD = (34, 197, 94)
DEEP = (14, 74, 37)  # #0E4A25, where the light dissolves into black
RAMP_MID = 0.5  # where the ramp passes emerald
SF = "/System/Library/Fonts/SFNS.ttf"
SF_MONO = "/System/Library/Fonts/SFNSMono.ttf"
BAYER = ((0, 8, 2, 10), (12, 4, 14, 6), (3, 11, 1, 9), (15, 7, 13, 5))
DEVICE_BODY = (18, 18, 18)
DEVICE_EDGE = (44, 44, 44)  # the body's outer edge, one step above #262626 so it reads on black

CAPTIONS = json.loads((HERE / "captions.json").read_text())
LAYOUTS = json.loads((HERE / "layouts.json").read_text())
SHOT_ORDER = list(CAPTIONS["shots"])


@dataclass(frozen=True)
class Spec:
    """One store surface: the canvas it is composed on, the sizes the store accepts, and where it is written."""

    name: str
    size: tuple[int, int]
    accepted: tuple[tuple[int, int], ...]
    out: str
    suffix: str = ""


SPECS: dict[str, Spec] = {
    "ios-phone": Spec("ios-phone", (1320, 2868), ((1320, 2868), (2868, 1320)), "ios/fastlane/screenshots/en-US", "-iphone69"),
    "ios-ipad": Spec("ios-ipad", (2048, 2732), ((2048, 2732), (2732, 2048)), "ios/fastlane/screenshots/en-US", "-ipad13"),
    "play-phone": Spec("play-phone", (1080, 1920), ((1080, 1920), (1920, 1080)), "android/fastlane/metadata/android/en-US/images/phoneScreenshots"),
    "play-7in": Spec("play-7in", (1920, 1080), ((1920, 1080), (1080, 1920)), "android/fastlane/metadata/android/en-US/images/sevenInchScreenshots"),
    "play-10in": Spec("play-10in", (2560, 1440), ((2560, 1440), (1440, 2560)), "android/fastlane/metadata/android/en-US/images/tenInchScreenshots"),
}


# ---------------------------------------------------------------------------------------------------- type


@cache
def font(size: int, weight: int = 400, mono: bool = False) -> ImageFont.FreeTypeFont:
    """SF Pro at the optical size its pixel size calls for (Display above 60 px), or SF Mono."""
    if mono:
        face = ImageFont.truetype(SF_MONO, size)
        face.set_variation_by_axes([weight, weight])
        return face
    face = ImageFont.truetype(SF, size)
    face.set_variation_by_axes([100, 96 if size >= 60 else 28, 400, weight])
    return face


def text_width(draw: ImageDraw.ImageDraw, text: str, face: ImageFont.FreeTypeFont, tracking: float) -> float:
    if not text:
        return 0.0
    return sum(draw.textlength(character, font=face) for character in text) + tracking * (len(text) - 1)


def draw_text(draw: ImageDraw.ImageDraw, x: float, baseline: float, text: str, face: ImageFont.FreeTypeFont, tracking: float, fill) -> float:
    """Draws `text` letter by letter from its baseline; returns where the next letter would start."""
    for character in text:
        draw.text((x, baseline), character, font=face, fill=fill, anchor="ls")
        x += draw.textlength(character, font=face) + tracking
    return x


def accent_words(text: str) -> list[tuple[str, bool]]:
    """`Drive omp on [machines you own]` → words, each marked whether it is in the lime phrase."""
    words: list[tuple[str, bool]] = []
    accent = False
    for word in text.split():
        opens, closes = word.startswith("["), word.endswith("]")
        accent = accent or opens
        words.append((word.strip("[]"), accent))
        if closes:
            accent = False
    return words


def balanced(draw: ImageDraw.ImageDraw, words: list[tuple[str, bool]], face, tracking: float, width: float, count: int):
    """The split of `words` into `count` lines that keeps the widest line narrowest, or None when none fits."""
    if count > len(words):
        return None
    space = draw.textlength(" ", font=face) + tracking
    best = None
    for cuts in itertools.combinations(range(1, len(words)), count - 1):
        lines, start = [], 0
        for cut in (*cuts, len(words)):
            lines.append(words[start:cut])
            start = cut
        widths = [sum(text_width(draw, word, face, tracking) for word, _ in line) + space * (len(line) - 1) for line in lines]
        if max(widths) > width:
            continue
        key = (round(max(widths)), sum(value * value for value in widths))
        if best is None or key < best[0]:
            best = (key, lines)
    return best[1] if best else None


def headline_lines(draw: ImageDraw.ImageDraw, tokens: list[tuple[str, bool]], face, tracking: float, width: float, budget: int,
                   inline: bool):
    """The headline's lines: the white part and the lime phrase each start a line of their own and wrap on their own
    (or, `inline`, run on as one sentence), into as few balanced lines as fit; None when they need more than `budget`."""
    runs = [tokens] if inline else [list(run) for _, run in itertools.groupby(tokens, key=lambda token: token[1])]
    lines = []
    for run in runs:
        split = next((split for count in range(1, len(run) + 1) if (split := balanced(draw, run, face, tracking, width, count))), None)
        if split is None:
            return None
        lines += split
    return lines if len(lines) <= budget else None


def caption(image: Image.Image, spec_layout: dict, placement: dict, words: dict[str, str]) -> tuple[int, int, int, int]:
    """The numbered mono label, the headline with its lime phrase, and the subline, as one aligned block.

    `placement.at` is the block's left, centre or right edge (by `align`) and its top or bottom (by `anchor`); the
    headline shrinks from its size until it fits `lines` lines of the column. `inline` lets the lime phrase follow
    the white part on the same line, for the wide canvases."""
    width, height = image.size
    draw = ImageDraw.Draw(image)
    types = spec_layout["type"]
    mono = placement.get("mono", False)
    column = placement["width"] * width
    size = round(types["headline"] * placement.get("scale", 1.0))
    tokens = accent_words(words["headline"])
    while True:
        face = font(size, 700, mono)
        tracking = 0.0 if mono else -0.04 * size
        lines = headline_lines(draw, tokens, face, tracking, column, placement.get("lines", 2), placement.get("inline", False))
        if lines:
            break
        size -= 2
    leading = round(size * (1.08 if mono else 1.02))
    label_face = font(types["label"], 400, True)
    label_tracking = types["label"] * 0.16
    subline_face = font(types["subline"], 400)
    subline_tracking = -0.005 * subline_face.size
    subline_words = [(word, False) for word in words.get("subline", "").split()]
    sublines = next((split for count in (1, 2) if (split := balanced(draw, subline_words, subline_face, subline_tracking, column, count))),
                    [subline_words]) if subline_words else []
    subline_leading = round(subline_face.size * 1.3)
    cap = -face.getbbox("H", anchor="ls")[1]
    label_gap = round(types["label"] * 1.1 + size * 0.28)
    subline_gap = round(types["subline"] * 1.55)
    block = label_gap + cap + leading * (len(lines) - 1) + (subline_gap + subline_leading * (len(sublines) - 1) if sublines else 0)
    x, y = placement["at"][0] * width, placement["at"][1] * height
    top = y - block if placement.get("anchor", "top") == "bottom" else y
    align = placement.get("align", "left")
    extent = [width, 0]

    def start(line_width: float) -> float:
        left = {"left": x, "center": x - line_width / 2, "right": x - line_width}[align]
        extent[0], extent[1] = min(extent[0], left), max(extent[1], left + line_width)
        return left

    label = words["label"]
    label_cap = -label_face.getbbox("H", anchor="ls")[1]
    draw_text(draw, start(text_width(draw, label, label_face, label_tracking)), top + label_cap, label, label_face, label_tracking, MUTED)
    baseline = top + label_gap + cap
    space = draw.textlength(" ", font=face) + tracking
    for line in lines:
        line_width = sum(text_width(draw, word, face, tracking) for word, _ in line) + space * (len(line) - 1)
        cursor = start(line_width)
        for index, (word, accent) in enumerate(line):
            cursor = draw_text(draw, cursor, baseline, word, face, tracking, LIME if accent else INK)
            if index < len(line) - 1:
                cursor += space - tracking
        if placement.get("cursor") and line is lines[-1]:
            # The terminal's block cursor, one cell wide, after the last word.
            cell = draw.textlength("M", font=face)
            draw.rectangle([cursor + cell * 0.35, baseline - cap, cursor + cell * 1.25, baseline + size * 0.06], fill=LIME)
        baseline += leading
    baseline += subline_gap - leading
    for line in sublines:
        text = " ".join(word for word, _ in line)
        draw_text(draw, start(text_width(draw, text, subline_face, subline_tracking)), baseline, text, subline_face, subline_tracking, MUTED)
        baseline += subline_leading
    bottom = baseline - subline_leading + subline_face.size * 0.3 if sublines else baseline - subline_gap + size * 0.25
    return round(extent[0]), round(top), round(extent[1]), round(bottom)


# --------------------------------------------------------------------------------------------------- light


def render_svg(source: Path, width: int) -> Image.Image:
    """Rasterizes an SVG with rsvg-convert."""
    with tempfile.TemporaryDirectory() as tmp:
        target = Path(tmp) / "render.png"
        subprocess.run(["rsvg-convert", "-w", str(width), "--keep-aspect-ratio", "-o", str(target), str(source)], check=True)
        return Image.open(target).convert("RGBA").copy()


@cache
def glyph_ink(repo: Path) -> Image.Image:
    """The π's coverage, cropped to its ink, rendered large once."""
    alpha = render_svg(repo / "assets" / "ompanion_glyph.svg", 2048).getchannel("A")
    return alpha.crop(alpha.getbbox())


def ramp(t: float) -> tuple[int, int, int]:
    """The light's colour: lime at the hottest cells, emerald through the body, deep emerald where it dissolves."""
    t = min(1.0, max(0.0, t))
    low, high, start = (LIME, EMERALD, 0.0) if t < RAMP_MID else (EMERALD, DEEP, RAMP_MID)
    span = RAMP_MID if t < RAMP_MID else 1 - RAMP_MID
    return tuple(round(low[k] + (high[k] - low[k]) * (t - start) / span) for k in range(3))


def value_noise(columns: int, rows: int, seed: int):
    """Smooth noise, 0 to 255, on the cell grid: two octaves of a coarse random grid scaled up bicubically."""
    generator = random.Random(seed)
    octaves = []
    for step in (18, 6):
        coarse = (columns // step + 3, rows // step + 3)
        grid = Image.frombytes("L", coarse, generator.randbytes(coarse[0] * coarse[1]))
        octaves.append(grid.resize((columns, rows), Image.BICUBIC))
    return Image.blend(octaves[0], octaves[1], 0.35).point(lambda value: min(255, max(0, round((value - 128) * 1.8 + 128)))).load()


def light(size: tuple[int, int], cell: int, sources: list[dict], repo: Path, keep_out: tuple[int, int, int, int] | None = None) -> Image.Image:
    """The dithered light: every source adds a density field on a grid of `cell`-pixel squares; a cell is lit in
    full colour when its density beats the Bayer threshold at its position, else it stays black.

    `pool`: density `peak·(1−r)^gamma` over an ellipse, hottest at its core, broken up by a smooth value noise
    (`cloud`, 0 to 1) so its edge frays like light rather than a stamped disc; lit on every other row only, so a
    wide pool reads as calm scanlines rather than a solid wash.
    `pi`: the π glyph's own coverage, softened by `blur`, on every row so the mark stays whole; hottest at its
    top left, its density falling toward the bottom right to `fade` of its peak so the long leg dissolves.

    `keep_out` is the caption's box: a pool's density fades to nothing around it, so the words always sit on black
    while every cell stays either lit or dark. The π is placed clear of the words and never faded."""
    width, height = size
    columns, rows = math.ceil(width / cell), math.ceil(height / cell)
    density = [0.0] * (columns * rows)
    tint = [0.0] * (columns * rows)
    scan = [False] * (columns * rows)

    def lift(index: int, value: float, colour: float, scanlines: bool) -> None:
        if value > density[index]:
            density[index], tint[index], scan[index] = value, colour, scanlines

    for number, source in enumerate(sources):
        if "pool" in source:
            pool = source["pool"]
            cx, cy = pool["at"][0] * columns, pool["at"][1] * rows
            rx, ry = pool["radius"][0] * columns, pool["radius"][1] * columns
            peak, gamma, cloud = pool["peak"], pool.get("gamma", 1.6), pool.get("cloud", 0.5)
            noise = value_noise(columns, rows, seed=number + round(cx * 31 + cy * 17))
            for row in range(max(0, int(cy - ry)), min(rows, int(cy + ry) + 1)):
                for column in range(max(0, int(cx - rx)), min(columns, int(cx + rx) + 1)):
                    r = math.hypot((column + 0.5 - cx) / rx, (row + 0.5 - cy) / ry)
                    if r < 1:
                        broken = 1 - cloud + 2 * cloud * noise[column, row] / 255
                        lift(row * columns + column, min(1.0, peak * (1 - r) ** gamma * broken), r, True)
        elif "pi" in source:
            pi = source["pi"]
            ink = glyph_ink(repo)
            glyph_height = pi["height"] * rows
            glyph_width = ink.width * glyph_height / ink.height
            soft = pi.get("blur", 0.02) * glyph_height
            pad = math.ceil(soft * 3) + 1
            field = Image.new("L", (round(glyph_width) + 2 * pad, round(glyph_height) + 2 * pad), 0)
            field.paste(ink.resize((round(glyph_width), round(glyph_height)), Image.LANCZOS), (pad, pad))
            if soft:
                field = field.filter(ImageFilter.GaussianBlur(soft))
            coverage = field.load()
            left = pi["at"][0] * columns - glyph_width / 2 - pad
            top = pi["at"][1] * rows - glyph_height / 2 - pad
            peak, fade = pi["peak"], pi.get("fade", 0.3)
            for row in range(max(0, math.floor(top)), min(rows, math.ceil(top + field.height))):
                for column in range(max(0, math.floor(left)), min(columns, math.ceil(left + field.width))):
                    gx, gy = int(column - left), int(row - top)
                    if not (0 <= gx < field.width and 0 <= gy < field.height) or not coverage[gx, gy]:
                        continue
                    along = min(1.0, max(0.0, ((gx - pad) / glyph_width + (gy - pad) / glyph_height) / 2))
                    lift(row * columns + column, peak * coverage[gx, gy] / 255 * (1 - (1 - fade) * along), along, False)
    margin = 0.02 * min(size)  # black around the words
    comeback = 0.10 * min(size)  # then the light returns over this distance
    grid = Image.new("RGB", (columns, rows), BLACK)
    pixels = grid.load()
    for row in range(rows):
        thresholds = BAYER[row % 4]
        for column in range(columns):
            index = row * columns + column
            if scan[index] and row % 2:
                continue
            value = density[index]
            if keep_out and value and scan[index]:
                x0, y0, x1, y1 = keep_out
                x, y = (column + 0.5) * cell, (row + 0.5) * cell
                distance = math.hypot(max(x0 - x, 0, x - x1), max(y0 - y, 0, y - y1))
                value *= min(1.0, max(0.0, (distance - margin) / comeback))
            if value * 16 > thresholds[column % 4] + 0.5:
                pixels[column, row] = ramp(tint[index])
    return grid.resize((columns * cell, rows * cell), Image.NEAREST).crop((0, 0, width, height))


# ------------------------------------------------------------------------------------------ devices, zooms


def rounded_mask(size: tuple[int, int], radius: float) -> Image.Image:
    """An anti-aliased rounded rectangle, drawn at 4× and reduced."""
    big = Image.new("L", (size[0] * 4, size[1] * 4), 0)
    ImageDraw.Draw(big).rounded_rectangle([0, 0, big.width - 1, big.height - 1], radius=radius * 4, fill=255)
    return big.resize(size, Image.LANCZOS)


def shade(image: Image.Image, box: tuple[int, int, int, int], radius: float, spread: int, strength: float = 1.0) -> None:
    """A black, feathered shadow under `box`: it lifts what sits on it off the light and the device behind."""
    if spread <= 0:
        return
    x0, y0, x1, y1 = box
    mask = Image.new("L", (x1 - x0 + 4 * spread, y1 - y0 + 4 * spread), 0)
    ImageDraw.Draw(mask).rounded_rectangle([2 * spread, 2 * spread, 2 * spread + x1 - x0, 2 * spread + y1 - y0],
                                           radius=radius, fill=round(255 * strength))
    image.paste(BLACK, (x0 - 2 * spread, y0 - 2 * spread), mask.filter(ImageFilter.GaussianBlur(spread / 2)))


def device(image: Image.Image, shot: Image.Image, placement: dict, style: dict) -> tuple[int, int, int, int]:
    """The whole capture in a plain, flat device body: a bezel in near black with one grey outer edge. Returns its box."""
    width, height = image.size
    screen_width = round(placement["width"] * width)
    screen = shot.resize((screen_width, round(shot.height * screen_width / shot.width)), Image.LANCZOS)
    if placement.get("dim"):
        screen = Image.blend(screen, Image.new("RGB", screen.size, BLACK), placement["dim"])
    bezel = round(style["bezel"] * screen_width)
    radius = style["radius"] * screen_width
    edge = max(2, round(0.003 * screen_width))
    body = Image.new("RGB", (screen.width + 2 * bezel, screen.height + 2 * bezel), DEVICE_EDGE)
    body.paste(DEVICE_BODY, (edge, edge), rounded_mask((body.width - 2 * edge, body.height - 2 * edge), radius + bezel - edge))
    body.paste(screen, (bezel, bezel), rounded_mask(screen.size, radius))
    left, top = round(placement["at"][0] * width) - bezel, round(placement["at"][1] * height) - bezel
    shade(image, (left, top, left + body.width, top + body.height), radius + bezel, round(style["shadow"] * screen_width))
    image.paste(body, (left, top), rounded_mask(body.size, radius + bezel))
    return left, top, left + body.width, top + body.height


def zoom(image: Image.Image, shot: Image.Image, placement: dict, style: dict) -> tuple[int, int, int, int]:
    """A rectangle of the capture, magnified, rounded, lifted on a black shadow. Returns its box.

    `crop` is in capture pixels, cut on element or row boundaries; `width` is the zoom's width on the canvas."""
    width, height = image.size
    x0, y0, x1, y1 = placement["crop"]
    zoom_width = round(placement["width"] * width)
    scale = zoom_width / (x1 - x0)
    part = shot.crop((x0, y0, x1, y1)).resize((zoom_width, round((y1 - y0) * scale)), Image.LANCZOS)
    radius = placement.get("radius", style["zoom_radius"]) * scale
    left, top = round(placement["at"][0] * width), round(placement["at"][1] * height)
    shade(image, (left, top, left + part.width, top + part.height), radius, round(placement.get("shadow", style["zoom_shadow"]) * width))
    image.paste(part, (left, top), rounded_mask(part.size, radius))
    return left, top, left + part.width, top + part.height


# ------------------------------------------------------------------------------------------------ compose


def compose(spec: Spec, shot_name: str, shot: Image.Image, repo: Path) -> Image.Image:
    spec_layout = LAYOUTS["classes"][spec.name]
    layout = spec_layout["shots"][shot_name]
    words = CAPTIONS["shots"][shot_name]
    words = {**words, **words.get(spec.name, {})}
    # The caption is measured on a scratch canvas first, so the light can stay clear of it.
    box = caption(Image.new("RGB", spec.size), spec_layout, layout["caption"], words)
    image = light(spec.size, spec_layout["cell"], layout.get("light", []), repo, keep_out=box)
    layers = [(device if "device" in layer else zoom)(image, shot, layer.get("device") or layer["zoom"], spec_layout["device"])
              for layer in layout["layers"]]
    caption(image, spec_layout, layout["caption"], words)
    # A layout edit that runs the words into a device or a zoom fails here, not in review.
    x0, y0, x1, y1 = box
    for bx0, by0, bx1, by1 in layers:
        if x0 < bx1 and bx0 < x1 and y0 < by1 and by0 < y1:
            raise SystemExit(f"{spec.name} {shot_name}: the caption {box} overlaps a layer {(bx0, by0, bx1, by1)}")
    return image


def compose_class(spec: Spec, raw: Path, repo: Path) -> list[Path]:
    written: list[Path] = []
    # A run that failed before its first capture must not empty the class's directory: keep what is there.
    if not any((raw / spec.name / f"{shot}.png").exists() for shot in SHOT_ORDER):
        print(f"{spec.name}: no raw captures, leaving the composed images alone")
        return written
    for shot in SHOT_ORDER:
        source = raw / spec.name / f"{shot}.png"
        if not source.exists():
            continue
        with Image.open(source) as opened:
            capture = opened.convert("RGB")
        target = repo / spec.out / f"{shot}{spec.suffix}.png"
        write(compose(spec, shot, capture, repo), target, alpha=False)
        written.append(target)
    return written


def feature_graphic(repo: Path) -> Image.Image:
    """Play's feature graphic: the dithered π beside the wordmark and the hero's headline."""
    graphic = LAYOUTS["feature"]
    size = tuple(graphic["size"])
    image = light(size, graphic["cell"], graphic["light"], repo)
    draw = ImageDraw.Draw(image)
    x, baseline = graphic["wordmark"]["at"][0] * size[0], graphic["wordmark"]["at"][1] * size[1]
    wordmark = font(graphic["wordmark"]["size"], 700)
    draw_text(draw, x, baseline, "ompanion", wordmark, -0.04 * wordmark.size, INK)
    tagline = font(graphic["tagline"]["size"], 600)
    baseline = graphic["tagline"]["at"][1] * size[1]
    cursor = graphic["tagline"]["at"][0] * size[0]
    space = draw.textlength(" ", font=tagline)
    for word, accent in accent_words(CAPTIONS["feature"]["tagline"]):
        cursor = draw_text(draw, cursor, baseline, word, tagline, -0.02 * tagline.size, LIME if accent else MUTED) + space
    return image


# ------------------------------------------------------------------------------------------------- output


def write(image: Image.Image, path: Path, alpha: bool) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    image.convert("RGBA" if alpha else "RGB").save(path, "PNG", optimize=True)
    print(f"{path}  {image.size[0]}x{image.size[1]}  {'RGBA' if alpha else 'RGB'}")


def sheet(images: Iterable[Path], target: Path, tile_height: int, title: str, names: bool = True) -> None:
    """The images side by side at one height, in gallery order, each file's name under it."""
    tiles = []
    for path in images:
        with Image.open(path) as opened:
            tile = opened.convert("RGB")
        tiles.append((path.name, tile.resize((round(tile.width * tile_height / tile.height), tile_height), Image.LANCZOS)))
    if not tiles:
        return
    gap, head, foot = 24, 56, 44 if names else 0
    canvas = Image.new("RGB", (sum(tile.width for _, tile in tiles) + gap * (len(tiles) + 1), head + tile_height + foot + gap), (22, 22, 24))
    draw = ImageDraw.Draw(canvas)
    draw.text((gap, 18), title, font=font(22, 400, True), fill=INK)
    x = gap
    for name, tile in tiles:
        canvas.paste(tile, (x, head))
        if names:
            draw.text((x, head + tile_height + 12), name, font=font(16, 400, True), fill=MUTED)
        x += tile.width + gap
    write(canvas, target, alpha=False)


def review(spec: Spec, repo: Path, directory: Path) -> None:
    """What to judge a class by: the gallery as a contact sheet, as store thumbnails (300 px wide), the hero."""
    present = [path for shot in SHOT_ORDER if (path := repo / spec.out / f"{shot}{spec.suffix}.png").exists()]
    if not present:
        return
    directory.mkdir(parents=True, exist_ok=True)
    portrait = spec.size[1] > spec.size[0]
    sheet(present, directory / f"sheet-{spec.name}.png", 900 if portrait else 520, f"{spec.name} — gallery order")
    thumb_height = round(300 * spec.size[1] / spec.size[0])
    sheet(present, directory / f"thumbs-{spec.name}.png", thumb_height, f"{spec.name} — 300 px wide, store thumbnail size", names=False)
    with Image.open(present[0]) as hero:
        write(hero.convert("RGB"), directory / f"hero-{spec.name}.png", alpha=False)


def verify(repo: Path) -> None:
    """Checks every composed image against the stores' rules and exits non-zero when one fails."""
    rows: list[tuple[str, str, bool]] = []

    def check(path: Path, sizes: Iterable[tuple[int, int]], alpha_allowed: bool) -> None:
        with Image.open(path) as opened:
            alpha = opened.mode in ("RGBA", "LA") or "transparency" in opened.info
            ok = opened.size in tuple(sizes) and (alpha_allowed or not alpha)
            rows.append((str(path.relative_to(repo)), f"{opened.size[0]}x{opened.size[1]} {'RGBA' if alpha else 'RGB'}", ok))

    for spec in SPECS.values():
        for shot in SHOT_ORDER:
            path = repo / spec.out / f"{shot}{spec.suffix}.png"
            if path.exists():
                check(path, spec.accepted, alpha_allowed=False)
    images = repo / "android/fastlane/metadata/android/en-US/images"
    for path, size, alpha_allowed in (
        (images / "featureGraphic.png", (1024, 500), False),
        (images / "icon.png", (512, 512), True),
        (repo / "store/app-icon-1024.png", (1024, 1024), False),
    ):
        if path.exists():
            check(path, [size], alpha_allowed)
    for path, size, ok in rows:
        print(f"{'ok  ' if ok else 'FAIL'} {size:>12}  {path}")
    print(f"{sum(1 for _, _, ok in rows if ok)}/{len(rows)} images pass")
    if any(not ok for _, _, ok in rows):
        sys.exit(1)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--raw", default="/tmp/ompanion-store/StoreShots/raw", help="directory of raw captures, one per class")
    parser.add_argument("--repo", default=str(HERE.parents[1]), help="repository root the images are written into")
    parser.add_argument("--only", action="append", choices=sorted(SPECS), help="compose one class (repeatable)")
    parser.add_argument("--review", help="write the review artifacts (sheets, thumbnails, heroes) into a directory")
    parser.add_argument("--skip-brands", action="store_true", help="skip the Play feature graphic and the icons")
    parser.add_argument("--verify", action="store_true", help="only check the composed images against the store rules")
    arguments = parser.parse_args()

    raw = Path(arguments.raw)
    repo = Path(arguments.repo).resolve()
    if arguments.verify:
        verify(repo)
        return
    for name in arguments.only or SPECS:
        compose_class(SPECS[name], raw, repo)
    if not arguments.skip_brands:
        images = repo / "android/fastlane/metadata/android/en-US/images"
        write(feature_graphic(repo), images / "featureGraphic.png", alpha=False)
        write(render_svg(repo / "assets" / "ompanion.svg", 512), images / "icon.png", alpha=True)
        write(render_svg(repo / "assets" / "ompanion.svg", 1024), repo / "store/app-icon-1024.png", alpha=False)
    if arguments.review:
        for name in arguments.only or SPECS:
            review(SPECS[name], repo, Path(arguments.review))
        with Image.open(repo / "android/fastlane/metadata/android/en-US/images/featureGraphic.png") as graphic:
            write(graphic.convert("RGB"), Path(arguments.review) / "feature-graphic.png", alpha=False)
            write(graphic.convert("RGB").resize((256, 125), Image.LANCZOS), Path(arguments.review) / "feature-graphic-small.png", alpha=False)


if __name__ == "__main__":
    main()
