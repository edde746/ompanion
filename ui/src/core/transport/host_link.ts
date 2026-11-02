// Port of packages/omp_core/lib/src/transport/host_link.dart. The only implementation is BridgeLink
// (bridge_link.ts): the Go core runs the processes, SFTP and sockets, for this computer (`local`) and over SSH.
import type { EventStream } from "../util/stream";

/** A machine the app can run commands on, read files from, and open sockets through. */
export interface HostLink {
  /** Short human label for errors and logs, e.g. `user@host` or `this computer`. */
  readonly label: string;

  /**
   * Starts [command] with SSH exec semantics: the machine's shell for this user parses it. On this computer the core
   * runs `/bin/sh -c` on POSIX and `cmd.exe /d /s /c` on Windows. With [pty] the process gets a terminal; stderr is
   * merged into stdout.
   */
  exec(command: string, options?: { pty?: PtyRequest }): Promise<HostProcess>;

  /** File access in SFTP path space: POSIX paths, Windows drives as `/C:/...`. */
  files(): Promise<HostFiles>;

  /** Opens a TCP connection from the machine to [host]:[port] (SSH `direct-tcpip`). */
  connect(host: string, port: number): Promise<HostSocket>;

  /** Settles when the link is gone: closed locally, closed by the peer, or the network dropped. */
  readonly done: Promise<void>;

  close(): Promise<void>;
}

export interface PtyRequest {
  columns: number;
  rows: number;
  /** Default `xterm-256color`. */
  term?: string;
}

export interface HostProcess {
  /** Single subscription: bytes wait for the first listener. */
  readonly stdout: EventStream<Uint8Array>;

  /** Empty when the process runs with a PTY. Single subscription. */
  readonly stderr: EventStream<Uint8Array>;

  write(bytes: Uint8Array): void;

  /** Sends EOF on stdin. */
  closeStdin(): Promise<void>;

  readonly exit: Promise<HostExit>;

  /** Only meaningful with a PTY. */
  resize(columns: number, rows: number): void;

  /**
   * Has the machine stop reading the process's output until [resume], so the process waits on a full pipe instead of
   * its output piling up here (backpressure); its end waits too. Settles once the machine stopped reading; never fails
   * for a process that ended meanwhile.
   */
  pause(): Promise<void>;

  /** Delivers what [pause] held back, then the rest of the output in order, the end last. */
  resume(): Promise<void>;

  /** Best effort: SIGTERM over SSH, a kill locally. */
  kill(): void;

  /**
   * Ends the process for good: over SSH the channel closes, so sshd hangs up a PTY session (interactive shells ignore
   * [kill]'s SIGTERM); locally the process is killed. Settles when the channel or process is gone.
   */
  close(): Promise<void>;
}

export interface HostExit {
  /** Null when the process ended by signal or the channel closed without an exit status. */
  code: number | null;
  signal?: string;
}

export interface HostFiles {
  /**
   * Null when [path] does not exist. With `followLinks: false` a symbolic link describes itself (SFTP LSTAT): `isLink`
   * is true and `isDirectory` false, whatever the link points to.
   */
  stat(path: string, options?: { followLinks?: boolean }): Promise<HostFileStat | null>;

  /** Entries describe themselves without following links. */
  list(path: string): Promise<HostDirEntry[]>;

  /** Reads [length] bytes from [offset], or to the end when [length] is absent. */
  read(path: string, options?: { offset?: number; length?: number }): Promise<Uint8Array>;

  /** Creates or truncates [path], or appends. [mode] applies on creation. */
  write(path: string, bytes: Uint8Array, options?: { append?: boolean; mode?: number }): Promise<void>;

  /** Throws [HostFileExists] when [path] already exists; used as an atomic lock. */
  mkdir(path: string, options?: { mode?: number }): Promise<void>;

  /** Deletes a file or a symbolic link. A link is removed itself, never what it points to. */
  remove(path: string): Promise<void>;

  removeDir(path: string): Promise<void>;

  rename(from: string, to: string): Promise<void>;

  /** Absolute home directory of the logged-in user, in SFTP path space. */
  home(): Promise<string>;

  close(): Promise<void>;
}

export interface HostFileStat {
  size: number;
  isDirectory: boolean;
  isLink: boolean;
  /** Epoch milliseconds. */
  modifiedMs?: number;
  mode?: number;
}

export interface HostDirEntry {
  name: string;
  stat: HostFileStat;
}

export interface HostSocket {
  readonly input: EventStream<Uint8Array>;
  add(bytes: Uint8Array): void;
  readonly done: Promise<void>;
  close(): Promise<void>;
}

export class HostLinkException extends Error {
  constructor(message: string, cause?: unknown) {
    super(cause === undefined ? message : `${message}: ${String(cause)}`, { cause });
    this.name = "HostLinkException";
  }
}

export class HostFileExists extends HostLinkException {
  constructor(path: string) {
    super(`already exists: ${path}`);
    this.name = "HostFileExists";
  }
}
