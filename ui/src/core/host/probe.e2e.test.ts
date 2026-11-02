// Port of the machine cases of packages/omp_core/test/host/probe_test.dart, run on this computer through the core.
import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { spawnSync } from "node:child_process";
import { existsSync } from "node:fs";
import { chmod, copyFile, mkdir, mkdtemp, rm, unlink, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { localLink, useCore } from "../../test/core";
import {
  hostProbeScratchDirs,
  parsePosixProbe,
  parseShellProbe,
  parseWindowsProbe,
  posixProbeScript,
  probeHost,
  shellProbeCommand,
  windowsProbeScript,
  type HostProbe,
} from "./probe";
import { encodePowerShell, newMarker, powershellPreamble, runPosixScript, scriptResultPayload } from "./scripts";

useCore();

/** A stand-in omp at [path] that prints `omp/<version>`. */
async function fakeOmp(path: string, version: string): Promise<string> {
  await mkdir(dirname(path), { recursive: true });
  await writeFile(path, `#!/bin/sh\necho "omp/${version}"\n`);
  await chmod(path, 0o755);
  return path;
}

describe("shell probe", () => {
  test("a POSIX shell prints the probe as expected", () => {
    const result = spawnSync("/bin/sh", ["-c", shellProbeCommand], { encoding: "utf8" });
    expect(parseShellProbe(result.stdout)).toBe("posix");
  });
});

describe("POSIX probe", () => {
  let home: string;

  beforeEach(async () => {
    home = await mkdtemp(join(tmpdir(), "probe home "));
    await fakeOmp(`${home}/.local/bin/omp`, "18.3.1");
  });

  afterEach(() => rm(home, { recursive: true }));

  async function probe(environment: Record<string, string>, searchSystemPaths = true): Promise<HostProbe> {
    const link = localLink({ HOME: home, PATH: "/usr/bin:/bin:/usr/sbin:/sbin", ...environment });
    try {
      return await probeHost(link, { searchSystemPaths });
    } finally {
      await link.close();
    }
  }

  test("finds omp outside PATH and reports this machine", async () => {
    const result = await probe({ PI_CODING_AGENT_DIR: "", OMP_PROFILE: "" });
    expect(result.commandShell).toBe("posix");
    expect(result.os).toBe(process.platform === "darwin" ? "macos" : "linux");
    expect(result.home).toBe(home);
    expect(result.agentDir).toBe(`${home}/.omp/agent`);
    expect(result.ompPath).toBe(`${home}/.local/bin/omp`);
    expect(result.ompVersion).toBe("18.3.1");
    expect(result.curl).toBe(existsSync("/usr/bin/curl"));
    if (process.platform === "darwin") expect(["arm64", "x64"]).toContain(result.arch);
  });

  test("honours PI_CODING_AGENT_DIR, and OMP_PROFILE over it", async () => {
    expect((await probe({ PI_CODING_AGENT_DIR: "/elsewhere/agent", OMP_PROFILE: "" })).agentDir).toBe(
      "/elsewhere/agent",
    );
    const profiled = await probe({ PI_CODING_AGENT_DIR: "/elsewhere/agent", OMP_PROFILE: "work" });
    expect(profiled.agentDir).toBe(`${home}/.omp/profiles/work/agent`);
    expect(profiled.profile).toBe("work");
  });

  test("reports omp's temporary directory: TMPDIR, TMP, TEMP, then /tmp, without a trailing slash", async () => {
    expect((await probe({ TMPDIR: "/var/folders/x/T/" })).tempDir).toBe("/var/folders/x/T");
    expect((await probe({ TMPDIR: "", TMP: "/scratch", TEMP: "/other" })).tempDir).toBe("/scratch");
    const fallback = await probe({ TMPDIR: "", TMP: "", TEMP: "" });
    expect(fallback.tempDir).toBe("/tmp");
    // omp tries ~/tmp, /tmp and /var/tmp before its temporary directory.
    expect(hostProbeScratchDirs(fallback)).toEqual([`${home}/tmp`, "/tmp", "/var/tmp", "/tmp"]);
  });

  test("an omp on PATH wins", async () => {
    await mkdir(`${home}/bin`);
    await copyFile(`${home}/.local/bin/omp`, `${home}/bin/omp`);
    await chmod(`${home}/bin/omp`, 0o755);
    const link = localLink({ HOME: home, PATH: `${home}/bin:/usr/bin:/bin` });
    try {
      expect((await probeHost(link)).ompPath).toBe(`${home}/bin/omp`);
    } finally {
      await link.close();
    }
  });

  test("an omp on PATH older than the minimum gives way to the one in the install directory", async () => {
    const old = await fakeOmp(`${home}/bin/omp`, "18.3.0");
    const result = await probe({ PATH: `${home}/bin:/usr/bin:/bin` });
    expect([result.ompPath, result.ompVersion]).toEqual([`${home}/.local/bin/omp`, "18.3.1"]);
    await unlink(`${home}/.local/bin/omp`);
    const only = await probe({ PATH: `${home}/bin:/usr/bin:/bin` }, false);
    // PATH is not searched.
    expect(only.ompPath).toBeUndefined();
    await fakeOmp(`${home}/.local/bin/omp`, "18.2.0");
    const none = await probe({ PATH: `${home}/bin:/usr/bin:/bin` });
    // No usable omp: the first one found is reported.
    expect([none.ompPath, none.ompVersion]).toEqual([old, "18.3.0"]);
  });

  test("without system paths omp is looked for only in the home directory", async () => {
    const system = await mkdtemp(join(tmpdir(), "probe system "));
    try {
      const onPath = await fakeOmp(`${system}/bin/omp`, "18.4.0");
      await fakeOmp(`${home}/.local/bin/omp`, "18.0.0");
      const environment = { PATH: `${system}/bin:/usr/bin:/bin` };
      expect((await probe(environment)).ompPath).toBe(onPath);
      const isolated = await probe(environment, false);
      expect([isolated.ompPath, isolated.ompVersion]).toEqual([`${home}/.local/bin/omp`, "18.0.0"]);
      await unlink(`${home}/.local/bin/omp`);
      const bun = await fakeOmp(`${home}/.bun/bin/omp`, "18.3.1");
      expect((await probe(environment, false)).ompPath).toBe(bun);
      await unlink(bun);
      // omp in /opt/homebrew/bin or /usr/local/bin, as on this computer, is never looked at either.
      expect((await probe(environment, false)).ompPath).toBeUndefined();
    } finally {
      await rm(system, { recursive: true });
    }
  });
});

describe("login shell PATH", () => {
  let temp: string;

  beforeEach(async () => {
    temp = await mkdtemp(join(tmpdir(), "probe login "));
  });

  afterEach(() => rm(temp, { recursive: true }));

  /** A stand-in login shell: the flags land in `$flags`, then [body] runs with the command to run as `$1`. */
  async function fakeShell(body: string): Promise<string> {
    const path = `${temp}/shell`;
    await writeFile(path, `#!/bin/sh\nflags=$*\nwhile [ $# -gt 1 ]; do shift; done\n${body}\n`);
    await chmod(path, 0o755);
    return path;
  }

  /**
   * Runs the real probe script with [shell] as the machine's login shell. [loginWait] is the probe's own budget in
   * tenths of a second, kept short so a hanging shell test stays fast.
   */
  async function run(shell: string, loginWait = 20): Promise<HostProbe> {
    const link = localLink({ HOME: temp, PATH: "/usr/bin:/bin", SHELL: shell });
    try {
      const marker = newMarker();
      const result = await runPosixScript(link, posixProbeScript(marker, { searchSystemPaths: false, loginWait }));
      return parsePosixProbe(scriptResultPayload(result, marker));
    } finally {
      await link.close();
    }
  }

  test("reads the PATH the login shell gives its children, past rc noise", async () => {
    const shell = await fakeShell(
      'echo "welcome to my shell"\n' +
        'printf "loading nvm..."\n' +
        "PATH=/opt/homebrew/bin:/home/me/.local/bin:/usr/bin\n" +
        "export PATH\n" +
        'eval "$1"\n' +
        'echo "prompt %"',
    );
    const probe = await run(shell);
    expect(probe.loginPath).toBe("/opt/homebrew/bin:/home/me/.local/bin:/usr/bin");
    expect(probe.loginProblem).toBeUndefined();
  });

  test("a shell that refuses -i still answers as a login shell", async () => {
    const shell = await fakeShell(
      'case $flags in *-i*) echo "illegal option -- i" >&2; exit 2;; esac\n' +
        "PATH=/from-login-shell:/usr/bin\n" +
        "export PATH\n" +
        'eval "$1"',
    );
    expect((await run(shell)).loginPath).toBe("/from-login-shell:/usr/bin");
  });

  test("a shell that answers nothing leaves the exec PATH and says why", async () => {
    const quiet = await run(await fakeShell(":"));
    expect(quiet.loginPath).toBeUndefined();
    expect(quiet.loginProblem).toBe("the login shell reported no PATH");
  });

  test("a shell that hangs is killed after the wait, and the probe returns", async () => {
    const started = Date.now();
    const stuck = await run(await fakeShell("while :; do sleep 0.1; done"), 2);
    expect(stuck.loginPath).toBeUndefined();
    expect(stuck.loginProblem).toBe("the login shell reported no PATH");
    expect(Date.now() - started).toBeLessThan(10_000);
  });

  test("an empty $SHELL falls back to the account login shell from passwd", async () => {
    const probe = await run("");
    expect(probe.loginPath).toContain("/usr/bin");
  });

  test("omp's standalone binary runs the app's scripts; a package's run on the bun the login shell finds", async () => {
    const omp = `${temp}/.local/bin/omp`;
    await mkdir(dirname(omp), { recursive: true });
    const install = async (body: string) => {
      await writeFile(omp, `#!/bin/sh\n${body}\n`);
      await chmod(omp, 0o755);
    };

    const bin = `${temp}/login bin`;
    await mkdir(bin);
    const bun = `${bin}/bun`;
    await writeFile(bun, "#!/bin/sh\n");
    await chmod(bun, 0o755);
    const shell = await fakeShell(`PATH="${bin}:/usr/bin"\nexport PATH\neval "$1"`);

    // The standalone binary is Bun once BUN_BE_BUN is set; a package's omp is a script that prints omp's version.
    await install('if [ -n "$BUN_BE_BUN" ]; then echo 1.4.3; else echo omp/18.3.1; fi');
    expect((await run(shell)).bunPath).toBe(omp);
    await install("echo omp/18.3.1");
    expect((await run(shell)).bunPath).toBe(bun);
    // No bun on the login PATH or the exec PATH.
    expect((await run(await fakeShell(":"))).bunPath).toBeUndefined();
  });
});

const pwsh = Bun.which("pwsh");

describe.skipIf(pwsh === null)("Windows probe script", () => {
  let temp: string;

  beforeEach(async () => {
    temp = await mkdtemp(join(tmpdir(), "windows probe "));
  });

  afterEach(() => rm(temp, { recursive: true }));

  function probe(options: {
    path: string;
    searchSystemPaths?: boolean;
    environment?: Record<string, string>;
  }): HostProbe {
    const marker = "OMPANION_test";
    const profile = `${temp}/Users/me`;
    const script = powershellPreamble + windowsProbeScript(marker, { searchSystemPaths: options.searchSystemPaths });
    const args = ["-NoProfile", "-NonInteractive", "-EncodedCommand", encodePowerShell(script)];
    const result = spawnSync(pwsh ?? "pwsh", args, {
      encoding: "utf8",
      env: {
        ...process.env,
        PATH: options.path,
        USERPROFILE: profile,
        LOCALAPPDATA: `${profile}/AppData/Local`,
        SystemRoot: `${temp}/Windows`,
        ProgramFiles: `${temp}/Program Files`,
        PI_INSTALL_DIR: "",
        ...options.environment,
      },
    });
    expect(result.status, result.stderr).toBe(0);
    return parseWindowsProbe(
      scriptResultPayload({ stdout: result.stdout, stderr: "", exit: { code: 0 } }, marker),
      "powershell",
    );
  }

  test("an omp on PATH older than the minimum gives way to the one in LOCALAPPDATA, and PATH can be left out", async () => {
    const bin = `${temp}/bin`;
    const onPath = await fakeOmp(`${bin}/omp.exe`, "18.3.0");
    const installed = await fakeOmp(`${temp}/Users/me/AppData/Local/omp/omp.exe`, "18.3.1");
    const path = `${bin}:/usr/bin:/bin`;
    const found = probe({ path });
    expect([found.ompPath, found.ompVersion]).toEqual([installed, "18.3.1"]);
    await unlink(installed);
    // No usable omp: the first one found is reported.
    expect(probe({ path }).ompPath).toBe(onPath);
    expect(probe({ path, searchSystemPaths: false }).ompPath).toBeUndefined();
  });

  test("the app's scripts run on omp's standalone binary, or for bun's omp.exe shim on the bun.exe beside it, else on PATH", async () => {
    const bin = `${temp}/bin`;
    const path = `${bin}:/usr/bin:/bin`;
    const omp = await fakeOmp(`${temp}/Users/me/.bun/bin/omp.exe`, "18.3.1");
    expect(probe({ path }).bunPath).toBe(omp);
    // `bun install -g` puts the shim's omp.bunx, which names the script it runs, beside omp.exe.
    await writeFile(`${temp}/Users/me/.bun/bin/omp.bunx`, "");
    expect(probe({ path }).bunPath).toBeUndefined();
    const onPath = await fakeOmp(`${bin}/bun.exe`, "0");
    expect(probe({ path }).bunPath).toBe(onPath);
    const beside = await fakeOmp(`${temp}/Users/me/.bun/bin/bun.exe`, "0");
    expect(probe({ path }).bunPath).toBe(beside);
  });

  test(String.raw`reports omp's temporary directory: TEMP, TMP, then SystemRoot\temp, a trailing backslash dropped`, () => {
    const tempDir = (environment: Record<string, string>) => probe({ path: "/usr/bin:/bin", environment }).tempDir;
    expect(tempDir({ TEMP: "C:\\Users\\me\\AppData\\Local\\Temp\\", TMP: String.raw`D:\tmp` })).toBe(
      String.raw`C:\Users\me\AppData\Local\Temp`,
    );
    // A drive's root keeps its backslash.
    expect(tempDir({ TEMP: "", TMP: "D:\\" })).toBe("D:\\");
    expect(tempDir({ TEMP: "", TMP: "" })).toBe(`${temp}/Windows\\temp`);
  });
});
