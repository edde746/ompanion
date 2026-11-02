// Port of test/utils/token_count_test.dart.
import { afterEach, beforeAll, beforeEach, describe, expect, test } from "bun:test";
import { loadLocale, setLocale } from "../i18n/i18n";
import { formatTokens } from "./token_count";

test("whole values drop the decimal, others keep one, in K below a million, M below a billion, B from there", () => {
  const cases: readonly (readonly [number, string])[] = [
    [0, "0"],
    [999, "999"],
    [1000, "1K"],
    [1234, "1.2K"],
    [12345, "12.3K"],
    [128000, "128K"],
    [200000, "200K"],
    [128500, "128.5K"],
    [999949, "999.9K"],
    // Rounding up to 1000K reads as the next unit.
    [999960, "1M"],
    [1000000, "1M"],
    [1048576, "1M"],
    [1500000, "1.5M"],
    [2000000, "2M"],
    [10250000, "10.3M"],
    [999949999, "999.9M"],
    [999960000, "1B"],
    [17406968354, "17.4B"],
  ];
  for (const [tokens, text] of cases) expect(formatTokens(tokens), `${tokens} tokens`).toBe(text);
});

describe("in German", () => {
  beforeAll(() => loadLocale("de"));
  beforeEach(() => setLocale("de"));
  afterEach(() => setLocale("en"));

  test("the decimal is a comma", () => {
    expect([999, 1234, 128000, 128500, 1500000, 17406968354].map((tokens) => formatTokens(tokens))).toEqual([
      "999",
      "1,2K",
      "128K",
      "128,5K",
      "1,5M",
      "17,4B",
    ]);
  });
});
