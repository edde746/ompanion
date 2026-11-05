import { describe, expect, test } from "bun:test";
import { shortPath } from "./home_path";

describe("shortPath", () => {
  test("the machine's home directory becomes ~", () => {
    expect(shortPath("/home/me", "/home/me")).toBe("~");
    expect(shortPath("/home/me/app", "/home/me")).toBe("~/app");
    expect(shortPath("C:\\Users\\me\\app", "C:\\Users\\me")).toBe("~\\app");
    expect(shortPath("/home/meow/app", "/home/me")).toBe("/home/meow/app");
    expect(shortPath("/home/me/app", undefined)).toBe("/home/me/app");
    expect(shortPath("/home/me/app", "")).toBe("/home/me/app");
  });
});
