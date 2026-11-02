// Port of lib/terminal/shell_launch.dart. Not ported: `localShell`, `accountLoginShell` and the `dscl`/`passwd`
// parsers. A terminal on this computer is a `pty.open` through the core like an SSH one (docs/app.md: the core picks
// the shell and the environment of local processes).
import { type CommandShell, psQuote } from "../../core/host/scripts";
import { base64Decode } from "../../core/util/base64";

/** The line [posixTerminalCommand] prints once the terminal neither echoes nor edits input. */
export const terminalReadyMarker = "OMPANION_TERMINAL_READY";

/**
 * What a PTY runs on a POSIX machine. The machine's login shell (fish, csh, …) parses it, so it holds no value: sh
 * saves the terminal modes, switches to raw mode without echo, prints [terminalReadyMarker], reads the start directory
 * as one stdin line, restores the modes, changes into the directory and replaces itself with the login shell. Raw mode
 * keeps the line from being echoed, cut at the canonical line limit, or edited by control characters in the name. A
 * `cd` that fails leaves the shell in the home directory with the error on screen.
 */
export const posixTerminalCommand =
  `sh -c 's=$(stty -g); stty raw -echo; echo ${terminalReadyMarker}; ` +
  `IFS= read -r d; stty "$s"; [ -z "$d" ] || cd "$d"; exec "\${SHELL:-/bin/sh}" -l'`;

/**
 * How a terminal starts on a machine: [command] for a PTY, and on POSIX machines the [startLine] to send once
 * [terminalReadyMarker] arrives.
 */
export interface RemoteShellLaunch {
  readonly command: string;
  readonly startLine: string | undefined;
}

/**
 * The user's login shell, started in [cwd] (host-native). [shell] is the OpenSSH `DefaultShell` of a Windows machine;
 * a POSIX machine runs its own `$SHELL`. Windows shells get [cwd] quoted on the command line.
 */
export function remoteShellLaunch(options: {
  readonly commandShell: CommandShell;
  readonly shell: string | undefined;
  readonly cwd: string | undefined;
}): RemoteShellLaunch {
  const { cwd, shell } = options;
  switch (options.commandShell) {
    case "posix":
      // `read` ends at the first newline, so a directory whose name holds one starts in the home directory.
      return { command: posixTerminalCommand, startLine: `${cwd === undefined || cwd.includes("\n") ? "" : cwd}\n` };
    case "cmd":
      return { command: `${cwd === undefined ? "" : `cd /d "${cwd}" & `}cmd.exe`, startLine: undefined };
    case "powershell": {
      const program = shell !== undefined && shell.trim() !== "" ? shell : "powershell.exe";
      const cd = cwd === undefined ? "" : `Set-Location -LiteralPath ${psQuote(cwd)}; `;
      return { command: `${cd}& ${psQuote(program)} -NoLogo`, startLine: undefined };
    }
  }
}

const marker = new TextEncoder().encode(terminalReadyMarker);
const empty: Uint8Array = new Uint8Array(0);

/**
 * Takes the [terminalReadyMarker] line out of PTY output that arrives in chunks. Output before the line is held until
 * it arrives, then passed on with everything after it.
 */
export class TerminalReadyFilter {
  private held = empty;
  private isReady = false;

  /** Whether the line arrived. */
  get ready(): boolean {
    return this.isReady;
  }

  /** The bytes to show for [chunk]: none while the line is still to come. */
  add(chunk: Uint8Array): Uint8Array {
    if (this.isReady) return chunk;
    const bytes = concat(this.held, chunk);
    this.held = bytes;
    for (let at = indexOf(bytes, marker, 0); at >= 0; at = indexOf(bytes, marker, at + 1)) {
      let end = at + marker.length;
      // Raw mode ends the line with LF; a terminal still translating output sends CR LF.
      if (end < bytes.length && bytes[end] === 0x0d) end++;
      if (end === bytes.length) break;
      if (bytes[end] !== 0x0a) continue;
      this.isReady = true;
      this.held = empty;
      return concat(bytes.subarray(0, at), bytes.subarray(end + 1));
    }
    return empty;
  }

  /** Output held back when the stream ended before the line, such as the error of a shell that failed to start. */
  close(): Uint8Array {
    const held = this.held;
    this.held = empty;
    return held;
  }
}

function concat(a: Uint8Array, b: Uint8Array): Uint8Array {
  const bytes = new Uint8Array(a.length + b.length);
  bytes.set(a);
  bytes.set(b, a.length);
  return bytes;
}

function indexOf(bytes: Uint8Array, pattern: Uint8Array, from: number): number {
  for (let i = from; i + pattern.length <= bytes.length; i++) {
    let j = 0;
    while (j < pattern.length && bytes[i + j] === pattern[j]) j++;
    if (j === pattern.length) return i;
  }
  return -1;
}

const encoder = new TextEncoder();

/** Keystrokes and pastes from the terminal view, as the bytes a PTY expects. */
export function encodeTerminalInput(data: string): Uint8Array {
  return encoder.encode(data);
}

/**
 * xterm.js's binary input (`onBinary`: mouse reports past code 127 in the X10 encoding), one byte per character, as
 * xterm.js asks its embedders to send it.
 */
export function encodeTerminalBinary(data: string): Uint8Array {
  return Uint8Array.from(data, (character) => character.charCodeAt(0) & 0xff);
}

/**
 * Turns PTY output chunks into text for the terminal. A UTF-8 sequence split across chunks is held back until its last
 * byte arrives; invalid bytes become U+FFFD instead of failing the stream.
 */
export class TerminalOutputDecoder {
  // ignoreBOM keeps a U+FEFF the program wrote instead of dropping it from the start of the stream.
  private readonly decoder = new TextDecoder("utf-8", { ignoreBOM: true });

  constructor(private readonly onText: (text: string) => void) {}

  add(bytes: Uint8Array): void {
    this.emit(this.decoder.decode(bytes, { stream: true }));
  }

  /** Flushes a trailing incomplete sequence as U+FFFD. */
  close(): void {
    this.emit(this.decoder.decode());
  }

  private emit(text: string): void {
    if (text !== "") this.onText(text);
  }
}

/**
 * The text an OSC 52 sequence (`ESC ] 52 ; <selections> ; <base64> BEL`, xterm.js's handler gets what follows `52;`)
 * asks to put on the clipboard: a remote editor's yank. Undefined for a query (`?`), which no program gets an answer
 * to: `cat` of a hostile file, or a compromised machine, could read a copied password through it. Undefined as well
 * for data that is not base64.
 */
export function osc52ClipboardText(data: string): string | undefined {
  const payload = data.slice(data.indexOf(";") + 1);
  if (!data.includes(";") || !/^[A-Za-z0-9+/]*={0,2}$/.test(payload) || payload.length % 4 !== 0) return undefined;
  return new TextDecoder().decode(base64Decode(payload));
}
