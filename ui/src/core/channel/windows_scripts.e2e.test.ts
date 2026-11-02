// The Windows scripts that need a machine through the core, with PowerShell 7 standing in for `powershell.exe`.
import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import { pwsh } from "../../test/channel";
import { localLink, useCore } from "../../test/core";
import {
  encodedPowerShellCommand,
  powershellPreamble,
  runPowerShell,
  shQuote,
  windowsCommandLineLimit,
} from "../host/scripts";
import type { BridgeLink } from "../transport/bridge_link";
import type { HostFiles, HostLink, HostProcess, HostSocket, PtyRequest } from "../transport/host_link";

useCore();

/** A machine whose login shell is [shell]: it parses every exec command, as sshd's `$SHELL -c` does. */
class LoginShellLink implements HostLink {
  constructor(
    private readonly local: BridgeLink,
    private readonly shell: string,
  ) {}

  get label(): string {
    return this.local.label;
  }

  exec(command: string, options?: { pty?: PtyRequest }): Promise<HostProcess> {
    return this.local.exec(`exec ${this.shell} -c ${shQuote(command)}`, options);
  }

  files(): Promise<HostFiles> {
    return this.local.files();
  }

  connect(host: string, port: number): Promise<HostSocket> {
    return this.local.connect(host, port);
  }

  get done(): Promise<void> {
    return this.local.done;
  }

  close(): Promise<void> {
    return this.local.close();
  }
}

describe.skipIf(pwsh === undefined)("with PowerShell 7", () => {
  let temp: string;

  beforeEach(() => {
    temp = fs.mkdtempSync(path.join(os.tmpdir(), "windows scripts "));
  });

  afterEach(() => fs.rmSync(temp, { recursive: true, force: true }));

  test("a script too long for one command line runs from a file whose path never reaches a POSIX login shell", async () => {
    // csh stands in for login shells that misread sh quoting (fish, csh): a newline inside '…' is an error there.
    const home = `${temp}/home\nwith a newline`;
    fs.mkdirSync(home);
    const bin = `${temp}/bin`;
    fs.mkdirSync(bin);
    fs.symlinkSync(pwsh!, `${bin}/powershell.exe`);
    const link = new LoginShellLink(localLink({ HOME: home, PATH: `${bin}:/usr/bin:/bin` }), "/bin/csh");
    try {
      const script = `# ${"x".repeat(windowsCommandLineLimit)}\n[Console]::Out.Write('ran')`;
      expect(encodedPowerShellCommand("posix", `${powershellPreamble}${script}`)).toBeNull();
      const result = await runPowerShell(link, "posix", script);
      expect(result.exit.code, result.stderr).toBe(0);
      expect(result.stdout).toBe("ran");
      // The uploaded script is removed.
      expect(fs.readdirSync(`${home}/.ompanion/tmp`)).toEqual([]);
    } finally {
      await link.close();
    }
  });
});
