// Port of lib/terminal/terminal_session.dart. Its LocalTerminalBackend (flutter_pty2) is not ported: this computer's
// PTY is the core's `pty.open` too, so one backend on HostLink.exec serves every machine. TerminalFrameWriter is not
// ported as such: xterm.js queues what `write` gets and parses it in slices of at most 12 ms a frame on its own; the
// writer's other half, pausing the shell's output past a backlog, is the session's watermarks below.
import type { Terminal } from "@xterm/xterm";
import { type Accessor, createSignal, type Setter } from "solid-js";
import type { HostLink, HostProcess } from "../../core/transport/host_link";
import { Emitter, type EventStream, type Subscription } from "../../core/util/stream";
import { appLogger } from "../utils/app_logger";
import {
  encodeTerminalBinary,
  encodeTerminalInput,
  type RemoteShellLaunch,
  TerminalOutputDecoder,
  TerminalReadyFilter,
} from "./shell_launch";

/** The process a terminal shows: a shell on a PTY. */
export interface TerminalBackend {
  readonly output: EventStream<Uint8Array>;
  write(bytes: Uint8Array): void;
  resize(columns: number, rows: number): void;
  /** Stops taking the shell's output, so the shell waits on a full PTY (backpressure); its end waits too. */
  pause(): Promise<void>;
  /** Takes the output again, what [pause] held back first. */
  resume(): Promise<void>;
  /** The shell's exit code; undefined when it died by a signal or the connection dropped. */
  readonly exitCode: Promise<number | undefined>;
  /** Ends the shell. Idempotent. */
  close(): Promise<void>;
}

/** A PTY on [HostLink.exec]: Dart's SshTerminalBackend, for this computer as for SSH machines. */
export class HostTerminalBackend implements TerminalBackend {
  private readonly held: Uint8Array[] = [];

  private constructor(
    private readonly process: HostProcess,
    readonly output: EventStream<Uint8Array>,
    private ready: boolean,
  ) {}

  /**
   * Runs [launch] on a PTY and returns once it is open, so the terminal can size the PTY before the login shell starts
   * drawing. A launch with a start line sends it once the machine's shell printed the ready marker; keystrokes written
   * before that are held and follow the line. When the process ends before the marker, its output explains why.
   */
  static async start(
    link: HostLink,
    launch: RemoteShellLaunch,
    size: { readonly columns: number; readonly rows: number },
  ): Promise<HostTerminalBackend> {
    const process = await link.exec(launch.command, { pty: { columns: size.columns, rows: size.rows } });
    const startLine = launch.startLine;
    if (startLine === undefined) return new HostTerminalBackend(process, process.stdout, true);
    const filter = new TerminalReadyFilter();
    const output = new Emitter<Uint8Array>({ buffered: true });
    const backend = new HostTerminalBackend(process, output.stream, false);
    process.stdout.listen(
      (chunk) => {
        const shown = filter.add(chunk);
        if (filter.ready && !backend.ready) backend.release(startLine);
        if (shown.length > 0) output.add(shown);
      },
      {
        error: (error) => output.addError(error),
        done: () => {
          const held = filter.close();
          if (held.length > 0) output.add(held);
          output.close();
        },
      },
    );
    return backend;
  }

  private release(startLine: string): void {
    this.ready = true;
    this.process.write(encodeTerminalInput(startLine));
    for (const bytes of this.held.splice(0)) this.process.write(bytes);
  }

  write(bytes: Uint8Array): void {
    if (this.ready) this.process.write(bytes);
    else this.held.push(bytes);
  }

  resize(columns: number, rows: number): void {
    this.process.resize(columns, rows);
  }

  pause(): Promise<void> {
    return this.process.pause();
  }

  resume(): Promise<void> {
    return this.process.resume();
  }

  get exitCode(): Promise<number | undefined> {
    return this.process.exit.then((exit) => exit.code ?? undefined);
  }

  close(): Promise<void> {
    return this.process.close();
  }
}

/** Where a terminal is in its life. */
export type TerminalPhase = TerminalStarting | TerminalRunning | TerminalExited | TerminalFailed;

export interface TerminalStarting {
  readonly kind: "TerminalStarting";
}

export interface TerminalRunning {
  readonly kind: "TerminalRunning";
}

export interface TerminalExited {
  readonly kind: "TerminalExited";
  readonly code: number | undefined;
}

export interface TerminalFailed {
  readonly kind: "TerminalFailed";
  readonly error: unknown;
}

/** The part of xterm.js's Terminal a session drives; tests hand it a fake. */
export type TerminalScreen = Pick<
  Terminal,
  "cols" | "rows" | "write" | "onData" | "onBinary" | "onResize" | "onTitleChange" | "dispose"
>;

/** How long a terminal waits for the view to lay out its grid before the PTY opens at the terminal's own size. */
export const terminalStartDelayMs = 500;

/**
 * Output handed to xterm.js and not parsed yet (UTF-16 code units) past which the shell's output is paused, and down
 * to which it is taken again (the watermarks of xterm.js's flow control guide). A shell that writes faster than the
 * terminal parses (`yes`, `cat` of a large log) then blocks, as in any terminal, instead of piling up output in the
 * page (xterm.js drops what is queued past 50 MB), and the prompt after Ctrl-C waits for at most the backlog.
 */
export const outputHighWatermark = 1024 * 1024;
export const outputLowWatermark = 256 * 1024;

/**
 * One terminal tab: an xterm.js [Terminal] bound to a shell. The PTY opens at the grid size the view lays out (the
 * first resize), or at the terminal's size if the view reports none in time, and follows every later layout,
 * including the ones while the PTY opens. The session owns the terminal: it outlives the view that shows it.
 */
export class TerminalSession<T extends TerminalScreen = Terminal> {
  /** Bumped wherever the Dart ChangeNotifier notifies (title, phase); read it to follow them. */
  readonly changed: Accessor<number>;
  private readonly setChanged: Setter<number>;
  readonly terminal: T;
  private readonly open: (columns: number, rows: number) => Promise<TerminalBackend>;
  private currentTitle: string;
  private currentPhase: TerminalPhase = { kind: "TerminalStarting" };
  private backend: TerminalBackend | undefined;
  private output: Subscription | undefined;
  private readonly startTimer: ReturnType<typeof setTimeout>;
  private readonly pendingInput: Uint8Array[] = [];
  private readonly listeners: { dispose(): void }[];
  private started = false;
  private disposed = false;
  private unparsed = 0;
  private outputPaused = false;

  /** [open] opens the backend at a grid size. */
  constructor(options: {
    readonly title: string;
    readonly terminal: T;
    readonly open: (columns: number, rows: number) => Promise<TerminalBackend>;
  }) {
    [this.changed, this.setChanged] = createSignal(0);
    this.currentTitle = options.title;
    this.terminal = options.terminal;
    this.open = options.open;
    this.listeners = [
      this.terminal.onData((data) => this.input(encodeTerminalInput(data))),
      this.terminal.onBinary((data) => this.input(encodeTerminalBinary(data))),
      this.terminal.onResize(({ cols, rows }) => this.resized(cols, rows)),
      this.terminal.onTitleChange((title) => this.retitle(title)),
    ];
    this.startTimer = setTimeout(() => void this.start(), terminalStartDelayMs);
  }

  get title(): string {
    return this.currentTitle;
  }

  get phase(): TerminalPhase {
    return this.currentPhase;
  }

  private notify(): void {
    this.setChanged((value) => value + 1);
  }

  private retitle(title: string): void {
    const trimmed = title.trim();
    if (trimmed === "" || trimmed === this.currentTitle) return;
    this.currentTitle = trimmed;
    this.notify();
  }

  // Only a running shell gets input and sizes: once it exited, its PTY is gone.
  private input(bytes: Uint8Array): void {
    const kind = this.currentPhase.kind;
    if (this.backend !== undefined && kind === "TerminalRunning") this.backend.write(bytes);
    else if (kind === "TerminalStarting") this.pendingInput.push(bytes);
  }

  private resized(columns: number, rows: number): void {
    if (this.backend !== undefined && this.currentPhase.kind === "TerminalRunning") {
      this.backend.resize(columns, rows);
    } else if (!this.started) {
      // The view laid out the grid: start at its real size.
      queueMicrotask(() => void this.start());
    }
  }

  private async start(): Promise<void> {
    if (this.started || this.disposed) return;
    this.started = true;
    clearTimeout(this.startTimer);
    const { cols: columns, rows } = this.terminal;
    try {
      const backend = await this.open(columns, rows);
      if (this.disposed) {
        await backend.close();
        return;
      }
      this.backend = backend;
      // The view may have laid out again while the PTY opened; the shell has not drawn yet, so it starts at that size.
      const { cols, rows: height } = this.terminal;
      if (cols !== columns || height !== rows) backend.resize(cols, height);
      const decoder = new TerminalOutputDecoder((text) => this.show(text, backend));
      this.output = backend.output.listen((bytes) => decoder.add(bytes), { done: () => decoder.close() });
      for (const bytes of this.pendingInput.splice(0)) backend.write(bytes);
      this.setPhase({ kind: "TerminalRunning" });
      const code = await backend.exitCode;
      this.setPhase({ kind: "TerminalExited", code });
    } catch (error) {
      this.setPhase({ kind: "TerminalFailed", error });
    }
  }

  /** Writes [text] to the terminal, pausing [backend] while too much waits to be parsed. */
  private show(text: string, backend: TerminalBackend): void {
    this.unparsed += text.length;
    this.terminal.write(text, () => {
      this.unparsed -= text.length;
      if (!this.outputPaused || this.unparsed > outputLowWatermark || this.disposed) return;
      this.outputPaused = false;
      backend.resume().catch((error: unknown) => appLogger.w("resuming the terminal's output failed", { error }));
    });
    if (this.outputPaused || this.unparsed <= outputHighWatermark) return;
    this.outputPaused = true;
    backend.pause().catch((error: unknown) => appLogger.w("pausing the terminal's output failed", { error }));
  }

  private setPhase(phase: TerminalPhase): void {
    if (this.disposed) return;
    this.currentPhase = phase;
    this.notify();
  }

  dispose(): void {
    this.disposed = true;
    clearTimeout(this.startTimer);
    this.output?.cancel();
    for (const listener of this.listeners) listener.dispose();
    const backend = this.backend;
    this.backend = undefined;
    // Nothing awaits a disposed tab: a close that fails (the link gone while the app shuts down) is logged here
    // instead of surfacing as an unhandled rejection.
    backend?.close().catch((error: unknown) => appLogger.w("closing the terminal failed", { error }));
    this.terminal.dispose();
  }
}
