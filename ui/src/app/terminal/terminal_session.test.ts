// Port of the backend, tabs, PTY size, exited shell and burst cases of test/dock/terminal_io_test.dart. The frame
// writer's own cases are not ported (terminal_session.ts says why); the view is a fake that resizes like xterm.js.
import { describe, expect, jest, test } from "bun:test";
import type { IEvent } from "@xterm/xterm";
import { deferred } from "../../deferred";
import type { HostExit, HostFiles, HostLink, HostProcess, HostSocket, PtyRequest } from "../../core/transport/host_link";
import { Emitter, type EventStream } from "../../core/util/stream";
import { encodeTerminalInput, posixTerminalCommand } from "./shell_launch";
import { TerminalDeck } from "./terminal_deck";
import {
  HostTerminalBackend,
  outputHighWatermark,
  outputLowWatermark,
  type TerminalBackend,
  type TerminalScreen,
  TerminalSession,
  terminalStartDelayMs,
} from "./terminal_session";

const utf8 = (text: string) => new TextEncoder().encode(text);
const decode = (bytes: Uint8Array) => new TextDecoder().decode(bytes);

/** One macrotask turn: every promise callback queued before it has run by then. */
function settle(): Promise<void> {
  const done = deferred<void>();
  setTimeout(() => done.resolve(), 0);
  return done.promise;
}

class FakeEvent<T> {
  private readonly listeners = new Set<(value: T) => void>();

  readonly event: IEvent<T> = (listener) => {
    this.listeners.add(listener);
    return { dispose: () => this.listeners.delete(listener) };
  };

  fire(value: T): void {
    for (const listener of this.listeners) listener(value);
  }

  get count(): number {
    return this.listeners.size;
  }
}

/**
 * xterm.js's Terminal as the session sees it: a grid that reports its resizes, and the text written to it, whose
 * write callbacks (xterm.js calls them once it parsed the text) wait for [parse].
 */
class FakeScreen implements TerminalScreen {
  cols = 80;
  rows = 24;
  shown = "";
  disposed = false;
  readonly data = new FakeEvent<string>();
  readonly binary = new FakeEvent<string>();
  readonly resized = new FakeEvent<{ cols: number; rows: number }>();
  readonly titles = new FakeEvent<string>();
  readonly onData = this.data.event;
  readonly onBinary = this.binary.event;
  readonly onResize = this.resized.event;
  readonly onTitleChange = this.titles.event;
  private readonly unparsed: (() => void)[] = [];

  write(data: string | Uint8Array, parsed?: () => void): void {
    this.shown += typeof data === "string" ? data : decode(data);
    if (parsed) this.unparsed.push(parsed);
  }

  /** Parses the oldest [writes] writes still waiting. */
  parse(writes: number): void {
    for (const parsed of this.unparsed.splice(0, writes)) parsed();
  }

  /** As xterm.js: a resize to the size it has fires nothing. */
  resize(cols: number, rows: number): void {
    if (cols === this.cols && rows === this.rows) return;
    this.cols = cols;
    this.rows = rows;
    this.resized.fire({ cols, rows });
  }

  dispose(): void {
    this.disposed = true;
  }
}

/** A shell that exits when told. Afterwards writes and resizes throw, as they would on a PTY whose shell exited. */
class FakeBackend implements TerminalBackend {
  private readonly out = new Emitter<Uint8Array>({ buffered: true });
  private readonly exited = deferred<number | undefined>();
  private hasExited = false;
  readonly written: string[] = [];
  readonly sizes: [number, number][] = [];
  /** Pauses and resumes, in order. */
  readonly flow: string[] = [];
  closed = false;
  closeError: Error | undefined;

  get output(): EventStream<Uint8Array> {
    return this.out.stream;
  }

  get exitCode(): Promise<number | undefined> {
    return this.exited.promise;
  }

  emit(text: string): void {
    this.out.add(utf8(text));
  }

  exit(code: number): void {
    this.hasExited = true;
    this.exited.resolve(code);
    this.out.close();
  }

  write(bytes: Uint8Array): void {
    if (this.hasExited) throw new Error("PTY closed");
    this.written.push(decode(bytes));
  }

  resize(columns: number, rows: number): void {
    if (this.hasExited) throw new Error("PTY closed");
    this.sizes.push([columns, rows]);
  }

  async pause(): Promise<void> {
    this.flow.push("pause");
  }

  async resume(): Promise<void> {
    this.flow.push("resume");
  }

  async close(): Promise<void> {
    this.closed = true;
    if (this.closeError) throw this.closeError;
  }
}

/** A PTY process driven by the test. */
class FakeProcess implements HostProcess {
  private readonly out = new Emitter<Uint8Array>({ buffered: true });
  private readonly ended = deferred<HostExit>();
  readonly written: string[] = [];
  readonly sizes: [number, number][] = [];
  readonly exit = this.ended.promise;
  readonly stderr: EventStream<Uint8Array> = new Emitter<Uint8Array>().stream;

  get stdout(): EventStream<Uint8Array> {
    return this.out.stream;
  }

  emit(text: string): void {
    this.out.add(utf8(text));
  }

  end(): void {
    this.out.close();
    this.ended.resolve({ code: 0 });
  }

  write(bytes: Uint8Array): void {
    this.written.push(decode(bytes));
  }

  async closeStdin(): Promise<void> {}

  resize(columns: number, rows: number): void {
    this.sizes.push([columns, rows]);
  }

  async pause(): Promise<void> {}

  async resume(): Promise<void> {}

  kill(): void {}

  async close(): Promise<void> {}
}

/** A link whose one PTY process is driven by the test. */
class PtyLink implements HostLink {
  readonly label = "test";
  readonly done = deferred<void>().promise;
  readonly process = new FakeProcess();
  command: string | undefined;
  pty: PtyRequest | undefined;

  async exec(command: string, options: { pty?: PtyRequest } = {}): Promise<HostProcess> {
    this.command = command;
    this.pty = options.pty;
    return this.process;
  }

  files(): Promise<HostFiles> {
    throw new Error("not used");
  }

  connect(): Promise<HostSocket> {
    throw new Error("not used");
  }

  async close(): Promise<void> {}
}

function collect(stream: EventStream<Uint8Array>): { text: () => string; done: Promise<void> } {
  let shown = "";
  const done = deferred<void>();
  stream.listen((bytes) => (shown += decode(bytes)), { done: () => done.resolve() });
  return { text: () => shown, done: done.promise };
}

describe("remote shell launch", () => {
  test("the PTY takes sizes at once; the directory waits for the ready line, and keystrokes for the directory", async () => {
    const link = new PtyLink();
    const backend = await HostTerminalBackend.start(
      link,
      { command: posixTerminalCommand, startLine: "/srv/app\n" },
      { columns: 80, rows: 24 },
    );
    const process = link.process;
    expect(link.command).toBe(posixTerminalCommand);
    expect(link.pty).toEqual({ columns: 80, rows: 24 });
    const shown = collect(backend.output);

    // Before the login shell exists, the view's size already reaches the PTY; typing waits.
    backend.resize(100, 40);
    backend.write(encodeTerminalInput("ls\r"));
    expect(process.sizes).toEqual([[100, 40]]);
    process.emit("Last login: today\r\n");
    expect(process.written).toEqual([]);

    process.emit("OMPANION_TERMINAL_READY\n");
    expect(process.written).toEqual(["/srv/app\n", "ls\r"]);
    backend.write(encodeTerminalInput("pwd\r"));
    expect(process.written).toEqual(["/srv/app\n", "ls\r", "pwd\r"]);

    process.emit("~/srv/app $ ");
    process.end();
    await shown.done;
    expect(shown.text()).toBe("Last login: today\r\n~/srv/app $ ");
    expect(await backend.exitCode).toBe(0);
  });

  test("a shell that ends before the ready line shows why", async () => {
    const link = new PtyLink();
    const backend = await HostTerminalBackend.start(
      link,
      { command: posixTerminalCommand, startLine: "\n" },
      { columns: 80, rows: 24 },
    );
    const process = link.process;
    backend.write(encodeTerminalInput("ls\r"));
    process.emit("This account is currently not available.\r\n");
    process.end();
    const shown = collect(backend.output);
    await shown.done;
    expect(shown.text()).toBe("This account is currently not available.\r\n");
    expect(process.written).toEqual([]);
  });

  test("a launch without a start line passes output and keystrokes straight through", async () => {
    const link = new PtyLink();
    const backend = await HostTerminalBackend.start(
      link,
      { command: "cmd.exe", startLine: undefined },
      { columns: 80, rows: 24 },
    );
    backend.write(encodeTerminalInput("dir\r"));
    expect(link.process.written).toEqual(["dir\r"]);
    const shown = collect(backend.output);
    link.process.emit("C:\\> ");
    expect(shown.text()).toBe("C:\\> ");
  });
});

describe("tabs", () => {
  test("closing a tab to the left of the selected one keeps that one selected", () => {
    const tab = () =>
      new TerminalSession({ title: "sh", terminal: new FakeScreen(), open: () => deferred<TerminalBackend>().promise });
    const [a, b, c] = [tab(), tab(), tab()];
    const deck = new TerminalDeck<FakeScreen>();
    deck.add(a);
    deck.add(b);
    deck.add(c);
    expect(deck.current).toBe(c);
    deck.select(1);
    deck.close(a);
    expect(deck.current).toBe(b);
    deck.close(c);
    expect(deck.current).toBe(b);
    expect(a.terminal.disposed && c.terminal.disposed).toBe(true);
    deck.close(b);
    expect(deck.current).toBeUndefined();
    deck.dispose();
  });

  test("disposing the deck ends every shell", async () => {
    const backends = [new FakeBackend(), new FakeBackend()];
    const deck = new TerminalDeck<FakeScreen>();
    for (const backend of backends) {
      const session = new TerminalSession({ title: "sh", terminal: new FakeScreen(), open: async () => backend });
      deck.add(session);
      session.terminal.resize(90, 30);
    }
    await settle();
    expect(deck.sessions.map((session) => session.phase.kind)).toEqual(["TerminalRunning", "TerminalRunning"]);
    deck.dispose();
    expect(backends.map((backend) => backend.closed)).toEqual([true, true]);
    expect(deck.sessions).toEqual([]);
  });
});

describe("PTY size", () => {
  test("opens at the laid-out grid and follows the view, also while the PTY opens", async () => {
    const opening = deferred<TerminalBackend>();
    const opened: [number, number][] = [];
    const backend = new FakeBackend();
    const screen = new FakeScreen();
    const session = new TerminalSession({
      title: "sh",
      terminal: screen,
      open: (columns, rows) => {
        opened.push([columns, rows]);
        return opening.promise;
      },
    });
    screen.resize(100, 30);
    await settle();
    expect(opened).toEqual([[100, 30]]);

    // The dock widens while the PTY opens: the PTY gets the new grid before any output is drawn.
    screen.resize(120, 40);
    await settle();
    expect(backend.sizes).toEqual([]);
    opening.resolve(backend);
    await settle();
    expect(backend.sizes).toEqual([[120, 40]]);
    expect(session.phase.kind).toBe("TerminalRunning");

    screen.resize(90, 20);
    expect(backend.sizes.at(-1)).toEqual([90, 20]);
    session.dispose();
  });

  test("a view that reports no grid in time starts the PTY at the terminal's own size", async () => {
    jest.useFakeTimers();
    const opened: [number, number][] = [];
    const session = new TerminalSession({
      title: "sh",
      terminal: new FakeScreen(),
      open: async (columns, rows) => {
        opened.push([columns, rows]);
        return new FakeBackend();
      },
    });
    jest.advanceTimersByTime(terminalStartDelayMs - 1);
    expect(opened).toEqual([]);
    jest.advanceTimersByTime(1);
    expect(opened).toEqual([[80, 24]]);
    jest.useRealTimers();
    await settle();
    expect(session.phase.kind).toBe("TerminalRunning");
    session.dispose();
  });
});

describe("running shell", () => {
  test("output reaches the terminal; keystrokes typed while it starts follow once it runs", async () => {
    const backend = new FakeBackend();
    const screen = new FakeScreen();
    const session = new TerminalSession({ title: "sh", terminal: screen, open: async () => backend });
    screen.data.fire("echo hi\r");
    screen.resize(90, 30);
    await settle();
    expect(backend.written).toEqual(["echo hi\r"]);
    backend.emit("hi\r\n$ ");
    expect(screen.shown).toBe("hi\r\n$ ");
    screen.binary.fire("\x1b[M \xff\x80");
    expect(backend.written.length).toBe(2);
    session.dispose();
  });

  test("the title follows the shell's, and an empty one keeps the last", async () => {
    const screen = new FakeScreen();
    const session = new TerminalSession({ title: "studio", terminal: screen, open: async () => new FakeBackend() });
    screen.titles.fire("  vim notes.txt ");
    expect(session.title).toBe("vim notes.txt");
    screen.titles.fire("   ");
    expect(session.title).toBe("vim notes.txt");
    session.dispose();
  });

  test("a backend that fails to open is the failed phase", async () => {
    const screen = new FakeScreen();
    const session = new TerminalSession({
      title: "sh",
      terminal: screen,
      open: async () => {
        throw new Error("connection refused");
      },
    });
    screen.resize(90, 30);
    await settle();
    expect(session.phase).toMatchObject({ kind: "TerminalFailed" });
    session.dispose();
  });

  test("a tab disposed while its PTY opens closes the PTY", async () => {
    const opening = deferred<TerminalBackend>();
    const backend = new FakeBackend();
    const screen = new FakeScreen();
    const session = new TerminalSession({ title: "sh", terminal: screen, open: () => opening.promise });
    screen.resize(90, 30);
    await settle();
    session.dispose();
    opening.resolve(backend);
    await settle();
    expect(backend.closed).toBe(true);
    expect(session.phase.kind).toBe("TerminalStarting");
  });
});

describe("bursts", () => {
  /** A running session on a fake backend. */
  async function running(): Promise<{ session: TerminalSession<FakeScreen>; backend: FakeBackend }> {
    const backend = new FakeBackend();
    const session = new TerminalSession({ title: "sh", terminal: new FakeScreen(), open: async () => backend });
    session.terminal.resize(90, 30);
    await settle();
    expect(session.phase.kind).toBe("TerminalRunning");
    return { session, backend };
  }

  test("a shell that writes faster than the terminal parses is paused until the terminal caught up", async () => {
    const { session, backend } = await running();
    // `yes`: chunks of a quarter of the high watermark, written before the terminal parsed any.
    const chunk = "y\n".repeat(outputHighWatermark / 8);
    for (let i = 0; i < 4; i++) backend.emit(chunk);
    expect(backend.flow).toEqual([]);
    backend.emit(chunk);
    expect(backend.flow).toEqual(["pause"]);
    // What arrived before the pause took effect is still shown, and pauses no second time.
    backend.emit("done\n");
    expect(backend.flow).toEqual(["pause"]);
    expect(session.terminal.shown).toBe(`${chunk.repeat(5)}done\n`);

    // Parsed down to just above the low watermark: still paused.
    const left = (count: number) => chunk.length * count + "done\n".length;
    expect(left(1)).toBeGreaterThan(outputLowWatermark);
    session.terminal.parse(4);
    expect(backend.flow).toEqual(["pause"]);
    session.terminal.parse(1);
    expect(left(0)).toBeLessThanOrEqual(outputLowWatermark);
    expect(backend.flow).toEqual(["pause", "resume"]);
    session.terminal.parse(1);
    expect(backend.flow).toEqual(["pause", "resume"]);
    session.dispose();
  });

  test("output the terminal keeps up with never pauses the shell", async () => {
    const { session, backend } = await running();
    const chunk = "y\n".repeat(outputHighWatermark / 4);
    for (let i = 0; i < 10; i++) {
      backend.emit(chunk);
      session.terminal.parse(1);
    }
    expect(backend.flow).toEqual([]);
    session.dispose();
  });
});

describe("exited shell", () => {
  test("resizing and pasting no longer reach it, and the grid still follows the view", async () => {
    const backend = new FakeBackend();
    const screen = new FakeScreen();
    const session = new TerminalSession({ title: "sh", terminal: screen, open: async () => backend });
    screen.resize(90, 30);
    await settle();
    expect(session.phase.kind).toBe("TerminalRunning");
    screen.resize(95, 30);
    expect(backend.sizes).toEqual([[95, 30]]);

    backend.exit(0);
    await settle();
    expect(session.phase).toEqual({ kind: "TerminalExited", code: 0 });
    screen.resize(100, 40);
    screen.data.fire("ls");
    expect([screen.cols, screen.rows]).toEqual([100, 40]);
    expect(backend.written).toEqual([]);

    session.dispose();
    expect(backend.closed).toBe(true);
    expect(screen.disposed).toBe(true);
    expect(screen.data.count + screen.resized.count + screen.titles.count + screen.binary.count).toBe(0);
  });

  test("a close that fails while the tab goes away is no unhandled error", async () => {
    // A live shell when the app shuts down: the link may already be gone.
    const backend = new FakeBackend();
    backend.closeError = new Error("link is closed");
    const screen = new FakeScreen();
    const session = new TerminalSession({ title: "sh", terminal: screen, open: async () => backend });
    screen.resize(90, 30);
    await settle();
    expect(session.phase.kind).toBe("TerminalRunning");
    session.dispose();
    await settle();
    expect(backend.closed).toBe(true);
  });
});
