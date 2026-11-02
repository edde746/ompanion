// Port of packages/omp_core/test/windows/windows_host_test.dart: the host operations the app runs on a Windows machine,
// against this computer's Win32-OpenSSH (cmd.exe as the default shell, sftp-server for files): probe, exec, PowerShell
// scripts, the download install, the file browser's SFTP operations, image previews and attachment uploads. Runs only
// where the CI Windows host job set this computer up (src/test/windows_host.ts).
import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import * as fs from "node:fs";
import { Cleanups } from "../../test/cleanups";
import { useCore } from "../../test/core";
import { pngBytes } from "../../test/host_images";
import { ompAsset, testedOmpVersion } from "../../test/omp";
import { connectWindows, windowsHostConfigured } from "../../test/windows_host";
import type { SshLink } from "../ssh/ssh_link";
import { HostFileExists, type HostFiles } from "../transport/host_link";
import { fetchHostImage, type HostImage, type HostImageBytes, imageKeepBytes, probeImageTools } from "./host_image";
import { windowsInstallCommand } from "./install";
import { type HostProbe, hostProbeReleaseAsset, probeHost } from "./probe";
import {
  encodedPowerShellCommand,
  hostPath,
  powershellPreamble,
  runCommand,
  runPowerShell,
  toSftpPath,
  windowsCommandLineLimit,
} from "./scripts";
import { savePaste, uploadAttachment } from "./upload";

function imageBytes(image: HostImage): HostImageBytes {
  if (image.kind !== "HostImageBytes") throw new Error(`expected image bytes, got ${image.issue}`);
  return image;
}

describe.skipIf(!windowsHostConfigured)("this Windows computer over its own sshd", () => {
  let link: SshLink;
  let files: HostFiles;
  let probe: HostProbe;
  let scratch: string;
  let dir: string;
  const cleanups = new Cleanups();
  const encoder = new TextEncoder();
  const decoder = new TextDecoder();

  afterAll(() => cleanups.run());

  // Hooks run in the order they are registered: this file's cleanup before the core stops, its setup after the core
  // started (the SSH connection goes through the core).
  useCore();

  beforeAll(async () => {
    link = await connectWindows();
    cleanups.add(() => link.close());
    probe = await probeHost(link);
    files = await link.files();
    cleanups.add(() => files.close());
    scratch = `${process.env.USERPROFILE}\\ompanion host test`;
    fs.mkdirSync(scratch, { recursive: true });
    cleanups.add(() => fs.rmSync(scratch, { recursive: true, force: true }));
    dir = toSftpPath(scratch);
  });

  test("the probe reads the machine through cmd.exe and Windows PowerShell", () => {
    expect(probe.os).toBe("windows");
    expect(probe.commandShell).toBe("cmd");
    expect(probe.shell, "no OpenSSH DefaultShell is set").toBeUndefined();
    expect(probe.arch).toBe("x64");
    expect(probe.home).toBe(process.env.USERPROFILE!);
    expect(probe.localAppData).toBe(process.env.LOCALAPPDATA!);
    expect(hostProbeReleaseAsset(probe)).toBe("omp-windows-x64.exe");
    expect(probe.powershellVersion).toStartWith("5.1");
  });

  test("exec runs cmd.exe commands, and a script too long for one command line runs from an uploaded file", async () => {
    const echo = await runCommand(link, "echo %OS%");
    expect([echo.exit.code, echo.stdout.trim()]).toEqual([0, "Windows_NT"]);
    const script = `# ${"x".repeat(windowsCommandLineLimit)}\n[Console]::Out.Write('ran é')`;
    expect(encodedPowerShellCommand(probe.commandShell, `${powershellPreamble}${script}`)).toBeNull();
    const long = await runPowerShell(link, probe.commandShell, script);
    expect([long.exit.code, long.stdout], long.stderr).toEqual([0, "ran é"]);
    expect(await files.list(`${toSftpPath(probe.home)}/.ompanion/tmp`), "the uploaded script is removed").toEqual([]);
  });

  test("the download install checks the release asset, installs it, and refuses a tampered one", async () => {
    const server = Bun.serve({
      hostname: "127.0.0.1",
      port: 0,
      fetch: (request) => {
        const segments = new URL(request.url).pathname.split("/");
        return segments[1] === "release" ? new Response(Bun.file(ompAsset(segments.at(-1)!))) : new Response("not omp");
      },
    });
    try {
      const origin = `http://127.0.0.1:${server.port}`;

      const good = `${scratch}\\omp good`;
      const installed = await runPowerShell(
        link,
        probe.commandShell,
        windowsInstallCommand(probe, testedOmpVersion, { installDir: good, assetBase: `${origin}/release/` }),
      );
      expect(installed.exit.code, installed.stderr).toBe(0);
      expect(fs.readdirSync(good)).toEqual(["omp.exe"]);
      const version = Bun.spawn([`${good}\\omp.exe`, "--version"], { stdout: "pipe" });
      expect((await new Response(version.stdout).text()).trim()).toBe(`omp/${testedOmpVersion}`);

      const bad = `${scratch}\\omp bad`;
      const refused = await runPowerShell(
        link,
        probe.commandShell,
        windowsInstallCommand(probe, testedOmpVersion, { installDir: bad, assetBase: `${origin}/tampered/` }),
      );
      expect(refused.exit.code).not.toBe(0);
      expect(refused.stderr).toContain("SHA-256 mismatch");
      expect(fs.readdirSync(bad)).toEqual([]);
    } finally {
      await server.stop(true);
    }
  }, 300_000);

  test("the file browser operations work on drive-letter SFTP paths", async () => {
    const folder = `${dir}/folder é`;
    await files.mkdir(folder);
    await expect(files.mkdir(folder)).rejects.toBeInstanceOf(HostFileExists);
    await files.write(`${folder}/a.txt`, encoder.encode("hello world"));
    await files.write(`${folder}/a.txt`, encoder.encode("hi"), { append: true });
    expect(decoder.decode(await files.read(`${folder}/a.txt`))).toBe("hello worldhi");
    expect(decoder.decode(await files.read(`${folder}/a.txt`, { offset: 6, length: 5 }))).toBe("world");
    await files.write(`${folder}/a.txt`, encoder.encode("new"));
    expect(decoder.decode(await files.read(`${folder}/a.txt`)), "a plain write truncates").toBe("new");
    const stat = (await files.stat(`${folder}/a.txt`))!;
    expect([stat.size, stat.isDirectory]).toEqual([3, false]);
    expect((await files.stat(folder))!.isDirectory).toBe(true);
    expect(await files.stat(`${folder}/none`)).toBeNull();
    await files.rename(`${folder}/a.txt`, `${folder}/b.txt`);
    expect((await files.list(folder)).map((entry) => entry.name)).toEqual(["b.txt"]);
    await files.remove(`${folder}/b.txt`);
    await files.removeDir(folder);
    expect(await files.stat(folder)).toBeNull();
    expect(hostPath(await files.home()).toLowerCase()).toBe(probe.home.toLowerCase());
  });

  test("attachments of several 4 MiB chunks arrive whole, a second one of that name beside it", async () => {
    const bytes = new Uint8Array(9 << 20);
    for (let i = 0; i < bytes.length; i++) bytes[i] = (i * 7) % 251;
    const chunks: Uint8Array[] = [];
    for (let i = 0; i < bytes.length; i += 65536) chunks.push(bytes.subarray(i, i + 65536));
    const progress: number[] = [];
    const target = `${dir}/sessions/s1/local`;
    const first = await uploadAttachment(files, {
      dir: target,
      name: "build log.txt",
      bytes: chunks,
      onProgress: (written) => progress.push(written),
    });
    const second = await uploadAttachment(files, { dir: target, name: "build log.txt", bytes: [encoder.encode("b")] });
    expect([first, second]).toEqual([`${target}/build log.txt`, `${target}/build log-2.txt`]);
    expect(progress).toEqual([4 << 20, 8 << 20, 9 << 20]);
    expect(fs.readFileSync(hostPath(first)).equals(bytes), "the first upload's bytes").toBe(true);
    expect(fs.readFileSync(hostPath(second), "utf8")).toBe("b");
    expect(await savePaste(files, { dir: target, text: "line\n".repeat(1000) })).toBe("paste-1.md");
  });

  test("images: originals within the limits, ffmpeg previews beyond them, problems named", async () => {
    const tools = await probeImageTools(link, probe);
    expect(tools.ffmpeg, "the CI job installs ffmpeg").toBeDefined();
    const fetchImage = (name: string, original = false) =>
      fetchHostImage(link, files, probe, tools, `${scratch}\\${name}`, { original });

    const small = pngBytes(64, 48);
    fs.writeFileSync(`${scratch}\\small.png`, small);
    const image = imageBytes(await fetchImage("small.png"));
    expect(image.bytes).toEqual(small);
    expect([image.mimeType, image.preview]).toEqual(["image/png", false]);

    fs.writeFileSync(`${scratch}\\big.png`, pngBytes(2000, 1600, { noise: true }));
    const preview = imageBytes(await fetchImage("big.png"));
    expect([preview.preview, preview.mimeType, preview.width, preview.height]).toEqual([
      true,
      tools.webp ? "image/webp" : "image/jpeg",
      2000,
      1600,
    ]);
    expect(preview.bytes.length, "a preview, not the 9.6 MB original").toBeLessThan(imageKeepBytes * 8);
    expect(await files.list(`${toSftpPath(probe.home)}/.ompanion/tmp`), "the preview file is removed").toEqual([]);
    expect(imageBytes(await fetchImage("big.png", true)).bytes.length).toBe(fs.statSync(`${scratch}\\big.png`).size);

    fs.writeFileSync(`${scratch}\\notes.txt`, "hello\n");
    fs.mkdirSync(`${scratch}\\folder.png`);
    const issues: string[] = [];
    for (const name of ["gone.png", "folder.png"]) {
      const fetched = await fetchImage(name);
      issues.push(fetched.kind === "HostImageProblem" ? fetched.issue : "bytes");
    }
    expect(issues).toEqual(["missing", "notFile"]);
    expect((await fetchImage("notes.txt")).kind).toBe("HostImageProblem");
  });
});
