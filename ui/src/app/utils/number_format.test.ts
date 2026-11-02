// Port of test/utils/number_format_test.dart.
import { afterEach, beforeAll, beforeEach, describe, expect, test } from "bun:test";
import { loadLocale, setLocale } from "../i18n/i18n";
import { formatCount, formatFixed, formatPercent, formatUsd } from "./number_format";

test("English groups with commas and writes decimals, percentages and dollars as Dart and omp do", () => {
  expect(formatCount(128767)).toBe("128,767");
  expect(formatCount(-1234567)).toBe("-1,234,567");
  expect(formatFixed(1234.56, 1)).toBe("1234.6");
  expect(formatPercent(0.1234)).toBe("12.3%");
  expect(formatUsd(0.01234, 4)).toBe("$0.0123");
});

describe("in German", () => {
  beforeAll(() => loadLocale("de"));
  beforeEach(() => setLocale("de"));
  afterEach(() => setLocale("en"));

  test("groups with dots, writes decimals with a comma and puts a space before % and $", () => {
    expect(formatCount(128767)).toBe("128.767");
    expect(formatCount(-1234567)).toBe("-1.234.567");
    expect(formatFixed(1234.56, 1)).toBe("1234,6");
    expect(formatPercent(0.1234)).toBe("12,3 %");
    expect(formatUsd(0.01234, 4)).toBe("0,0123 $");
  });
});
