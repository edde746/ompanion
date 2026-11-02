// Port of test/utils/compact_duration_test.dart; the Dart Durations are milliseconds here.
import { afterEach, beforeAll, beforeEach, describe, expect, test } from "bun:test";
import { loadLocale, setLocale } from "../i18n/i18n";
import { compactDuration } from "./compact_duration";

// 1 h 30 min, 2 h, 4 min 30 s, 44.1 s.
const durationsMs = [5_400_000, 7_200_000, 270_000, 44_100];

test("omp's loop time: two units at most, whole seconds rounded up", () => {
  expect(durationsMs.map((durationMs) => compactDuration(durationMs))).toEqual(["1h30m", "2h", "4m30s", "45s"]);
});

describe("in German", () => {
  beforeAll(() => loadLocale("de"));
  beforeEach(() => setLocale("de"));
  afterEach(() => setLocale("en"));

  test("the units are spaced SI symbols", () => {
    expect(durationsMs.map((durationMs) => compactDuration(durationMs))).toEqual([
      "1 h 30 min",
      "2 h",
      "4 min 30 s",
      "45 s",
    ]);
  });
});
