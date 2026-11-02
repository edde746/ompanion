// Port of packages/omp_core/lib/src/store/external_writer.dart.
//
// Another process on the machine is writing a session file: the app reads the file and never starts its own omp for
// it. Two omp processes appending to one session file interleave their turns and each one's later rewrite throws away
// the other's writes, so the app must stay out.
//
// Detected from the machine, not from omp (`host/session_writer.ts`): a process holding the session file open for
// writing, and omp's terminal breadcrumb (`<agentDir>/terminal-sessions/<terminal id>`, `session-paths.ts`) whose
// recorded session is this file and whose terminal still runs an omp. The breadcrumb catches an omp that holds no
// descriptor right now: omp opens its append descriptor at the first write after it opened or rewrote the file.
import { isJsonObject, type JsonObject } from "../rpc/json_fields";

/** What the machine says about a session file another process writes. */
export interface ExternalWriter {
  /** Pids holding the session file open for writing right now; empty when only a terminal named the writer. */
  readonly pids: readonly number[];
  /**
   * Terminal id from omp's breadcrumb, e.g. `ttys009`; absent when only an open descriptor named the writer, and
   * absent when the breadcrumb id names no terminal the app can check (a multiplexer or emulator id).
   */
  readonly terminal?: string;
  /** The file's last message leaves a turn open (`turnInFlight`): the other process is working on it. */
  readonly busy: boolean;
}

export function externalWriter(fields: { pids?: readonly number[]; terminal?: string; busy?: boolean } = {}): ExternalWriter {
  return { pids: fields.pids ?? [], terminal: fields.terminal, busy: fields.busy ?? false };
}

/** Dart's `ExternalWriter ==`: equal pids in order, terminal and busy. */
export function externalWriterEquals(a: ExternalWriter, b: ExternalWriter): boolean {
  return (
    a.terminal === b.terminal &&
    a.busy === b.busy &&
    a.pids.length === b.pids.length &&
    a.pids.every((pid, i) => b.pids[i] === pid)
  );
}

/**
 * Whether the last message among a session file's [entries] leaves a turn open: a user message or a tool result waits
 * for the model, and an assistant message that stopped for tool use waits for its tools. omp appends a message when it
 * ends, so a long reply or a long tool run leaves the file unchanged for minutes while this holds.
 */
export function turnInFlight(entries: readonly JsonObject[]): boolean {
  for (let i = entries.length - 1; i >= 0; i--) {
    const entry = entries[i] as JsonObject;
    if (entry.type !== "message") continue;
    const message = entry.message;
    if (!isJsonObject(message)) return false;
    if (message.role === "user" || message.role === "toolResult") return true;
    // Dart's pattern requires the key: an assistant message without `stopReason` does not match.
    if (message.role === "assistant" && "stopReason" in message) return message.stopReason === "toolUse";
    return false;
  }
  return false;
}
