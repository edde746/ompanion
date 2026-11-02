// The colour picker's maths (lib/screens/settings/color_picker.dart): Flutter's HSVColor for opaque `#RRGGBB` colours,
// where a drag in the saturation/value area or on the hue track lands, and what the hex field applies.
import { parseColorHex } from "../../palette";

/** Flutter's `HSVColor` without alpha: `hue` in degrees (0–360), `saturation` and `value` from 0 to 1. */
export interface Hsv {
  readonly hue: number;
  readonly saturation: number;
  readonly value: number;
}

/** `HSVColor.fromColor`: a grey, black and white get hue 0. */
export function hsvFromHex(color: string): Hsv {
  const rgb = Number.parseInt(color.slice(1), 16);
  const red = ((rgb >> 16) & 0xff) / 0xff;
  const green = ((rgb >> 8) & 0xff) / 0xff;
  const blue = (rgb & 0xff) / 0xff;
  const max = Math.max(red, green, blue);
  const delta = max - Math.min(red, green, blue);
  let hue = 0;
  if (delta > 0) {
    // Dart's `%` is never negative; JavaScript's keeps the dividend's sign.
    if (max === red) hue = 60 * ((((green - blue) / delta) % 6) + (green < blue ? 6 : 0));
    else if (max === green) hue = 60 * ((blue - red) / delta + 2);
    else hue = 60 * ((red - green) / delta + 4);
  }
  return { hue, saturation: max === 0 ? 0 : delta / max, value: max };
}

/** `HSVColor.toColor` as `#RRGGBB`, upper case. */
export function hsvToHex(hsv: Hsv): string {
  const chroma = hsv.saturation * hsv.value;
  const secondary = chroma * (1 - Math.abs(((hsv.hue / 60) % 2) - 1));
  const match = hsv.value - chroma;
  const [red, green, blue] =
    hsv.hue < 60
      ? [chroma, secondary, 0]
      : hsv.hue < 120
        ? [secondary, chroma, 0]
        : hsv.hue < 180
          ? [0, chroma, secondary]
          : hsv.hue < 240
            ? [0, secondary, chroma]
            : hsv.hue < 300
              ? [secondary, 0, chroma]
              : [chroma, 0, secondary];
  const channel = (value: number) =>
    Math.round((value + match) * 0xff)
      .toString(16)
      .padStart(2, "0");
  return `#${channel(red)}${channel(green)}${channel(blue)}`.toUpperCase();
}

/** The fully saturated, full-value colour of `hue`: the area's right edge and the hue handle. */
export function hueHex(hue: number): string {
  return hsvToHex({ hue, saturation: 1, value: 1 });
}

/**
 * The picker's colour once `color` comes in from outside (a reset, a hex applied). A grey or black has no hue of its
 * own, so the track keeps the one dragged to; `hsv` is unchanged while it already shows `color`.
 */
export function followColor(hsv: Hsv | undefined, color: string): Hsv {
  if (hsv !== undefined && hsvToHex(hsv) === color) return hsv;
  const next = hsvFromHex(color);
  if (hsv !== undefined && (next.saturation === 0 || next.value === 0)) return { ...next, hue: hsv.hue };
  return next;
}

function clamp01(value: number): number {
  return Math.min(Math.max(value, 0), 1);
}

/**
 * The colour at `x`, `y` (px from the top left) in a saturation/value area `width` × `height`: saturation grows to the
 * right, value to the top, the hue stays. A point outside lands on the nearest edge.
 */
export function pickInArea(hsv: Hsv, x: number, y: number, width: number, height: number): Hsv {
  return { hue: hsv.hue, saturation: clamp01(x / width), value: 1 - clamp01(y / height) };
}

/** The colour at `x` px on a hue track `width` wide, 0° at its left end and 360° at its right. */
export function pickOnHueTrack(hsv: Hsv, x: number, width: number): Hsv {
  return { ...hsv, hue: clamp01(x / width) * 360 };
}

/**
 * What the hex field applies on Enter or when it loses focus: the colour its six hex digits name, with or without `#`.
 * Undefined for anything else and for `current` itself; the field then shows `current` again.
 */
export function hexFieldColor(text: string, current: string): string | undefined {
  const color = parseColorHex(text);
  return color === null || color === current ? undefined : color;
}

/** What the hex field keeps of typed text: hex digits and `#`, at most seven characters. */
export function hexFieldText(text: string): string {
  return text.replace(/[^#0-9a-fA-F]/g, "").slice(0, 7);
}
