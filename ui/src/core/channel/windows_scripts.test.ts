// The Windows host scripts: their sizes, and with PowerShell 7 (when installed) what they do.
import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import { pwsh } from "../../test/channel";
import { expectFixtureSessions, writeSessionFixtures } from "../../test/host_fixtures";
import { windowsInstallCommand } from "../host/install";
import { hostProbe, hostProbeReleaseAsset, parseWindowsProbe, windowsProbeScript } from "../host/probe";
import {
  encodedPowerShellCommand,
  encodePowerShell,
  newMarker,
  powershellPreamble,
  type ScriptResult,
  scriptResultPayload,
} from "../host/scripts";
import { parseSessionList, windowsSessionListScript } from "../host/session_listing";
import { delay, withTimeout } from "../util/async";
import { windowsAppenderScript } from "./windows_channel";
import { windowsArg, windowsFeedScript } from "./windows_run";

function runPwsh(script: string, environment: Record<string, string>): ScriptResult {
  const result = Bun.spawnSync(
    [pwsh!, "-NoProfile", "-NonInteractive", "-EncodedCommand", encodePowerShell(`${powershellPreamble}${script}`)],
    { env: { ...process.env, ...environment } },
  );
  return { stdout: result.stdout.toString(), stderr: result.stderr.toString(), exit: { code: result.exitCode } };
}

test("Windows arguments are quoted for CommandLineToArgvW and refused when cmd.exe would misread them", () => {
  expect(windowsArg("--mode")).toBe("--mode");
  expect(windowsArg("fake/fake-1")).toBe("fake/fake-1");
  expect(windowsArg(String.raw`C:\Users\José\a b.jsonl`)).toBe(String.raw`"C:\Users\José\a b.jsonl"`);
  // A trailing backslash would escape the closing quote.
  expect(windowsArg("C:\\dir\\")).toBe('"C:\\dir\\\\"');
  expect(windowsArg("a&b")).toBe('"a&b"');
  expect(windowsArg("")).toBe('""');
  expect(() => windowsArg('say "hi"')).toThrow(RangeError);
});

test("the Windows probe fits on one cmd.exe line, so first contact needs no SFTP", () => {
  expect(encodedPowerShellCommand("cmd", `${powershellPreamble}${windowsProbeScript(newMarker())}`)).not.toBeNull();
});

test("the in.jsonl appender fits on one cmd.exe line, so it can keep stdin for the lines", () => {
  const dir = `C:\\Users\\${"é".repeat(200)}\\.ompanion\\run\\20260926T121807-195ca655`;
  expect(encodedPowerShellCommand("cmd", `${powershellPreamble}${windowsAppenderScript(dir)}`)).not.toBeNull();
});

// pwsh's first starts on a CI runner have taken over 15 s: each test gets 30 s.
describe.skipIf(pwsh === undefined)("with PowerShell 7", () => {
  let temp: string;

  beforeEach(() => {
    temp = fs.mkdtempSync(path.join(os.tmpdir(), "windows scripts "));
  });

  afterEach(() => fs.rmSync(temp, { recursive: true, force: true }));

  test("feed.ps1 copies in.jsonl byte for byte and exits once the stop file exists", async () => {
    const run = temp;
    fs.writeFileSync(`${run}/feed.ps1`, windowsFeedScript);
    const input = `${run}/in.jsonl`;
    fs.writeFileSync(input, '{"id":"1"}\n');
    const feed = Bun.spawn([pwsh!, "-NoProfile", "-NonInteractive", "-File", `${run}/feed.ps1`], {
      env: { ...process.env, OMPANION_RUN: run },
      stdout: "pipe",
      stderr: "pipe",
    });
    const copied = new Response(feed.stdout).arrayBuffer();
    const errors = new Response(feed.stderr).text();
    await delay(500);
    fs.appendFileSync(input, '{"t":"é ✓"}\r\n');
    fs.appendFileSync(input, `${JSON.stringify({ big: "x".repeat(200000) })}\n`);
    await delay(300);
    fs.writeFileSync(`${run}/in.jsonl.stop`, "");
    const code = await withTimeout(feed.exited, 25_000);
    expect(code, await errors).toBe(0);
    expect(new Uint8Array(await copied)).toEqual(new Uint8Array(fs.readFileSync(input)));
  }, 30_000);

  test("the session listing script finds what the POSIX one finds", async () => {
    const home = `${temp}/home`;
    await writeSessionFixtures(home, temp);
    const marker = "OMPANION_test";
    const result = runPwsh(windowsSessionListScript(marker, [`${temp}/session dir`]), {
      USERPROFILE: home,
      PI_CODING_AGENT_DIR: `${temp}/custom agent`,
      PI_CONFIG_DIR: "",
    });
    expect(result.exit.code, result.stderr).toBe(0);
    expectFixtureSessions(parseSessionList(scriptResultPayload(result, marker)), `${home}/.omp/agent/sessions`);
  }, 30_000);

  test("the probe script reads the architecture under WOW64 and finds omp in LOCALAPPDATA", () => {
    const profile = `${temp}/Users/José`;
    const local = `${profile}/AppData/Local`;
    const omp = `${local}/omp/omp.exe`;
    fs.mkdirSync(path.dirname(omp), { recursive: true });
    fs.writeFileSync(omp, '#!/bin/sh\necho "omp/18.3.1"\n');
    fs.chmodSync(omp, 0o755);
    const marker = "OMPANION_test";
    const result = runPwsh(windowsProbeScript(marker), {
      USERPROFILE: profile,
      LOCALAPPDATA: local,
      PROCESSOR_ARCHITECTURE: "x86",
      PROCESSOR_ARCHITEW6432: "ARM64",
      SystemRoot: `${temp}/Windows`,
      ProgramFiles: `${temp}/Program Files`,
      PI_CODING_AGENT_DIR: "",
      OMP_PROFILE: "",
      PI_PROFILE: "",
      PI_CONFIG_DIR: "",
      PI_INSTALL_DIR: "",
    });
    expect(result.exit.code, result.stderr).toBe(0);
    const probe = parseWindowsProbe(scriptResultPayload(result, marker), "powershell");
    expect(probe.arch).toBe("arm64");
    expect(probe.home).toBe(profile);
    expect(probe.ompPath).toBe(omp);
    expect(probe.ompVersion).toBe("18.3.1");
    expect(hostProbeReleaseAsset(probe)).toBe("omp-windows-arm64.exe");
    expect(probe.shell).toBeUndefined();
  }, 30_000);

  test("the install script refuses a tampered download and removes it, also pasted without the preamble", async () => {
    const server = Bun.serve({ hostname: "127.0.0.1", port: 0, fetch: () => new Response("not omp") });
    try {
      const windows = hostProbe({
        commandShell: "powershell",
        os: "windows",
        kernel: "Windows_NT",
        arch: "x64",
        home: "/unused",
        agentDir: "/unused",
      });
      const dir = `${temp}/omp`;
      const script = windowsInstallCommand(windows, "18.3.1", {
        installDir: dir,
        assetBase: `http://127.0.0.1:${server.port}/`,
      });
      const result = Bun.spawn([pwsh!, "-NoProfile", "-NonInteractive", "-Command", script], {
        stdout: "ignore",
        stderr: "pipe",
      });
      const stderr = await new Response(result.stderr).text();
      expect(await result.exited).not.toBe(0);
      expect(stderr).toContain("SHA-256 mismatch");
      expect(fs.readdirSync(dir)).toEqual([]);
    } finally {
      await server.stop(true);
    }
  }, 30_000);
});
