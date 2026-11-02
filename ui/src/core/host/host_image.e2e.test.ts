import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { execFileSync, spawnSync } from "node:child_process";
import {
  chmodSync,
  existsSync,
  lstatSync,
  mkdirSync,
  mkdtempSync,
  readdirSync,
  readFileSync,
  rmSync,
  statSync,
  symlinkSync,
  truncateSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { localLink, useCore } from "../../test/core";
import { macArm } from "../../test/host_fixtures";
import { pngBytes, pngLookalike, tiffLookalike } from "../../test/host_images";
import { asJsonObject, type JsonObject } from "../rpc/json_fields";
import type { BridgeLink } from "../transport/bridge_link";
import type { HostFiles } from "../transport/host_link";
import {
  decodableImageType,
  fetchHostImage,
  ffmpegLocations,
  hostImageProblemCanLoadOriginal,
  parseImageReport,
  parseImageTools,
  parseVideoSize,
  planImage,
  posixImageScript,
  probeImageTools,
  windowsImageScript,
  windowsImageToolsScript,
  type HostImage,
  type HostImageBytes,
  type HostImageProblem,
  type ImageTools,
} from "./host_image";
import {
  encodePowerShell,
  newMarker,
  powershellPreamble,
  runPosixScript,
  scriptResultPayload,
  shQuote,
} from "./scripts";

useCore();

function which(command: string): string | undefined {
  const result = spawnSync("/bin/sh", ["-c", `command -v ${command}`], { encoding: "utf8" });
  return result.status === 0 ? result.stdout.trim() : undefined;
}

/** ffmpeg on this computer, found where [probeImageTools] looks: PATH, then [ffmpegLocations]. */
const ffmpeg = which("ffmpeg") ?? ffmpegLocations.find((path) => existsSync(path));

/** CI must run the ffmpeg tests: there a missing ffmpeg fails them instead of skipping them. */
const skipWithoutFfmpeg = ffmpeg === undefined && process.env.CI !== "true";

const pwsh = which("pwsh");

const root = process.getuid?.() === 0;

/** A directory of links to every command in the system directories except ffmpeg and ffprobe. */
function pathWithoutFfmpeg(temp: string): string {
  const bin = `${temp}/bin`;
  mkdirSync(bin);
  for (const dir of ["/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]) {
    if (!existsSync(dir)) continue;
    for (const name of readdirSync(dir)) {
      const link = `${bin}/${name}`;
      if (name === "ffmpeg" || name === "ffprobe" || lstatSync(link, { throwIfNoEntry: false })) continue;
      symlinkSync(`${dir}/${name}`, link);
    }
  }
  return bin;
}

/** Width and height of image [bytes], as ffmpeg reads them. */
function decodedSize(temp: string, bytes: Uint8Array): { width: number; height: number } | undefined {
  const file = `${temp}/decoded-${bytes.length}`;
  writeFileSync(file, bytes);
  const result = spawnSync(ffmpegPath(), ["-hide_banner", "-nostdin", "-i", file], { encoding: "utf8" });
  return parseVideoSize(result.stderr.split("\n").find((line) => line.includes(": Video: ")));
}

function ffmpegMake(output: string, source: string, extra: string[] = []): void {
  const result = spawnSync(
    ffmpegPath(),
    ["-hide_banner", "-nostdin", "-loglevel", "error", "-y", "-f", "lavfi", "-i", source, "-frames:v", "1", ...extra, output],
    { encoding: "utf8" },
  );
  if (result.status !== 0) throw new Error(`ffmpeg could not make ${output}: ${result.stderr}`);
}

function ffmpegPath(): string {
  if (ffmpeg === undefined) throw new Error("ffmpeg is required here: install it (CI installs it in the integration job)");
  return ffmpeg;
}

function imageBytes(image: HostImage): HostImageBytes {
  if (image.kind !== "HostImageBytes") throw new Error(`expected image bytes, got ${image.issue}`);
  return image;
}

function imageProblem(image: HostImage): HostImageProblem {
  if (image.kind !== "HostImageProblem") throw new Error("expected a problem, got image bytes");
  return image;
}

let temp: string;
let home: string;

beforeEach(() => {
  temp = mkdtempSync(join(tmpdir(), "host-image "));
  home = `${temp}/home`;
  mkdirSync(home);
});

afterEach(() => {
  execFileSync("chmod", ["-R", "u+rwx", temp]);
  rmSync(temp, { recursive: true, force: true });
});

/** What the image operation left in `~/.ompanion/tmp`. */
function leftovers(): string[] {
  const dir = `${home}/.ompanion/tmp`;
  return existsSync(dir) ? readdirSync(dir) : [];
}

/** A file's modification time as the image script reports it: whole seconds. */
function modifiedSeconds(path: string): number {
  return Math.floor(statSync(path).mtimeMs / 1000);
}

describe("without ffmpeg", () => {
  let link: BridgeLink;
  let files: HostFiles;
  let tools: ImageTools;

  beforeEach(async () => {
    link = localLink({ HOME: home, PATH: pathWithoutFfmpeg(temp) });
    files = await link.files();
    tools = await probeImageTools(link, macArm, { locations: [] });
  });

  afterEach(async () => {
    await files.close();
    await link.close();
  });

  const fetch = (path: string, original = false) => fetchHostImage(link, files, macArm, tools, path, { original });

  test("the machine has no ffmpeg when PATH lacks it", () => {
    expect(tools.ffmpeg).toBeUndefined();
  });

  test("a decodable image up to 8 MB arrives as it is; a larger one waits for the user, who may load it", async () => {
    const small = `${temp}/small.png`;
    writeFileSync(small, pngBytes(64, 48));
    const image = imageBytes(await fetch(small));
    expect(image.bytes).toEqual(new Uint8Array(readFileSync(small)));
    expect([image.mimeType, image.preview, image.size]).toEqual(["image/png", false, statSync(small).size]);
    expect(image.modifiedMs).toBe(modifiedSeconds(small) * 1000);

    const big = `${temp}/big.png`;
    writeFileSync(big, pngLookalike(9 << 20));
    const refused = imageProblem(await fetch(big));
    expect([refused.issue, refused.size, hostImageProblemCanLoadOriginal(refused)]).toEqual(["tooLarge", 9 << 20, true]);
    const original = imageBytes(await fetch(big, true));
    expect(original.bytes.length).toBe(9 << 20);
  });

  test("a file over 64 MB is refused, even on request", async () => {
    const huge = `${temp}/huge.png`;
    writeFileSync(huge, pngLookalike(64));
    truncateSync(huge, (64 << 20) + 2);
    for (const original of [false, true]) {
      const problem = imageProblem(await fetch(huge, original));
      expect([problem.issue, hostImageProblemCanLoadOriginal(problem)]).toEqual(["tooLarge", false]);
    }
  });

  test("files that are missing, folders, unreadable, not images or not decodable say which", async () => {
    writeFileSync(`${temp}/notes.txt`, "hello\n");
    writeFileSync(`${temp}/scan.tif`, tiffLookalike(5000));
    writeFileSync(`${temp}/locked.png`, pngBytes(4, 4));
    chmodSync(`${temp}/locked.png`, 0o000);
    const issues: Record<string, unknown> = {};
    for (const name of ["gone.png", ".", "notes.txt", "scan.tif", ...(root ? [] : ["locked.png"])]) {
      const image = await fetch(`${temp}/${name}`);
      issues[name] = image.kind === "HostImageProblem" ? [image.issue, image.size] : "bytes";
    }
    expect(issues).toEqual({
      "gone.png": ["missing", undefined],
      ".": ["notFile", undefined],
      "notes.txt": ["notImage", 6],
      "scan.tif": ["unsupported", 5000],
      ...(root ? {} : { "locked.png": ["denied", undefined] }),
    });
  });

  test("a path is data for the script: quotes, dollars and spaces run nothing", async () => {
    const file = `${temp}/it's $(touch pwned) \`touch pwned\` a.png`;
    writeFileSync(file, pngBytes(8, 8));
    const image = imageBytes(await fetch(file));
    expect(image.bytes).toEqual(new Uint8Array(readFileSync(file)));
    expect(existsSync(`${home}/pwned`) || existsSync(`${temp}/pwned`)).toBe(false);
  });

  test("an ffmpeg that hangs is killed after the time limit, and the original is sent instead", async () => {
    const pid = `${temp}/ffmpeg.pid`;
    const fake = `${temp}/bin/fake-ffmpeg`;
    writeFileSync(fake, `#!/bin/sh\necho $$ > ${shQuote(pid)}\nexec sleep 60\n`);
    chmodSync(fake, 0o755);
    const file = `${temp}/wide.png`;
    writeFileSync(file, pngLookalike(1 << 20));
    const marker = newMarker();
    const startedAt = performance.now();
    const result = await runPosixScript(link, posixImageScript(marker, file, { ffmpeg: fake, webp: false, seconds: 1 }));
    expect(performance.now() - startedAt).toBeLessThan(5000);
    const report = parseImageReport(scriptResultPayload(result, marker));
    expect(report.ffmpeg).toBe("timeout");
    const plan = planImage(report, file, { original: false });
    expect(plan.kind === "ImageRead" && [plan.path, plan.preview]).toEqual([file, false]);
    expect(leftovers()).toEqual([]);
    // The hung ffmpeg must be gone.
    expect(spawnSync("kill", ["-0", readFileSync(pid, "utf8").trim()]).status).not.toBe(0);
  });
});

describe.skipIf(skipWithoutFfmpeg)("with ffmpeg", () => {
  let link: BridgeLink;
  let files: HostFiles;
  let tools: ImageTools;

  beforeEach(async () => {
    ffmpegPath();
    link = localLink({ HOME: home });
    files = await link.files();
    tools = await probeImageTools(link, macArm);
  });

  afterEach(async () => {
    await files.close();
    await link.close();
  });

  const fetch = (path: string) => fetchHostImage(link, files, macArm, tools, path);

  test("the machine has ffmpeg", () => {
    expect(tools.ffmpeg).toBeDefined();
  });

  test("a large PNG arrives as a much smaller preview, at most 1600 px on its long side", async () => {
    const path = `${temp}/large.png`;
    ffmpegMake(path, "testsrc2=size=3000x2000");
    const size = statSync(path).size;
    const image = imageBytes(await fetch(path));
    expect(image.preview).toBe(true);
    expect(image.mimeType).toBe(tools.webp ? "image/webp" : "image/jpeg");
    expect(image.bytes.length).toBeLessThan(Math.floor(size / 4));
    expect([image.width, image.height, image.size]).toEqual([3000, 2000, size]);
    expect(decodedSize(temp, image.bytes)).toEqual({ width: 1600, height: 1067 });
    expect(leftovers()).toEqual([]);
  });

  test("a small image arrives as it is", async () => {
    const path = `${temp}/small.png`;
    ffmpegMake(path, "testsrc2=size=640x360");
    const image = imageBytes(await fetch(path));
    expect(image.preview).toBe(false);
    expect(image.bytes).toEqual(new Uint8Array(readFileSync(path)));
    expect(leftovers()).toEqual([]);
  });

  test("an image with transparent pixels keeps them, and a smaller one is not scaled up", async () => {
    const path = `${temp}/alpha.png`;
    ffmpegMake(path, "testsrc2=size=1200x900,format=rgba,colorchannelmixer=aa=0.5", ["-compression_level", "0"]);
    const image = imageBytes(await fetch(path));
    expect(image.preview).toBe(true);
    expect(image.mimeType).toBe(tools.webp ? "image/webp" : "image/png");
    expect(decodedSize(temp, image.bytes)).toEqual({ width: 1200, height: 900 });
    const preview = `${temp}/alpha-preview`;
    writeFileSync(preview, image.bytes);
    const info = spawnSync(ffmpegPath(), ["-hide_banner", "-nostdin", "-i", preview], { encoding: "utf8" });
    expect(info.stderr).toMatch(/Video: \w+.*, (rgba|yuva420p|argb)/);
  });

  test("an alpha channel that leaves every pixel opaque, as in screenshots, does not need a PNG", async () => {
    const path = `${temp}/screenshot.png`;
    ffmpegMake(path, "testsrc2=size=2880x1800,format=rgba");
    const image = imageBytes(await fetch(path));
    expect(image.mimeType).toBe(tools.webp ? "image/webp" : "image/jpeg");
    expect(decodedSize(temp, image.bytes)).toEqual({ width: 1600, height: 1000 });
  });

  test("a JPEG photo becomes a smaller preview", async () => {
    const path = `${temp}/photo.jpg`;
    ffmpegMake(path, "testsrc2=size=4000x3000", ["-q:v", "2"]);
    const size = statSync(path).size;
    const image = imageBytes(await fetch(path));
    expect(image.preview).toBe(true);
    expect(image.bytes.length).toBeLessThan(Math.floor(size / 4));
    expect(decodedSize(temp, image.bytes)).toEqual({ width: 1600, height: 1200 });
  });

  test("a TIFF, which the app cannot decode, arrives as a preview; text is no image", async () => {
    const tiff = `${temp}/scan.tiff`;
    ffmpegMake(tiff, "testsrc2=size=320x240");
    const image = imageBytes(await fetch(tiff));
    expect(image.preview).toBe(true);
    expect(decodedSize(temp, image.bytes)).toEqual({ width: 320, height: 240 });
    writeFileSync(`${temp}/notes.txt`, "hello\n".repeat(100));
    expect(imageProblem(await fetch(`${temp}/notes.txt`)).issue).toBe("notImage");
    expect(leftovers()).toEqual([]);
  });
});

describe.skipIf(pwsh === undefined)("Windows scripts with PowerShell 7", () => {
  function runPwsh(script: (marker: string) => string, environment: Record<string, string> = {}): JsonObject {
    const marker = newMarker();
    const result = spawnSync(
      pwsh ?? "pwsh",
      ["-NoProfile", "-NonInteractive", "-EncodedCommand", encodePowerShell(`${powershellPreamble}${script(marker)}`)],
      { encoding: "utf8", env: { ...process.env, HOME: home, ...environment } },
    );
    const begin = result.stdout.indexOf(`${marker}:begin\n`);
    if (begin < 0) throw new Error(`no payload: ${result.stdout} ${result.stderr}`);
    const payload = result.stdout.substring(begin + marker.length + 7, result.stdout.indexOf(`\n${marker}:end`));
    return asJsonObject(JSON.parse(payload), "payload");
  }

  test("the image script reports problems, size, time and first bytes", () => {
    const file = `${temp}/it's a.png`;
    writeFileSync(file, pngBytes(8, 8));
    const ok = runPwsh((m) => windowsImageScript(m, file, { ffmpeg: undefined, webp: false }));
    expect(ok["size"]).toBe(statSync(file).size);
    expect(ok["mtime"]).toBe(modifiedSeconds(file));
    expect(decodableImageType(String(ok["magic"]))).toBe("image/png");
    expect(runPwsh((m) => windowsImageScript(m, `${temp}/gone.png`, { ffmpeg: undefined, webp: false }))["problem"]).toBe(
      "missing",
    );
    expect(runPwsh((m) => windowsImageScript(m, temp, { ffmpeg: undefined, webp: false }))["problem"]).toBe("notFile");
    chmodSync(file, 0o000);
    if (!root) {
      expect(runPwsh((m) => windowsImageScript(m, file, { ffmpeg: undefined, webp: false }))["problem"]).toBe("denied");
    }
  });

  test.skipIf(skipWithoutFfmpeg)("with ffmpeg the image script makes a preview in ~/.ompanion/tmp", () => {
    const path = `${temp}/large.png`;
    ffmpegMake(path, "testsrc2=size=3000x2000");
    const tools = parseImageTools(
      JSON.stringify(runPwsh(windowsImageToolsScript, { PATH: `${dirname(ffmpegPath())}:/usr/bin:/bin` })),
    );
    expect(tools.ffmpeg).toBeDefined();
    const report = parseImageReport(
      JSON.stringify(runPwsh((m) => windowsImageScript(m, path, { ffmpeg: tools.ffmpeg, webp: tools.webp }))),
    );
    expect([report.ffmpeg, report.format]).toEqual(["ok", tools.webp ? "webp" : "jpeg"]);
    expect(parseVideoSize(report.stream)).toEqual({ width: 3000, height: 2000 });
    const preview = report.out ?? "";
    expect(dirname(preview)).toBe(`${home}/.ompanion/tmp`);
    expect(decodedSize(temp, new Uint8Array(readFileSync(preview)))).toEqual({ width: 1600, height: 1067 });
    writeFileSync(`${temp}/notes.txt`, "hello\n".repeat(100));
    const text = runPwsh((m) =>
      windowsImageScript(m, `${temp}/notes.txt`, { ffmpeg: tools.ffmpeg, webp: tools.webp }),
    );
    expect(text["ffmpeg"]).toBe("notImage");
    for (const [name, source, format] of [
      ["opaque.png", "testsrc2=size=2000x1000,format=rgba", "jpeg"],
      ["clear.png", "testsrc2=size=2000x1000,format=rgba,colorchannelmixer=aa=0.5", "png"],
    ] as const) {
      ffmpegMake(`${temp}/${name}`, source, ["-compression_level", "0"]);
      const json = runPwsh((m) => windowsImageScript(m, `${temp}/${name}`, { ffmpeg: tools.ffmpeg, webp: tools.webp }));
      expect(json["format"]).toBe(tools.webp ? "webp" : format);
    }
  });
});
