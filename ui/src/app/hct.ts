// HCT (hue, chroma, tone), the colour space Material 3 builds its schemes in: the parts of Google's
// material_color_utilities 0.13.0 (Apache License 2.0; hct/cam16.dart, hct/viewing_conditions.dart,
// hct/src/hct_solver.dart, utils/color_utils.dart) that a tonal palette's tones need, ported from the Dart the Flutter
// app ran so the page derives the same colours. Inside, a colour is a 0xRRGGBB number and a linear one an
// [r, g, b] of 0–100.

type Vector = readonly [number, number, number];
type Matrix = readonly [Vector, Vector, Vector];

const srgbToXyz: Matrix = [
  [0.41233895, 0.35762064, 0.18051042],
  [0.2126, 0.7152, 0.0722],
  [0.01932141, 0.11916382, 0.95034478],
];

const scaledDiscountFromLinrgb: Matrix = [
  [0.001200833568784504, 0.002389694492170889, 0.0002795742885861124],
  [0.0005891086651375999, 0.0029785502573438758, 0.0003270666104008398],
  [0.00010146692491640572, 0.0005364214359186694, 0.0032979401770712076],
];

const linrgbFromScaledDiscount: Matrix = [
  [1373.2198709594231, -1100.4251190754821, -7.278681089101213],
  [-271.815969077903, 559.6580465940733, -32.46047482791194],
  [1.9622899599665666, -57.173814538844006, 308.7233197812385],
];

const yFromLinrgb: Vector = [0.2126, 0.7152, 0.0722];

function multiply(row: Vector, matrix: Matrix): Vector {
  return [
    row[0] * matrix[0][0] + row[1] * matrix[0][1] + row[2] * matrix[0][2],
    row[0] * matrix[1][0] + row[1] * matrix[1][1] + row[2] * matrix[1][2],
    row[0] * matrix[2][0] + row[1] * matrix[2][1] + row[2] * matrix[2][2],
  ];
}

/** An sRGB channel, 0–255, as linear light, 0–100. */
function linearized(channel: number): number {
  const normalized = channel / 255;
  if (normalized <= 0.040449936) return (normalized / 12.92) * 100;
  return ((normalized + 0.055) / 1.055) ** 2.4 * 100;
}

/** Linear light, 0–100, as an sRGB channel, 0–255, not rounded. */
function trueDelinearized(linear: number): number {
  const normalized = linear / 100;
  const delinearized = normalized <= 0.0031308 ? normalized * 12.92 : 1.055 * normalized ** (1 / 2.4) - 0.055;
  return delinearized * 255;
}

function colorFromLinrgb(linrgb: Vector): number {
  const [r, g, b] = linrgb.map((linear) => Math.min(255, Math.max(0, Math.round(trueDelinearized(linear)))));
  return (r! << 16) | (g! << 8) | b!;
}

/** CIE L* (a tone) as relative luminance, 0–100. */
function yFromLstar(lstar: number): number {
  const ft = (lstar + 16) / 116;
  const ft3 = ft * ft * ft;
  return 100 * (ft3 > 216 / 24389 ? ft3 : (116 * ft - 16) / (24389 / 27));
}

/** ViewingConditions.standard: D65 white, a mid-grey background (L* 50), an average surround. */
const viewing = (() => {
  const [xW, yW, zW] = [95.047, 100, 108.883];
  const adaptingLuminance = ((200 / Math.PI) * yFromLstar(50)) / 100;
  const white: Vector = [
    xW * 0.401288 + yW * 0.650173 + zW * -0.051461,
    xW * -0.250268 + yW * 1.204414 + zW * 0.045854,
    xW * -0.002079 + yW * 0.048952 + zW * 0.953127,
  ];
  const surround = 2;
  const f = 0.8 + surround / 10;
  const amount = (f - 0.9) * 10;
  const c = (1 - amount) * 0.59 + amount * 0.69;
  const d = Math.min(1, Math.max(0, f * (1 - (1 / 3.6) * Math.exp((-adaptingLuminance - 42) / 92))));
  const rgbD = white.map((response) => d * (100 / response) + 1 - d);
  const k = 1 / (5 * adaptingLuminance + 1);
  const k4 = k * k * k * k;
  const k4F = 1 - k4;
  const fl = k4 * adaptingLuminance + 0.1 * k4F * k4F * (5 * adaptingLuminance) ** (1 / 3);
  const n = yFromLstar(50) / yW;
  const nbb = 0.725 / n ** 0.2;
  const [rA, gA, bA] = white.map((response, index) => {
    const factor = ((fl * rgbD[index]! * response) / 100) ** 0.42;
    return (400 * factor) / (factor + 27.13);
  });
  return {
    backgroundYToWhitePointY: n,
    aw: ((40 * rA! + 20 * gA! + bA!) / 20) * nbb,
    nbb,
    ncb: nbb,
    c,
    nC: f,
    rgbD,
    fl,
    z: 1.48 + Math.sqrt(n),
  };
})();

function chromaticAdaptation(component: number): number {
  const af = Math.abs(component) ** 0.42;
  return (Math.sign(component) * 400 * af) / (af + 27.13);
}

function inverseChromaticAdaptation(adapted: number): number {
  const adaptedAbs = Math.abs(adapted);
  const base = Math.max(0, (27.13 * adaptedAbs) / (400 - adaptedAbs));
  return Math.sign(adapted) * base ** (1 / 0.42);
}

/** CAM16's hue angle, in radians, of the adapted cone responses. */
function hueAngle(rA: number, gA: number, bA: number): number {
  const a = (11 * rA + -12 * gA + bA) / 11;
  const b = (rA + gA - 2 * bA) / 9;
  return Math.atan2(b, a);
}

/** The HCT hue, 0 to under 360 degrees, of `#RRGGBB` (Hct.fromInt(argb).hue: CAM16's under the standard conditions). */
export function hctHue(color: string): number {
  const value = Number.parseInt(color.slice(1), 16);
  const [x, y, z] = multiply(
    [linearized((value >> 16) & 0xff), linearized((value >> 8) & 0xff), linearized(value & 0xff)],
    srgbToXyz,
  );
  const [rA, gA, bA] = [
    0.401288 * x + 0.650173 * y - 0.051461 * z,
    -0.250268 * x + 1.204414 * y + 0.045854 * z,
    -0.002079 * x + 0.048952 * y + 0.953127 * z,
  ].map((cone, index) => {
    const discounted = viewing.rgbD[index]! * cone;
    return chromaticAdaptation((viewing.fl * discounted) / 100);
  });
  const degrees = (hueAngle(rA!, gA!, bA!) * 180) / Math.PI;
  return degrees < 0 ? degrees + 360 : degrees >= 360 ? degrees - 360 : degrees;
}

/** The sRGB colour of hue, chroma and tone straight from CAM16's inverse; undefined when it leaves the gamut. */
function findResultByJ(hueRadians: number, chroma: number, y: number): number | undefined {
  let j = Math.sqrt(y) * 11;
  const tInnerCoeff = 1 / (1.64 - 0.29 ** viewing.backgroundYToWhitePointY) ** 0.73;
  const eHue = 0.25 * (Math.cos(hueRadians + 2) + 3.8);
  const p1 = eHue * (50000 / 13) * viewing.nC * viewing.ncb;
  const hSin = Math.sin(hueRadians);
  const hCos = Math.cos(hueRadians);
  for (let round = 0; round < 5; round++) {
    const jNormalized = j / 100;
    const alpha = chroma === 0 || j === 0 ? 0 : chroma / Math.sqrt(jNormalized);
    const t = (alpha * tInnerCoeff) ** (1 / 0.9);
    const ac = viewing.aw * jNormalized ** (1 / viewing.c / viewing.z);
    const p2 = ac / viewing.nbb;
    const gamma = (23 * (p2 + 0.305) * t) / (23 * p1 + 11 * t * hCos + 108 * t * hSin);
    const a = gamma * hCos;
    const b = gamma * hSin;
    const rA = (460 * p2 + 451 * a + 288 * b) / 1403;
    const gA = (460 * p2 - 891 * a - 261 * b) / 1403;
    const bA = (460 * p2 - 220 * a - 6300 * b) / 1403;
    const linrgb = multiply(
      [inverseChromaticAdaptation(rA), inverseChromaticAdaptation(gA), inverseChromaticAdaptation(bA)],
      linrgbFromScaledDiscount,
    );
    if (linrgb[0] < 0 || linrgb[1] < 0 || linrgb[2] < 0) return undefined;
    const fnj = yFromLinrgb[0] * linrgb[0] + yFromLinrgb[1] * linrgb[1] + yFromLinrgb[2] * linrgb[2];
    if (fnj <= 0) return undefined;
    if (round === 4 || Math.abs(fnj - y) < 0.002) {
      if (linrgb[0] > 100.01 || linrgb[1] > 100.01 || linrgb[2] > 100.01) return undefined;
      return colorFromLinrgb(linrgb);
    }
    j = j - ((fnj - y) * j) / (2 * fnj);
  }
  return undefined;
}

function hueOfLinrgb(linrgb: Vector): number {
  const [r, g, b] = multiply(linrgb, scaledDiscountFromLinrgb);
  return hueAngle(chromaticAdaptation(r), chromaticAdaptation(g), chromaticAdaptation(b));
}

/** Whether going round the circle from angle `a` (radians) meets `b` before `c`. */
function areInCyclicOrder(a: number, b: number, c: number): boolean {
  return (b - a + Math.PI * 8) % (Math.PI * 2) < (c - a + Math.PI * 8) % (Math.PI * 2);
}

/** The nth of the twelve edges of the RGB cube where it crosses the plane of luminance `y`, if inside the cube. */
function nthVertex(y: number, n: number): Vector | undefined {
  const [kR, kG, kB] = yFromLinrgb;
  const coordA = n % 4 <= 1 ? 0 : 100;
  const coordB = n % 2 === 0 ? 0 : 100;
  if (n < 4) {
    const r = (y - coordA * kG - coordB * kB) / kR;
    return 0 <= r && r <= 100 ? [r, coordA, coordB] : undefined;
  }
  if (n < 8) {
    const g = (y - coordB * kR - coordA * kB) / kG;
    return 0 <= g && g <= 100 ? [coordB, g, coordA] : undefined;
  }
  const b = (y - coordA * kR - coordB * kG) / kB;
  return 0 <= b && b <= 100 ? [coordA, coordB, b] : undefined;
}

/** The two vertices of the luminance plane's polygon in the RGB cube whose hues bracket `targetHue`. */
function bisectToSegment(y: number, targetHue: number): [Vector, Vector] {
  let left: Vector = [-1, -1, -1];
  let right = left;
  let leftHue = 0;
  let rightHue = 0;
  let initialized = false;
  let uncut = true;
  for (let n = 0; n < 12; n++) {
    const mid = nthVertex(y, n);
    if (mid === undefined) continue;
    const midHue = hueOfLinrgb(mid);
    if (!initialized) {
      left = mid;
      right = mid;
      leftHue = midHue;
      rightHue = midHue;
      initialized = true;
      continue;
    }
    if (uncut || areInCyclicOrder(leftHue, midHue, rightHue)) {
      uncut = false;
      if (areInCyclicOrder(leftHue, targetHue, midHue)) {
        right = mid;
        rightHue = midHue;
      } else {
        left = mid;
        leftHue = midHue;
      }
    }
  }
  return [left, right];
}

/** The linear values halfway between neighbouring sRGB channel values: where a rounded channel changes. */
const criticalPlanes = Array.from({ length: 255 }, (_, index) => linearized(index + 0.5));

/** The most chromatic colour of `targetHue` at luminance `y` that sRGB holds, on the gamut's surface. */
function bisectToLimit(y: number, targetHue: number): Vector {
  let [left, right] = bisectToSegment(y, targetHue);
  let leftHue = hueOfLinrgb(left);
  for (let axis = 0; axis < 3; axis++) {
    const from = left[axis]!;
    const to = right[axis]!;
    if (from === to) continue;
    let lPlane = from < to ? Math.floor(trueDelinearized(from) - 0.5) : Math.ceil(trueDelinearized(from) - 0.5);
    let rPlane = from < to ? Math.ceil(trueDelinearized(to) - 0.5) : Math.floor(trueDelinearized(to) - 0.5);
    for (let step = 0; step < 8 && Math.abs(rPlane - lPlane) > 1; step++) {
      const mPlane = Math.floor((lPlane + rPlane) / 2);
      const source = left[axis]!;
      const t = (criticalPlanes[mPlane]! - source) / (right[axis]! - source);
      const mid: Vector = [
        left[0] + (right[0] - left[0]) * t,
        left[1] + (right[1] - left[1]) * t,
        left[2] + (right[2] - left[2]) * t,
      ];
      const midHue = hueOfLinrgb(mid);
      if (areInCyclicOrder(leftHue, targetHue, midHue)) {
        right = mid;
        rPlane = mPlane;
      } else {
        left = mid;
        leftHue = midHue;
        lPlane = mPlane;
      }
    }
  }
  return [(left[0] + right[0]) / 2, (left[1] + right[1]) / 2, (left[2] + right[2]) / 2];
}

/**
 * `#RRGGBB` of `hue` (degrees), `chroma` and `tone` (L*, 0–100), as Hct.from(hue, chroma, tone).toInt(): the exact
 * colour where sRGB holds it, else the most chromatic one of that hue and tone.
 */
export function hctColor(hue: number, chroma: number, tone: number): string {
  const y = yFromLstar(tone);
  let value: number;
  if (chroma < 0.0001 || tone < 0.0001 || tone > 99.9999) {
    const grey = Math.min(255, Math.max(0, Math.round(trueDelinearized(y))));
    value = (grey << 16) | (grey << 8) | grey;
  } else {
    let degrees = hue % 360;
    if (degrees < 0) degrees += 360;
    const hueRadians = (degrees / 180) * Math.PI;
    value = findResultByJ(hueRadians, chroma, y) ?? colorFromLinrgb(bisectToLimit(y, hueRadians));
  }
  return `#${value.toString(16).padStart(6, "0").toUpperCase()}`;
}
