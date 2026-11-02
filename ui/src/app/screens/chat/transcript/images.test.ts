// Port of the logic cases of test/transcript/chat_images_test.dart: the session's images resolved and loaded as a
// MachineImage loads them (SessionImages over a fake machine), what the lines beside a machine image say, and the size
// read from an image's header; plus the header formats sniffImageSize reads. Skipped as markup: the fitted picture,
// the zoom viewer opening, "Open in Files" opening the path; the fling case needs a scrolling list (the view's
// `request`). The tool cards' cases are TrTools'.
import { afterEach, beforeEach, expect, test } from "bun:test";
import * as fs from "node:fs/promises";
import * as os from "node:os";
import * as path from "node:path";
import {
  type HostImageBytes,
  type HostImageProblem,
  hostImageProblemCanLoadOriginal,
} from "../../../../core/host/host_image";
import { base64Decode } from "../../../../core/util/base64";
import { FakeImageHost, nodeImageCacheDir } from "../../../../test/fake_image_host";
import { t } from "../../../i18n/i18n";
import { MachineImages, SessionImages } from "../../../sessions/machine_images";
import { formatBytes } from "../../../utils/byte_size";
import { imageCaption, imageName, imageProblemText, imageSize, sniffImageSize } from "./images";

const png = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=";
const modifiedMs = Date.UTC(2026, 8, 1);

function pngImage(fields: { preview?: boolean; size?: number } = {}): HostImageBytes {
  return {
    kind: "HostImageBytes",
    bytes: base64Decode(png),
    mimeType: "image/png",
    size: fields.size ?? 4 << 20,
    modifiedMs,
    preview: fields.preview ?? true,
    width: 3000,
    height: 2000,
  };
}

let temp: string;
let host: FakeImageHost;
let images: SessionImages;
const wanted = () => true;

beforeEach(async () => {
  temp = await fs.mkdtemp(path.join(os.tmpdir(), "chat images "));
  host = new FakeImageHost();
  images = new SessionImages(new MachineImages({ cacheDir: async () => nodeImageCacheDir(temp) }), host, {
    cwd: "/home/u/proj",
    sessionPath: "/home/u/.local/share/omp/sessions/-home-u-proj/s.jsonl",
  });
});

afterEach(() => fs.rm(temp, { recursive: true }));

test("machine images load on their own, with name, size and how much of it a preview sent", async () => {
  host.files.set("/home/u/proj/out/chart.png", { size: 4 << 20, modifiedMs });
  host.answers.set("/home/u/proj/out/chart.png", pngImage());
  expect(images.peek("out/chart.png")).toBeUndefined();
  expect(t.transcript.imageLoading({ name: imageName("out/chart.png") })).toBe("Loading chart.png…");

  const image = await images.load("out/chart.png", { wanted });
  expect(host.fetches).toEqual([["/home/u/proj/out/chart.png", false]]);
  expect(image.kind).toBe("HostImageBytes");
  expect(imageCaption("out/chart.png", image as HostImageBytes)).toBe(
    "chart.png · 3000×2000 · preview, 68 B of 4.0 MB",
  );
  expect(imageCaption("out/chart.png", pngImage({ preview: false }))).toBe("chart.png · 3000×2000");
});

test("a rebuilt transcript shows a loaded image at once, without fetching again", async () => {
  host.files.set("/home/u/proj/a.png", { size: 4 << 20, modifiedMs });
  host.answers.set("/home/u/proj/a.png", pngImage());
  const image = await images.load("a.png", { wanted });
  // A new MachineImage starts from what peek holds.
  expect(images.peek("a.png")).toBe(image);
  expect(await images.load("a.png", { wanted })).toBe(image);
  expect(host.fetches).toHaveLength(1);
});

test("a file too large to send on its own offers its original, loaded on request", async () => {
  host.files.set("/home/u/big.png", { size: 12 << 20, modifiedMs });
  host.answers.set("/home/u/big.png", { kind: "HostImageProblem", issue: "tooLarge", size: 12 << 20, modifiedMs });
  host.originals.set("/home/u/big.png", pngImage({ preview: false, size: 12 << 20 }));
  const problem = (await images.load("~/big.png", { wanted })) as HostImageProblem;
  expect(imageProblemText("~/big.png", problem)).toBe("~/big.png (12.0 MB) is too large to load on its own");
  expect(hostImageProblemCanLoadOriginal(problem)).toBe(true);
  expect(t.transcript.loadOriginal({ size: formatBytes(problem.size ?? 0) })).toBe("Load original (12.0 MB)");

  expect((await images.load("~/big.png", { original: true, wanted })).kind).toBe("HostImageBytes");
  expect(host.fetches).toEqual([
    ["/home/u/big.png", false],
    ["/home/u/big.png", true],
  ]);
});

test("missing and unreadable files say so", async () => {
  host.files.set("/secret.png", { size: 10, modifiedMs });
  host.answers.set("/secret.png", { kind: "HostImageProblem", issue: "denied" });
  const gone = (await images.load("gone.png", { wanted })) as HostImageProblem;
  const secret = (await images.load("/secret.png", { wanted })) as HostImageProblem;
  expect(imageProblemText("gone.png", gone)).toBe("Image not found: gone.png");
  expect(imageProblemText("/secret.png", secret)).toBe("No permission to read /secret.png");
});

test("an image omp keeps in its blob store loads from the blob beside the session file", async () => {
  const hash = "ab".repeat(32);
  const blob = `/home/u/.local/share/omp/blobs/${hash}`;
  host.files.set(blob, { size: 26672, modifiedMs });
  host.answers.set(blob, pngImage({ preview: false, size: 26672 }));
  expect((await images.loadBlob(hash, { wanted })).kind).toBe("HostImageBytes");
  expect(host.fetches).toEqual([[blob, false]]);
});

test("an image's name is its path's last segment, on any separator", () => {
  expect(imageName("C:\\shots\\a.png")).toBe("a.png");
  expect(imageName("out/dir/")).toBe("dir");
  expect(imageName("blob:sha256:ab")).toBe("blob:sha256:ab");
});

test("an inline image's size comes from its header", () => {
  expect(imageSize({ kind: "InlineImageBlock", data: png, mimeType: "image/png" })).toEqual({ width: 1, height: 1 });
});

/** `length` bytes with `bytes` written at `at`. */
function header(length: number, ...writes: [at: number, bytes: number[]][]): Uint8Array {
  const result = new Uint8Array(length);
  for (const [at, bytes] of writes) result.set(bytes, at);
  return result;
}

const riff = [0x52, 0x49, 0x46, 0x46, 0, 0, 0, 0, 0x57, 0x45, 0x42, 0x50];
const ascii = (text: string) => Array.from(text, (c) => c.charCodeAt(0));

test("sniffImageSize reads GIF, BMP, WebP and JPEG headers", () => {
  expect(sniffImageSize(header(10, [0, ascii("GIF89a")], [6, [0x40, 0x01, 0xf0, 0x00]]))).toEqual({
    width: 320,
    height: 240,
  });
  // A bottom-up BMP stores a negative height.
  expect(sniffImageSize(header(26, [0, ascii("BM")], [18, [0x20, 0, 0, 0]], [22, [0xf0, 0xff, 0xff, 0xff]]))).toEqual({
    width: 32,
    height: 16,
  });
  expect(sniffImageSize(header(30, [0, riff], [12, ascii("VP8 ")], [26, [0x80, 0x02, 0xe0, 0x01]]))).toEqual({
    width: 640,
    height: 480,
  });
  // VP8L: 14 bits of width − 1, then 14 bits of height − 1.
  const bits = (640 - 1) | ((480 - 1) << 14);
  const vp8l = [bits & 0xff, (bits >> 8) & 0xff, (bits >> 16) & 0xff, 0];
  expect(sniffImageSize(header(30, [0, riff], [12, ascii("VP8L")], [21, vp8l]))).toEqual({ width: 640, height: 480 });
  expect(sniffImageSize(header(30, [0, riff], [12, ascii("VP8X")], [24, [0x7f, 0x02, 0, 0xdf, 0x01, 0]]))).toEqual({
    width: 640,
    height: 480,
  });
  // A DHT segment comes before the start of frame and carries no size.
  const dht = [0xff, 0xc4, 0x00, 0x04, 0, 0];
  const frame = [0xff, 0xc0, 0x00, 0x11, 0x08, 0x01, 0xe0, 0x02, 0x80];
  expect(sniffImageSize(header(40, [0, [0xff, 0xd8]], [2, dht], [8, frame]))).toEqual({ width: 640, height: 480 });
});

test("sniffImageSize knows no size for other bytes", () => {
  expect(sniffImageSize(header(40, [0, ascii("II*")]))).toBeUndefined();
  expect(sniffImageSize(header(30, [0, riff], [12, ascii("ANIM")]))).toBeUndefined();
  expect(sniffImageSize(new Uint8Array(0))).toBeUndefined();
});
