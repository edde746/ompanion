import { describe, expect, test } from "bun:test";
import {
  decodableImageType,
  hostImageProblemCanLoadOriginal,
  hostImageReport,
  isOtherImage,
  parseImageReport,
  parseImageTools,
  parseVideoSize,
  planImage,
  type FfmpegOutcome,
  type HostImageIssue,
  type HostImageReport,
} from "./host_image";

const png = "89504e470d0a1a0a0000000d49484452";
const jpeg = "ffd8ffe000104a464946000101000001";
const tiff = "49492a0008000000";
const text = "68656c6c6f0a";

function report(
  fields: {
    size?: number;
    magic?: string;
    ffmpeg?: FfmpegOutcome;
    out?: string;
    format?: string;
    outSize?: number;
    error?: string;
  } = {},
): HostImageReport {
  return hostImageReport({ size: 1000, magic: png, modifiedMs: Date.UTC(2026, 8, 26), ...fields });
}

/** The file [planImage] reads for [report], with its type and whether it is the preview; or the problem. */
function plan(input: HostImageReport, options: { original?: boolean } = {}): unknown[] {
  const result = planImage(input, "/p/a.png", { original: options.original ?? false });
  if (result.kind === "ImageRead") return [result.path, result.mimeType, result.preview];
  return [result.problem.issue, result.problem.size, hostImageProblemCanLoadOriginal(result.problem)];
}

test("the image report keeps the problem the script found, or the file and what ffmpeg made of it", () => {
  expect(parseImageReport('{"problem":"denied"}').problem).toBe("denied");
  const parsed = parseImageReport(
    `{"size":615000,"mtime":1790400000,"magic":"${png}","demux":"png_pipe",` +
      '"stream":"Stream #0:0: Video: png, rgb24(pc, gbr/unknown/unknown), 3000x2000 [SAR 1:1 DAR 3:2], 25 fps",' +
      '"ffmpeg":"ok","out":"/home/u/.ompanion/tmp/img-X.webp","format":"webp","outSize":41000}',
  );
  expect(parsed.problem).toBeUndefined();
  expect(parsed.size).toBe(615000);
  expect(parsed.modifiedMs).toBe(Date.UTC(2026, 8, 26, 5, 20));
  expect(parsed.ffmpeg).toBe("ok");
  expect(parsed.out).toBe("/home/u/.ompanion/tmp/img-X.webp");
  expect(parsed.outSize).toBe(41000);
  expect(parseVideoSize(parsed.stream)).toEqual({ width: 3000, height: 2000 });
  const bare = parseImageReport('{"size":5,"mtime":0,"magic":"","demux":"","stream":"","ffmpeg":"notImage"}');
  expect([bare.ffmpeg, bare.stream, bare.out]).toEqual(["notImage", undefined, undefined]);
});

test("stream sizes skip codec tags that look like sizes", () => {
  expect(
    parseVideoSize("Stream #0:0: Video: h264 (High) (avc1 / 0x31637661), yuv420p(tv, bt709), 1920x1080 [SAR 1:1]"),
  ).toEqual({ width: 1920, height: 1080 });
  expect(parseVideoSize("Stream #0:0: Video: gif, bgra, 320x240, 25 fps")).toEqual({ width: 320, height: 240 });
  expect(parseVideoSize(undefined)).toBeUndefined();
});

test("image types come from the first bytes, not the name", () => {
  expect(decodableImageType(png)).toBe("image/png");
  expect(decodableImageType(jpeg)).toBe("image/jpeg");
  expect(decodableImageType("474946383961")).toBe("image/gif");
  expect(decodableImageType("524946462400000057454250565038")).toBe("image/webp");
  // A RIFF that is not WebP (AVI).
  expect(decodableImageType("524946462400000041564920")).toBeUndefined();
  expect(decodableImageType("424d36000000")).toBe("image/bmp");
  expect(decodableImageType(tiff)).toBeUndefined();
  expect(isOtherImage(tiff)).toBe(true);
  // HEIC.
  expect(isOtherImage("0000001c667479706865696300000000")).toBe(true);
  // An MP4 video.
  expect(isOtherImage("0000001c667479706d70343200000000")).toBe(false);
  // SVG.
  expect(isOtherImage("3c737667")).toBe(true);
  expect(isOtherImage(text)).toBe(false);
});

describe("planImage", () => {
  test("a preview is read when it is smaller than the file", () => {
    const input = report({ size: 600000, ffmpeg: "ok", out: "/t/img.webp", format: "webp", outSize: 40000 });
    expect(plan(input)).toEqual(["/t/img.webp", "image/webp", true]);
  });

  test("a preview no smaller than a decodable file loses to the file", () => {
    const input = report({ size: 300000, ffmpeg: "ok", out: "/t/img.jpeg", format: "jpeg", outSize: 310000 });
    expect(plan(input)).toEqual(["/p/a.png", "image/png", false]);
  });

  test("a preview of a file too large to send as it is wins even when it is larger", () => {
    const input = report({ size: 9 << 20, ffmpeg: "ok", out: "/t/img.png", format: "png", outSize: 10 << 20 });
    expect(plan(input)).toEqual(["/t/img.png", "image/png", true]);
  });

  test("a preview of a format this app cannot decode wins", () => {
    const input = report({
      magic: tiff,
      size: 90000,
      ffmpeg: "ok",
      out: "/t/img.jpeg",
      format: "jpeg",
      outSize: 95000,
    });
    expect(plan(input)).toEqual(["/t/img.jpeg", "image/jpeg", true]);
  });

  test("without a preview a decodable file up to 8 MB is sent, a larger one waits for the user", () => {
    expect(plan(report({ size: 8 << 20 }))).toEqual(["/p/a.png", "image/png", false]);
    expect(plan(report({ size: (8 << 20) + 1 }))).toEqual(["tooLarge", (8 << 20) + 1, true]);
    expect(plan(report({ size: 3 << 20, ffmpeg: "timeout" }))).toEqual(["/p/a.png", "image/png", false]);
  });

  test("the original on request is read up to 64 MB", () => {
    expect(plan(report({ size: 12 << 20 }), { original: true })).toEqual(["/p/a.png", "image/png", false]);
    expect(plan(report({ size: (64 << 20) + 1 }), { original: true })).toEqual(["tooLarge", (64 << 20) + 1, false]);
    expect(plan(report({ magic: tiff }), { original: true })).toEqual(["unsupported", 1000, false]);
  });

  test("files over 64 MB are refused before anything else", () => {
    const input = report({ size: 65 << 20, ffmpeg: "ok", out: "/t/img.webp", format: "webp", outSize: 1 });
    expect(plan(input)).toEqual(["tooLarge", 65 << 20, false]);
  });

  test("files that are no image say so; images this app cannot show say unsupported", () => {
    expect(plan(report({ magic: text }))).toEqual(["notImage", 1000, false]);
    expect(plan(report({ magic: text, ffmpeg: "notImage" }))).toEqual(["notImage", 1000, false]);
    expect(plan(report({ magic: tiff }))).toEqual(["unsupported", 1000, false]);
    expect(plan(report({ magic: "3c737667", ffmpeg: "notImage" }))).toEqual(["unsupported", 1000, false]);
    const failed = planImage(report({ magic: tiff, ffmpeg: "failed", error: "Invalid data" }), "/p/a.tif", {
      original: false,
    });
    expect(failed.kind === "ImageRefused" && failed.problem.detail).toBe("Invalid data");
  });

  test("problems the script found pass through", () => {
    for (const issue of ["missing", "notFile", "denied"] satisfies HostImageIssue[]) {
      expect(plan(hostImageReport({ problem: issue }))).toEqual([issue, undefined, false]);
    }
  });
});

test("image tools parse an empty path as no ffmpeg", () => {
  const none = parseImageTools('{"ffmpeg":"","webp":""}');
  expect([none.ffmpeg, none.webp]).toEqual([undefined, false]);
  const found = parseImageTools(String.raw`{"ffmpeg":"C:\\ffmpeg\\bin\\ffmpeg.exe","webp":"1"}`);
  expect([found.ffmpeg, found.webp]).toEqual([String.raw`C:\ffmpeg\bin\ffmpeg.exe`, true]);
});
