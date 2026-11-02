import { describe, expect, test } from "bun:test";
import { cubic, Curves, curveFrames, flipped, interval, threePointCubic } from "./motion";

describe("curves", () => {
  test("a cubic matches CSS's cubic-bezier at the same control points", () => {
    // CSS `ease` at 0.5 is 0.8024; Flutter solves x to 0.001, so the value is that close.
    expect(Curves.ease(0.5)).toBeCloseTo(0.8024, 2);
    expect(cubic(0.42, 0, 0.58, 1)(0.5)).toBeCloseTo(0.5, 2);
    expect(Curves.fastOutSlowIn(0)).toBe(0);
    expect(Curves.fastOutSlowIn(1)).toBe(1);
  });

  test("a three-point cubic passes through its midpoint and joins both halves there", () => {
    const curve = threePointCubic([0.05, 0], [0.133333, 0.06], [0.166666, 0.4], [0.208333, 0.82], [0.25, 1]);
    expect(curve(0.166666)).toBeCloseTo(0.4, 6);
    expect(curve(0.166)).toBeCloseTo(0.4, 1);
    expect(curve(0.167)).toBeCloseTo(0.4, 1);
    // Emphasized motion covers most of its way by half time.
    expect(curve(0.5)).toBeGreaterThan(0.9);
    expect(curve(1)).toBe(1);
  });

  test("the three-point curves rise without going back", () => {
    for (const curve of [Curves.fastEaseInToSlowEaseOut, Curves.easeInOutCubicEmphasized]) {
      let last = 0;
      for (let step = 1; step <= 100; step++) {
        const value = curve(step / 100);
        expect(value).toBeGreaterThanOrEqual(last - 0.002);
        last = value;
      }
    }
  });

  test("an interval holds 0 before and 1 after its span", () => {
    const curve = interval(0.4, 0.6);
    expect(curve(0.2)).toBe(0);
    expect(curve(0.5)).toBeCloseTo(0.5, 6);
    expect(curve(0.8)).toBe(1);
  });

  test("a flipped curve mirrors the original", () => {
    const curve = flipped(Curves.easeIn);
    expect(curve(0.3)).toBeCloseTo(1 - Curves.easeIn(0.7), 6);
  });
});

test("curve frames sample the curve at even offsets", () => {
  const frames = curveFrames(Curves.easeOut, (value) => ({ opacity: value }), 4);
  expect(frames.map((frame) => frame.offset)).toEqual([0, 0.25, 0.5, 0.75, 1]);
  expect(frames[2]?.opacity).toBe(Curves.easeOut(0.5));
  expect(frames[4]?.opacity).toBe(1);
});
