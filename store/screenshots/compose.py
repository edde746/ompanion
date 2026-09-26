#!/usr/bin/env python3
"""Composes the store images from the raw captures.

Every composed image is a real screenshot in a rounded frame on OLED black: a mono label, a headline and a
subline from `captions.json`, and one signal line that runs across the set. No device frames, no invented UI —
every pixel inside the frame is a pixel of the app, and the exploded details live on the website, which has the
room for them.

The visual language, shared with the website:

- One colour, the π gradient (lime `#C4F042` → emerald `#22C55E`), used as light: a rim hairline along the top
  edge of the frame, one small glow behind that edge, and the signal line.
- Texture: film grain over the black, and a dot grid that fades out radially — both quiet enough to read as
  flat black until you look.
- Type: SF Pro Display with tight tracking for the headline, SF Mono uppercase with wide tracking for the
  label. No gradient text.
- The π watermark: an outline stroke, once per class, on the hero shot only, cropped by an edge.

    python3 store/screenshots/compose.py --raw /tmp/ompanion-store/StoreShots/raw --repo .
    python3 store/screenshots/compose.py --verify
    python3 store/screenshots/compose.py --contact-sheet /tmp/ompanion-store/StoreShots/contact-sheet.png
    python3 store/screenshots/compose.py --review /tmp/ompanion-design/store

Needs Pillow (`python3 -m pip install pillow`) and, for the icons, the glyph and the watermark,
`rsvg-convert` (`brew install librsvg`). Output sizes are the ones the stores accept today; see
`store/screenshots/README.md` for the citations, and rerun after a store changes them.
"""
from __future__ import annotations

import argparse
import itertools
import json
import random
from dataclasses import dataclass, replace
from pathlib import Path
from typing import Iterable

from PIL import Image, ImageChops, ImageDraw, ImageFilter, ImageFont, ImageOps

HERE = Path(__file__).resolve().parent
BLACK = (0, 0, 0)
INK = (237, 237, 237)
MUTED = (143, 143, 143)
LIME = (196, 240, 66)
EMERALD = (34, 197, 94)
SF = "/System/Library/Fonts/SFNS.ttf"
SF_MONO = "/System/Library/Fonts/SFNSMono.ttf"

GRAIN = 0.030  # film grain over the black, opacity
GLOW = 0.09  # the radial glow's alpha at its centre
GLOW_FALLOFF = 1.15  # how fast it fades: 1 is linear, higher pools it
DOT_OPACITY = 0.055  # the dot grid's alpha at its centre, before the radial fade
DOT_PITCH = 24  # 1x logical pixels between dots
DOT_SIZE = 1  # 1x logical pixels per dot
RIM = 1.5  # 1x logical pixels of rim light along a frame's top edge
RIM_ALPHA = 0.62  # the rim hairline's opacity at its brightest
NODE = 6  # 1x logical pixels across a signal line's nodes
LINE_ALPHA = 0.62  # the signal line's opacity
STROKE = 1.8  # 1x logical pixels of signal line
LINE_X = 0.68  # where the line drops onto the frame, across the frame's own width: its right third

CAPTIONS = json.loads((HERE / "captions.json").read_text())
SHOT_ORDER = list(CAPTIONS["shots"])


@dataclass(frozen=True)
class Spec:
    """One store surface: the composed canvas, its other orientation, and where the images belong."""

    name: str
    size: tuple[int, int]
    alternate: tuple[int, int]
    out: str
    suffix: str = ""
    style: str = "phone"
    logical: tuple[int, int] = (440, 956)  # 1x points, portrait then landscape

    @property
    def layout(self) -> str:
        return "portrait" if self.size[1] > self.size[0] else "landscape"

    def scale(self, size: tuple[int, int]) -> float:
        """Canvas pixels per logical point: 3 for a phone, 2 for a tablet."""
        portrait = size[1] > size[0]
        return size[0] / self.logical[0 if portrait else 1]


SPECS: dict[str, Spec] = {
    "ios-phone": Spec("ios-phone", (1320, 2868), (2868, 1320), "ios/fastlane/screenshots/en-US", "-iphone69", "phone", (440, 956)),
    "ios-ipad": Spec("ios-ipad", (2732, 2048), (2048, 2732), "ios/fastlane/screenshots/en-US", "-ipad13", "tablet", (1024, 1366)),
    "play-phone": Spec("play-phone", (1080, 1920), (1920, 1080), "android/fastlane/metadata/android/en-US/images/phoneScreenshots", "", "phone", (360, 808)),
    "play-7in": Spec("play-7in", (1920, 1080), (1080, 1920), "android/fastlane/metadata/android/en-US/images/sevenInchScreenshots", "", "tablet", (600, 960)),
    "play-10in": Spec("play-10in", (2560, 1440), (1440, 2560), "android/fastlane/metadata/android/en-US/images/tenInchScreenshots", "", "tablet", (800, 1280)),
}


@dataclass(frozen=True)
class Layout:
    """The geometry of one canvas shape, every value a fraction of that canvas."""

    margin: float  # left edge of the caption, and of the frame when it is not centred
    caption_top: float  # top of the mono label, of the height
    caption_width: float  # the caption column, of the width
    label_size: float  # of the width
    headline_size: float  # largest headline size, of the height
    headline_lines: int
    subline_size: float  # of the width
    caption_gap: float  # portrait: the gap between the caption and the frame, carried by the signal line
    frame_top: float  # landscape: the frame's top, with the caption beside it
    frame_width: float  # of the width; the frame is centred unless frame_left is set
    frame_left: float | None
    route_y: float  # landscape: the signal line's height, above the frame's top edge
    glow: tuple[float, float]
    glow_radius: float  # of the width
    dots: tuple[float, float]
    dot_radius: float  # of the width
    watermark: tuple[float, float, float] | None  # centre x, centre y, height


PHONE_PORTRAIT = Layout(
    margin=0.080, caption_top=0.038, caption_width=0.640, label_size=0.030, headline_size=0.046, headline_lines=2,
    subline_size=0.0295, caption_gap=0.050, frame_top=0.250, frame_width=0.840, frame_left=None, route_y=0.225,
    glow=(0.500, 0.250), glow_radius=0.26, dots=(0.50, 0.41), dot_radius=0.80, watermark=(0.990, 0.135, 0.150),
)
TABLET_PORTRAIT = replace(
    PHONE_PORTRAIT, caption_width=0.600, label_size=0.028, subline_size=0.028,
)
LANDSCAPE = Layout(
    margin=0.055, caption_top=0.200, caption_width=0.235, label_size=0.020, headline_size=0.062, headline_lines=3,
    subline_size=0.017, caption_gap=0.050, frame_top=0.200, frame_width=0.660, frame_left=0.300, route_y=0.150,
    glow=(0.630, 0.200), glow_radius=0.24, dots=(0.65, 0.42), dot_radius=0.80, watermark=(0.200, 0.930, 0.180),
)
LAYOUTS: dict[tuple[str, str], Layout] = {
    ("phone", "portrait"): PHONE_PORTRAIT,
    ("phone", "landscape"): LANDSCAPE,
    ("tablet", "portrait"): TABLET_PORTRAIT,
    ("tablet", "landscape"): LANDSCAPE,
}
# A canvas squarer than the capture would crop a phone frame twice as deep as the iPhone's; give the frame less
# width instead, so the two phones read the same size on the page.
OVERRIDES: dict[str, dict[str, float]] = {"play-phone": {"frame_width": 0.700}}


def layout_for(spec: Spec, orientation: str) -> Layout:
    layout = LAYOUTS[(spec.style, orientation)]
    return replace(layout, **OVERRIDES.get(spec.name, {}))


def font(size: int, weight: str = "Regular", mono: bool = False) -> ImageFont.FreeTypeFont:
    face = ImageFont.truetype(SF_MONO if mono else SF, size)
    if weight != "Regular" and not mono:
        face.set_variation_by_name(weight)
    return face


def ramp(size: tuple[int, int], horizontal: bool = True) -> Image.Image:
    """A black-to-white ramp: left to right, or top to bottom."""
    width, height = size
    if horizontal:
        row = bytes(round(255 * x / max(1, width - 1)) for x in range(width))
        return Image.frombytes("L", size, row * height)
    column = [bytes([round(255 * y / max(1, height - 1))]) for y in range(height)]
    return Image.frombytes("L", size, b"".join(byte * width for byte in column))


def gradient_paint(size: tuple[int, int], horizontal: bool = True) -> Image.Image:
    """The π gradient: lime at the left (or the top) to emerald at the other end."""
    return Image.composite(Image.new("RGB", size, LIME), Image.new("RGB", size, EMERALD), ramp(size, horizontal))


def end_fade(size: tuple[int, int], share: float = 0.22) -> Image.Image:
    """Full across the middle, tapering to nothing over `share` of each end."""
    width, height = size
    row = bytes(
        round(255 * min(x / share, (1 - x) / share, 1.0))
        for x in (index / max(1, width - 1) for index in range(width))
    )
    return Image.frombytes("L", size, row * height)


def radial_mask(size: tuple[int, int], centre: tuple[float, float], radius: float, gamma: float = 1.5) -> Image.Image:
    """A soft round falloff: opaque at `centre`, nothing at `radius`, drawn small and scaled up."""
    width, height = size
    step = 4
    small = Image.new("L", (max(1, width // step), max(1, height // step)), 0)
    draw = ImageDraw.Draw(small)
    cx, cy, r = centre[0] / step, centre[1] / step, radius / step
    rings = 48
    for ring in range(rings, 0, -1):
        rr = r * ring / rings
        draw.ellipse([cx - rr, cy - rr, cx + rr, cy + rr], fill=int(255 * (1 - ring / rings) ** gamma))
    return small.resize(size, Image.BILINEAR)


def add_glow(image: Image.Image, layout: Layout, paint: Image.Image) -> Image.Image:
    """The one soft light behind the frame's top edge."""
    width, height = image.size
    mask = radial_mask(image.size, (layout.glow[0] * width, layout.glow[1] * height), layout.glow_radius * width, GLOW_FALLOFF)
    image.paste(paint, (0, 0), mask.point(lambda value: int(value * GLOW)))
    return image


def add_grain(image: Image.Image, opacity: float = GRAIN, seed: int = 7) -> Image.Image:
    """Film grain: noise at a low opacity over the black, so the glow and the dots do not band."""
    width, height = image.size
    noise = Image.frombytes("L", (width, height), random.Random(seed).randbytes(width * height))
    return ImageChops.add(image, noise.point(lambda value: int(value * opacity)).convert("RGB"))


def add_dots(image: Image.Image, layout: Layout, scale: float) -> Image.Image:
    """A 1 px dot grid at 24 px pitch, fading out radially: terminal cells, barely there."""
    width, height = image.size
    pitch = max(3, round(DOT_PITCH * scale))
    dot = max(1, round(DOT_SIZE * scale))
    grid = Image.new("L", (width, height), 0)
    draw = ImageDraw.Draw(grid)
    for y in range(pitch, height, pitch):
        for x in range(pitch, width, pitch):
            draw.rectangle([x, y, x + dot - 1, y + dot - 1], fill=255)
    fade = radial_mask((width, height), (layout.dots[0] * width, layout.dots[1] * height), layout.dot_radius * width, 1.0)
    mask = ImageChops.multiply(grid, fade).point(lambda value: int(value * DOT_OPACITY))
    image.paste(Image.new("RGB", image.size, INK), (0, 0), mask)
    return image


def rounded_mask(size: tuple[int, int], radius: int) -> Image.Image:
    mask = Image.new("L", size, 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, size[0] - 1, size[1] - 1], radius=radius, fill=255)
    return mask


def rim_mask(size: tuple[int, int], radius: int, thickness: int) -> Image.Image:
    """A band along the top edge: it follows the rounded corners down and fades out at both ends."""
    width, height = size
    shape = rounded_mask(size, radius)
    shifted = Image.new("L", size, 0)
    shifted.paste(shape.crop((0, 0, width, height - thickness)), (0, thickness))
    band = ImageChops.subtract(shape, shifted)
    span = max(thickness * 3, radius)
    vertical = Image.new("L", size, 0)
    vertical.paste(ImageOps.invert(ramp((width, span), horizontal=False)), (0, 0))
    return ImageChops.multiply(ImageChops.multiply(band, end_fade(size)), vertical)


def signal(image: Image.Image, points: list[tuple[float, float]], width: float, nodes: list[tuple[float, float]] | None = None,
           node_radius: float = 0.0) -> None:
    """A gradient stroke: straight segments, rounded turns, round nodes at its ends."""
    mask = Image.new("L", image.size, 0)
    draw = ImageDraw.Draw(mask)
    draw.line(points, fill=255, width=max(1, round(width)), joint="curve")
    radius = width / 2
    for point in points[1:-1] + (nodes or []):
        draw.ellipse([point[0] - radius, point[1] - radius, point[0] + radius, point[1] + radius], fill=255)
    for node in nodes or []:
        draw.ellipse([node[0] - node_radius, node[1] - node_radius, node[0] + node_radius, node[1] + node_radius], fill=255)
    paint = gradient_paint(image.size)
    image.paste(paint, (0, 0), mask.point(lambda value: int(value * LINE_ALPHA)))


def tracked_length(draw: ImageDraw.ImageDraw, text: str, face: ImageFont.FreeTypeFont, tracking: float) -> float:
    if not text:
        return 0.0
    return sum(draw.textlength(character, font=face) for character in text) + tracking * (len(text) - 1)


def draw_tracked(
    draw: ImageDraw.ImageDraw, xy: tuple[float, float], text: str, face: ImageFont.FreeTypeFont, tracking: float, fill
) -> None:
    x, y = xy
    for character in text:
        draw.text((x, y), character, font=face, fill=fill)
        x += draw.textlength(character, font=face) + tracking


def wrap(draw: ImageDraw.ImageDraw, text: str, face: ImageFont.FreeTypeFont, max_width: int, tracking: float = 0.0) -> list[str]:
    """Greedy word wrap; the caption's own words decide the lines, so many are allowed."""
    lines: list[str] = []
    current = ""
    for word in text.split():
        candidate = f"{current} {word}".strip()
        if current and tracked_length(draw, candidate, face, tracking) > max_width:
            lines.append(current)
            current = word
        else:
            current = candidate
    if current:
        lines.append(current)
    return lines


def balanced_split(
    draw: ImageDraw.ImageDraw, words: list[str], face: ImageFont.FreeTypeFont, tracking: float, max_width: int, lines: int
) -> list[str] | None:
    """The split of `words` into `lines` lines that minimises the widest line, or None when none fits.

    Every boundary is tried, so a headline never ends on a lone word unless no other split fits the column."""
    if lines < 1 or lines > len(words):
        return None
    best: tuple[tuple[float, float], list[str]] | None = None
    for cuts in itertools.combinations(range(1, len(words)), lines - 1):
        parts: list[str] = []
        start = 0
        for cut in (*cuts, len(words)):
            parts.append(" ".join(words[start:cut]))
            start = cut
        widths = [tracked_length(draw, part, face, tracking) for part in parts]
        if max(widths) > max_width:
            continue
        key = (round(max(widths), 2), round(sum(width * width for width in widths), 2))
        if best is None or key < best[0]:
            best = (key, parts)
    return best[1] if best else None


def prefer_whole_line(
    draw: ImageDraw.ImageDraw, words: list[str], size: int, parts: list[str], max_width: int
) -> tuple[int, list[str], ImageFont.FreeTypeFont, float]:
    """A line holding one short word reads badly at thumbnail size; a slightly smaller single line is better."""
    if len(parts) > 1 and any(len(part.split()) == 1 and len(part) <= 5 for part in parts):
        for smaller in range(size, max(24, int(size * 0.93)), -1):
            face = font(smaller, "Bold")
            single = balanced_split(draw, words, face, tracking=-smaller * 0.020, max_width=max_width, lines=1)
            if single:
                return smaller, single, face, -smaller * 0.020
    return size, parts, font(size, "Bold"), -size * 0.020


def headline(draw: ImageDraw.ImageDraw, text: str, size: int, max_width: int, max_lines: int) -> tuple[int, list[str], ImageFont.FreeTypeFont, float]:
    """The largest size at which the headline fits [max_lines] balanced lines of [max_width]."""
    words = text.split()
    while size > 24:
        face = font(size, "Bold")
        tracking = -size * 0.020
        for lines in range(1, max_lines + 1):
            parts = balanced_split(draw, words, face, tracking, max_width, lines)
            if parts:
                return prefer_whole_line(draw, words, size, parts, max_width)
        size = int(size * 0.88)
    face = font(size, "Bold")
    tracking = -size * 0.020
    for lines in range(1, max_lines + 1):
        parts = balanced_split(draw, words, face, tracking, max_width, lines)
        if parts:
            return prefer_whole_line(draw, words, size, parts, max_width)
    return size, wrap(draw, text, face, max_width, tracking), face, tracking


def caption_block(image: Image.Image, layout: Layout, caption: dict[str, str], size: tuple[int, int], draw_text: bool = True) -> int:
    """Draws the mono label, the headline and the subline; returns the y they end at.

    Called once with `draw_text` off to measure the block, so the frame can sit a fixed gap under it."""
    width, height = size
    margin = layout.margin * width
    draw = ImageDraw.Draw(image)
    label_size = max(9, round(layout.label_size * width))
    label_face = font(label_size, mono=True)
    label_tracking = label_size * 0.12
    top = layout.caption_top * height
    if draw_text:
        draw_tracked(draw, (margin, top), caption["label"], label_face, label_tracking, MUTED)
    top += round(label_size * 1.85)
    headline_size, lines, face, tracking = headline(draw, caption["headline"], round(layout.headline_size * height),
                                                    int(layout.caption_width * width), layout.headline_lines)
    leading = int(headline_size * 1.10)
    for line in lines:
        if draw_text:
            draw_tracked(draw, (margin, top), line, face, tracking, INK)
        top += leading
    top += int(headline_size * 0.34)
    subline_size = max(9, round(layout.subline_size * width))
    subline_face = font(subline_size)
    subline_tracking = -subline_size * 0.005
    subline_width = int(layout.caption_width * width)
    subline_lines = wrap(draw, caption["subline"], subline_face, subline_width, subline_tracking)
    # The same balance, at the same number of lines, so the caption's height never moves.
    moved = balanced_split(draw, caption["subline"].split(), subline_face, subline_tracking, subline_width, len(subline_lines))
    for line in moved or subline_lines:
        if draw_text:
            draw_tracked(draw, (margin, top), line, subline_face, subline_tracking, MUTED)
        top += int(subline_size * 1.30)
    return top


def frame_rect(layout: Layout, size: tuple[int, int], shot_aspect: float, top: float) -> tuple[int, int, int, int]:
    """The screenshot's frame: its height follows its width, so the canvas crops its bottom edge."""
    width, _ = size
    frame_width = layout.frame_width * width
    frame_height = frame_width / shot_aspect
    left = layout.frame_left * width if layout.frame_left is not None else (width - frame_width) / 2
    return round(left), round(top), round(left + frame_width), round(top + frame_height)


def place_shot(image: Image.Image, shot: Image.Image, rect: tuple[int, int, int, int], radius: int, scale: float) -> None:
    box = (rect[2] - rect[0], rect[3] - rect[1])
    framed = rounded(shot.convert("RGB").resize(box, Image.LANCZOS), radius)
    image.paste(framed, (rect[0], rect[1]), framed)
    paste_rim(image, (rect[0], rect[1]), box, radius, scale)


def rounded(image: Image.Image, radius: int) -> Image.Image:
    framed = image.convert("RGBA")
    framed.putalpha(rounded_mask(image.size, radius))
    return framed


def paste_rim(image: Image.Image, box: tuple[int, int], size: tuple[int, int], radius: int, scale: float) -> None:
    """The rim light: a gradient hairline along the element's top edge, fading out along its sides."""
    rim = rim_mask(size, radius, max(1, round(RIM * scale))).point(lambda value: int(value * RIM_ALPHA))
    image.paste(gradient_paint(size), box, rim)


def route(image: Image.Image, frame: tuple[int, int, int, int], y: float, size: tuple[int, int], scale: float) -> None:
    """One line across the image at a height every image in the class shares, with one drop into the frame.

    The line arrives from the image on the left, turns down once - a rounded elbow - and ends in one node on the
    frame's top edge at the frame's right third, a height and an x every image of the class shares; the run then
    carries on to the right edge, so a class laid side by side reads as one strip. It stands for the SSH link."""
    width, _ = size
    stroke = max(1, round(STROKE * scale))
    node = max(2.0, round(NODE * scale) / 2)
    x = frame[0] + (frame[2] - frame[0]) * LINE_X
    signal(image, [(-stroke, y), (x, y), (x, frame[1])], stroke, [(x, frame[1])], node)
    signal(image, [(x + stroke / 2, y), (width + stroke, y)], stroke)


def watermark(image: Image.Image, repo: Path, layout: Layout, size: tuple[int, int]) -> None:
    """The π as an outline stroke, once, cropped by an edge, clear of the headline."""
    if not layout.watermark:
        return
    width, height = size
    centre_x, centre_y, tall = layout.watermark
    glyph = outline_glyph(repo, round(tall * height))
    layer = Image.new("RGBA", glyph.size, (0, 0, 0, 0))
    layer.paste(gradient_paint(glyph.size).convert("RGBA"), (0, 0), glyph)
    layer.putalpha(glyph.point(lambda value: int(value * 0.06)))
    image.paste(layer, (round(centre_x * width - glyph.width / 2), round(centre_y * height - glyph.height / 2)), layer)


def outline_glyph(repo: Path, target_height: int, stroke: int = 22) -> Image.Image:
    """The π's ink as a hollow stroke: the shape minus a copy eroded by `stroke`."""
    big = render_svg(repo / "assets" / "ompanion_glyph.svg", 2048)
    ink = Image.new("L", big.size, 0)
    ink.paste(big.getchannel("A"), (0, 0))
    box = ink.getbbox()
    ink = ink.crop(box)
    inner = ink.filter(ImageFilter.MinFilter(stroke if stroke % 2 else stroke + 1))
    outline = ImageChops.subtract(ink, inner)
    return outline.resize((max(1, round(ink.width * target_height / ink.height)), target_height), Image.LANCZOS)


def render_svg(source: Path, width: int) -> Image.Image:
    """Rasterizes an SVG with rsvg-convert into a temp PNG of `width` pixels."""
    import subprocess
    import tempfile

    with tempfile.TemporaryDirectory() as tmp:
        target = Path(tmp) / "render.png"
        subprocess.run(
            ["rsvg-convert", "-w", str(width), "--keep-aspect-ratio", "-o", str(target), str(source)],
            check=True,
        )
        return Image.open(target).convert("RGBA").copy()


def compose(spec: Spec, shot: Image.Image, caption: dict[str, str], repo: Path, size: tuple[int, int], orientation: str) -> Image.Image:
    layout = layout_for(spec, orientation)
    scale = spec.scale(size)
    width, height = size
    image = Image.new("RGB", size, BLACK)
    # The caption is measured first: the frame sits a fixed gap under it, and the signal line runs in that gap.
    caption_end = caption_block(image, layout, caption, size, draw_text=False)
    if orientation == "portrait":
        frame_top = caption_end + layout.caption_gap * height
        route_y = caption_end + layout.caption_gap * height / 2
    else:
        frame_top = layout.frame_top * height
        route_y = layout.route_y * height
    frame = frame_rect(layout, size, shot.width / shot.height, frame_top)
    image = add_glow(image, replace(layout, glow=(layout.glow[0], frame_top / height)), gradient_paint(size))
    image = add_grain(image)
    image = add_dots(image, layout, scale)
    if caption["label"].startswith("01"):
        watermark(image, repo, layout, size)
    place_shot(image, shot, frame, max(6, round((frame[2] - frame[0]) * 0.030)), scale)
    route(image, frame, route_y, size, scale)
    caption_block(image, layout, caption, size)
    return image


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
            orientation = "landscape" if landscape else "portrait"
            size = spec.size if landscape == (spec.layout == "landscape") else spec.alternate
            canvas = compose(spec, shot_image, CAPTIONS["shots"][shot], repo, size, orientation)
        target = repo / spec.out / f"{shot}{spec.suffix}.png"
        write(canvas, target, alpha=False)
        written.append((shot, target))
    return written


def feature_graphic(repo: Path, size: tuple[int, int] = (1024, 500)) -> Image.Image:
    """Play's feature graphic: the glyph and the wordmark as one group, the signal line arriving at the mark.

    The π stands on the wordmark's baseline like a letter: its bar at the cap height, its short left leg ending on
    the baseline, and its long right leg dropping below it the way the p of "ompanion" does."""
    width, height = size
    image = Image.new("RGB", size, BLACK)
    image = add_glow(image, replace(PHONE_PORTRAIT, glow=(0.62, 0.42), glow_radius=0.55), gradient_paint(size))
    image = add_grain(image)
    image = add_dots(image, replace(PHONE_PORTRAIT, dots=(0.42, 0.45), dot_radius=0.70), 1.5)
    draw = ImageDraw.Draw(image)
    wordmark = font(int(height * 0.205), "Semibold")
    word = "ompanion"
    tagline = font(int(height * 0.062))
    cap_top, baseline_offset = cap_metrics(wordmark)
    cap_height = baseline_offset - cap_top
    # In assets/ompanion_glyph.svg the bar starts at y 283, the left leg ends at 651.9 and the right leg at 741.
    glyph = trimmed_glyph(repo, round((741 - 283) * cap_height / (651.9 - 283)))
    gap = int(cap_height * 0.42)
    word_width = int(tracked_length(draw, word, wordmark, -wordmark.size * 0.02))
    group_width = glyph.width + gap + word_width
    lines = wrap(draw, CAPTIONS["feature"]["tagline"], tagline, word_width + glyph.width)
    line_height = int(tagline.size * 1.30)
    block_height = cap_height + int(height * 0.150) + line_height * len(lines)
    baseline = (height - block_height) // 2 + cap_height
    left = (width - group_width) // 2
    image.paste(glyph, (left, baseline - cap_height), glyph)
    text_left = left + glyph.width + gap
    draw_tracked(draw, (text_left, baseline - cap_height), word, wordmark, -wordmark.size * 0.02, INK)
    top = baseline + int(height * 0.150)
    for line in lines:
        draw_tracked(draw, (text_left, top), line, tagline, -tagline.size * 0.005, MUTED)
        top += line_height
    # The link arrives at the mark from the left edge, its mono label above its end.
    mid = baseline - cap_height // 2
    stroke = max(2, round(height * 0.004))
    label = font(max(10, round(height * 0.042)), mono=True)
    tracking = label.size * 0.12
    span = left - int(0.05 * width)
    signal(image, [(-stroke, mid), (span, mid)], stroke, [(span, mid)], max(3, round(height * 0.010)))
    text_width = tracked_length(draw, "SSH", label, tracking)
    draw_tracked(draw, (span - text_width, mid - int(label.size * 2.6)), "SSH", label, tracking, MUTED)
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


def write(image: Image.Image, path: Path, alpha: bool) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    image.convert("RGBA" if alpha else "RGB").save(path, "PNG", optimize=True)
    print(f"{path}  {image.size[0]}x{image.size[1]}  {'RGBA' if alpha else 'RGB'}")


def contact_sheet(images: Iterable[Path], target: Path, columns: int = 4, tile: int = 360, title: str = "") -> None:
    items = [path for path in images if path.exists()]
    if not items:
        return
    rows = (len(items) + columns - 1) // columns
    sheet = Image.new("RGB", (columns * (tile + 24) + 24, rows * (tile + 62) + 24 + (36 if title else 0)), (18, 18, 20))
    draw = ImageDraw.Draw(sheet)
    label = font(20, mono=True)
    if title:
        draw.text((24, 12), title, font=font(22, mono=True), fill=INK)
    for index, path in enumerate(items):
        with Image.open(path) as opened:
            thumb = opened.convert("RGB")
            thumb.thumbnail((tile, tile), Image.LANCZOS)
        column = index % columns
        row = index // columns
        x = 24 + column * (tile + 24) + (tile - thumb.width) // 2
        y = 24 + row * (tile + 62) + (tile - thumb.height) // 2 + (36 if title else 0)
        sheet.paste(thumb, (x, y))
        draw.text((24 + column * (tile + 24), 24 + row * (tile + 62) + tile + 14 + (36 if title else 0)), path.name, font=label, fill=INK)
    write(sheet, target, alpha=False)


def panorama(images: Iterable[Path], target: Path, scale: float = 1.0) -> None:
    """One class's set side by side, so the signal line can be followed across the strip."""
    items = [path for path in images if path.exists()]
    if not items:
        return
    opened = []
    for path in items:
        with Image.open(path) as image:
            tile = image.convert("RGB")
        opened.append(tile.resize((max(1, round(tile.width * scale)), max(1, round(tile.height * scale))), Image.LANCZOS))
    strip = Image.new("RGB", (sum(tile.width for tile in opened), max(tile.height for tile in opened)), BLACK)
    x = 0
    for tile in opened:
        strip.paste(tile, (x, 0))
        x += tile.width
    write(strip, target, alpha=False)


def review(spec: Spec, repo: Path, directory: Path) -> None:
    """The artifacts to look at while judging a class: sheet, strip, thumbnails and the hero at full size."""
    images = [repo / spec.out / f"{shot}{spec.suffix}.png" for shot in SHOT_ORDER]
    present = [path for path in images if path.exists()]
    if not present:
        return
    directory.mkdir(parents=True, exist_ok=True)
    contact_sheet(present, directory / f"sheet-{spec.name}.png", columns=4, tile=360, title=f"{spec.name} — contact sheet")
    panorama(present, directory / f"strip-{spec.name}.png")
    thumbs = []
    for path in present:
        with Image.open(path) as image:
            thumb = image.convert("RGB")
            thumb.thumbnail((300, 4000), Image.LANCZOS)
        out = directory / f"thumb-{spec.name}-{path.name}"
        write(thumb, out, alpha=False)
        thumbs.append(out)
    contact_sheet(thumbs, directory / f"thumbs-{spec.name}.png", columns=8, tile=300, title=f"{spec.name} — thumbnail size")
    hero = present[0]
    with Image.open(hero) as image:
        write(image.convert("RGB"), directory / f"hero-{spec.name}.png", alpha=False)


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
    parser.add_argument("--review", help="write the review artifacts (sheets, strips, thumbnails, heroes) into a directory")
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
    if arguments.review:
        for name in arguments.only or sorted(SPECS):
            review(SPECS[name], repo, Path(arguments.review))


if __name__ == "__main__":
    main()
