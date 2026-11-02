// Port of the input, output, clipboard and remote shell launch cases of test/dock/terminal_io_test.dart.
import { describe, expect, test } from "bun:test";
import {
  encodeTerminalBinary,
  encodeTerminalInput,
  osc52ClipboardText,
  posixTerminalCommand,
  remoteShellLaunch,
  TerminalOutputDecoder,
  TerminalReadyFilter,
} from "./shell_launch";

const ascii = (text: string) => new TextEncoder().encode(text);
const text = (bytes: Uint8Array) => new TextDecoder().decode(bytes);

describe("clipboard", () => {
  test("a program cannot read the clipboard through OSC 52", () => {
    // `cat` of a hostile file, or a compromised machine, asking for the clipboard of this device.
    expect(osc52ClipboardText("c;?")).toBeUndefined();
    expect(osc52ClipboardText(";?")).toBeUndefined();
  });

  test("a program can write it, as a remote editor's yank does", () => {
    expect(osc52ClipboardText(`c;${btoa("yanked line")}`)).toBe("yanked line");
    expect(osc52ClipboardText(`;${btoa(String.fromCharCode(...new TextEncoder().encode("grüß")))}`)).toBe("grüß");
    expect(osc52ClipboardText("c;not base64!")).toBeUndefined();
    expect(osc52ClipboardText("no separator")).toBeUndefined();
  });
});

describe("input", () => {
  test("keystrokes, control characters and pastes are UTF-8 bytes", () => {
    expect([...encodeTerminalInput("ls\r")]).toEqual([0x6c, 0x73, 0x0d]);
    expect([...encodeTerminalInput("\x03")]).toEqual([0x03]);
    expect([...encodeTerminalInput("\x1b[A")]).toEqual([0x1b, 0x5b, 0x41]);
    expect(encodeTerminalInput("é🙂")).toEqual(new TextEncoder().encode("é🙂"));
  });

  test("binary input (X10 mouse reports) is one byte per character", () => {
    expect([...encodeTerminalBinary("\x1b[M \xff\x80")]).toEqual([0x1b, 0x5b, 0x4d, 0x20, 0xff, 0x80]);
  });
});

describe("output", () => {
  test("a character split across chunks comes out whole", () => {
    const shown: string[] = [];
    const decoder = new TerminalOutputDecoder((chunk) => shown.push(chunk));
    for (const byte of ascii("a🙂b")) decoder.add(Uint8Array.of(byte));
    decoder.close();
    expect(shown.join("")).toBe("a🙂b");
    expect(shown.some((chunk) => chunk.includes("\ufffd"))).toBe(false);
  });

  test("invalid bytes become replacement characters instead of ending the stream", () => {
    const shown: string[] = [];
    const decoder = new TerminalOutputDecoder((chunk) => shown.push(chunk));
    decoder.add(Uint8Array.of(0x61, 0xff, 0x62));
    decoder.add(ascii("ok"));
    decoder.add(Uint8Array.of(0xe2, 0x82));
    decoder.close();
    expect(shown.join("")).toBe("a\ufffdbok\ufffd");
  });

  test("a byte order mark the program wrote is kept", () => {
    const shown: string[] = [];
    const decoder = new TerminalOutputDecoder((chunk) => shown.push(chunk));
    decoder.add(Uint8Array.of(0xef, 0xbb, 0xbf, 0x61));
    expect(shown.join("")).toBe("\ufeffa");
  });
});

describe("remote shell launch", () => {
  test("POSIX: the login shell parses a fixed command; the directory follows on stdin", () => {
    // fish reads \' inside single quotes as an escaped quote, so no sh quoting of the name is safe there.
    const cwd = "/home/omp/it\\'s;touch pwned;#";
    const launch = remoteShellLaunch({ commandShell: "posix", shell: "/usr/bin/fish", cwd });
    expect(launch.command).toBe(posixTerminalCommand);
    expect(launch.startLine).toBe(`${cwd}\n`);
    expect(remoteShellLaunch({ commandShell: "posix", shell: undefined, cwd: undefined }).startLine).toBe("\n");
    // The rest of the name would reach the login shell as typed input.
    expect(remoteShellLaunch({ commandShell: "posix", shell: undefined, cwd: "/tmp/a\nrm -rf ~" }).startLine).toBe("\n");
  });

  test("the POSIX command is the Dart app's, byte for byte", () => {
    expect(posixTerminalCommand).toBe(
      `sh -c 's=$(stty -g); stty raw -echo; echo OMPANION_TERMINAL_READY; IFS= read -r d; stty "$s"; ` +
        `[ -z "$d" ] || cd "$d"; exec "\${SHELL:-/bin/sh}" -l'`,
    );
  });

  test("Windows: cmd.exe or the PowerShell default shell, in the session directory", () => {
    expect(remoteShellLaunch({ commandShell: "cmd", shell: undefined, cwd: "C:\\Users\\omp\\proj" })).toEqual({
      command: 'cd /d "C:\\Users\\omp\\proj" & cmd.exe',
      startLine: undefined,
    });
    expect(
      remoteShellLaunch({
        commandShell: "powershell",
        shell: "C:\\Program Files\\PowerShell\\7\\pwsh.exe",
        cwd: "C:\\Users\\o'brien",
      }),
    ).toEqual({
      command: "Set-Location -LiteralPath 'C:\\Users\\o''brien'; & 'C:\\Program Files\\PowerShell\\7\\pwsh.exe' -NoLogo",
      startLine: undefined,
    });
    expect(remoteShellLaunch({ commandShell: "powershell", shell: " ", cwd: undefined }).command).toBe(
      "& 'powershell.exe' -NoLogo",
    );
  });

  test("the ready line is taken out of the output, even split across chunks", () => {
    const filter = new TerminalReadyFilter();
    expect(filter.add(ascii("motd\r\nOMPANION_TERMINAL")).length).toBe(0);
    expect(filter.add(ascii("_READY")).length).toBe(0);
    expect(filter.ready).toBe(false);
    expect(text(filter.add(ascii("\n$ ")))).toBe("motd\r\n$ ");
    expect(filter.ready).toBe(true);
    expect(text(filter.add(ascii("OMPANION_TERMINAL_READY\n")))).toBe("OMPANION_TERMINAL_READY\n");

    // A shell tracing the command prints the marker mid-line first; only the line itself counts.
    const traced = new TerminalReadyFilter();
    expect(traced.add(ascii("+ echo OMPANION_TERMINAL_READY; IFS= read\r\nOMPANION_TERMINAL_READY\r")).length).toBe(0);
    expect(text(traced.add(ascii("\nok")))).toBe("+ echo OMPANION_TERMINAL_READY; IFS= read\r\nok");

    const failed = new TerminalReadyFilter();
    expect(failed.add(ascii("sh: not found\r\n")).length).toBe(0);
    expect(text(failed.close())).toBe("sh: not found\r\n");
  });
});
