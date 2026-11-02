// Port of the pure cases of packages/omp_core/test/host/probe_test.dart; the rest are in probe.e2e.test.ts.
import { describe, expect, test } from "bun:test";
import { FormatException } from "../rpc/json_fields";
import {
  hostProbeFromJson,
  hostProbeReleaseAsset,
  hostProbeScratchDirs,
  hostProbeToJson,
  parsePosixProbe,
  parseShellProbe,
  parseWindowsProbe,
} from "./probe";

describe("shell probe", () => {
  test("tells cmd.exe, PowerShell and POSIX shells apart, including a POSIX shell on Windows", () => {
    expect(parseShellProbe('"OMPANION_SHELL.Windows_NT.$env:OS.$OS."\r\n')).toBe("cmd");
    expect(parseShellProbe("OMPANION_SHELL.%OS%.Windows_NT..\r\n")).toBe("powershell");
    expect(parseShellProbe("motd\nOMPANION_SHELL.%OS%.:OS..\n")).toBe("posix");
    expect(parseShellProbe("OMPANION_SHELL.%OS%.:OS.Windows_NT.\n")).toBe("posix");
    // csh fails on the unset variable and prints nothing.
    expect(parseShellProbe("")).toBe("posix");
  });
});

test("POSIX probe payloads map to release assets", () => {
  const parse = (fields: Record<string, unknown>) =>
    parsePosixProbe(JSON.stringify({ v: "1", home: "/home/u", agentDir: "/home/u/.omp/agent", omps: [], ...fields }));
  expect(hostProbeReleaseAsset(parse({ kernel: "Linux", machine: "aarch64", libc: "musl" }))).toBe(
    "omp-linux-musl-arm64",
  );
  expect(hostProbeReleaseAsset(parse({ kernel: "Linux", machine: "x86_64", libc: "glibc" }))).toBe("omp-linux-x64");
  // uname -m under Rosetta says x86_64.
  expect(hostProbeReleaseAsset(parse({ kernel: "Darwin", machine: "x86_64", arm64: "1" }))).toBe("omp-darwin-arm64");
  expect(hostProbeReleaseAsset(parse({ kernel: "Linux", machine: "riscv64", libc: "glibc" }))).toBeUndefined();
  expect(parse({ kernel: "MINGW64_NT-10.0-26100", machine: "x86_64" }).os).toBe("windows");
  expect(() => parse({ kernel: "Linux", home: "" })).toThrow(FormatException);
});

test("the probe drives the first omp found that is new enough, else reports the first one", () => {
  const pick = (omps: [string, string][]) => {
    const probe = parsePosixProbe(
      JSON.stringify({
        v: "1",
        kernel: "Linux",
        home: "/home/u",
        agentDir: "/home/u/.omp/agent",
        omps: omps.map(([path, version]) => ({ path, version })),
      }),
    );
    return [probe.ompPath, probe.ompVersion];
  };

  expect(
    pick([
      ["/usr/bin/omp", "omp/18.3.1"],
      ["/home/u/.local/bin/omp", "omp/19.0.0"],
    ]),
  ).toEqual(["/usr/bin/omp", "18.3.1"]);
  expect(
    pick([
      ["/usr/bin/omp", "omp/18.3.0"],
      ["/home/u/.local/bin/omp", "omp/18.3.1"],
    ]),
  ).toEqual(["/home/u/.local/bin/omp", "18.3.1"]);
  expect(
    pick([
      ["/usr/bin/omp", "omp/18.3.1-rc.1"],
      ["/home/u/.local/bin/omp", "omp/18.3.1"],
    ]),
  ).toEqual(["/home/u/.local/bin/omp", "18.3.1"]);
  expect(
    pick([
      ["/usr/bin/omp", ""],
      ["/home/u/.local/bin/omp", "omp/18.0.0"],
    ]),
  ).toEqual(["/usr/bin/omp", undefined]);
  expect(pick([])).toEqual([undefined, undefined]);
});

test("Windows probe payloads parse, WOW64 architecture included", () => {
  const probe = parseWindowsProbe(
    String.raw`{"v":"1","kernel":"Windows_NT","machine":"AMD64","shell":null,"home":"C:\\Users\\Jos\u00e9",` +
      String.raw`"agentDir":"C:\\Users\\Jos\u00e9\\.omp\\agent","profile":null,` +
      String.raw`"omps":[{"path":"C:\\Program Files\\omp\\omp.exe","version":null},{"path":"C:\\Users\\Jos\u00e9\\.bun\\bin\\omp.exe","version":"omp/18.3.1","bun":"C:\\Users\\Jos\u00e9\\.bun\\bin\\bun.exe"}],` +
      String.raw`"curl":"1","powershell":"5.1.26100.1","localAppData":"C:\\Users\\Jos\u00e9\\AppData\\Local","sshd":"9.5.0.0",` +
      String.raw`"tempDir":"C:\\Users\\Jos\u00e9\\AppData\\Local\\Temp"}`,
    "cmd",
  );
  expect(probe.os).toBe("windows");
  expect(probe.arch).toBe("x64");
  // Plain strings: Bun's transpiler writes a non-ASCII character in a template as a \u escape, which String.raw keeps.
  expect(probe.home).toBe("C:\\Users\\José");
  expect([probe.ompPath, probe.ompVersion, probe.bunPath]).toEqual([
    "C:\\Users\\José\\.bun\\bin\\omp.exe",
    "18.3.1",
    "C:\\Users\\José\\.bun\\bin\\bun.exe",
  ]);
  expect(hostProbeReleaseAsset(probe)).toBe("omp-windows-x64.exe");
  expect(probe.powershellVersion).toBe("5.1.26100.1");
  // omp on Windows tries only ~\tmp before its temporary directory.
  expect(hostProbeScratchDirs(probe)).toEqual(["C:\\Users\\José\\tmp", "C:\\Users\\José\\AppData\\Local\\Temp"]);
  expect(hostProbeToJson(hostProbeFromJson(hostProbeToJson(probe)))).toEqual(hostProbeToJson(probe));
});
