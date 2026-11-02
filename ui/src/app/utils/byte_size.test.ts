// Port of test/utils/byte_size_test.dart.
import { afterEach, beforeAll, beforeEach, describe, expect, test } from "bun:test";
import { loadLocale, setLocale } from "../i18n/i18n";
import { formatBytes } from "./byte_size";

const sizes = [512, 4300, 89088, 12897484, 2362232013];

test("steps of 1024, one decimal except from 10 KB to 1 MB", () => {
  expect(sizes.map((bytes) => formatBytes(bytes))).toEqual(["512 B", "4.2 KB", "87 KB", "12.3 MB", "2.2 GB"]);
});

describe("in German", () => {
  beforeAll(() => loadLocale("de"));
  beforeEach(() => setLocale("de"));
  afterEach(() => setLocale("en"));

  test("the decimal is a comma", () => {
    expect(sizes.map((bytes) => formatBytes(bytes))).toEqual(["512 B", "4,2 KB", "87 KB", "12,3 MB", "2,2 GB"]);
  });
});
