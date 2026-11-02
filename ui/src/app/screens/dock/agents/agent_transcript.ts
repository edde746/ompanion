// Port of lib/screens/dock/agents/agent_transcript.dart.
import { toSftpPath } from "../../../../core/host/scripts";
import { RpcCommandException } from "../../../../core/rpc/exceptions";
import { FormatException, isJsonObject, type JsonObject } from "../../../../core/rpc/json_fields";
import type { LiveSession } from "../../../../core/session/live_session";
import { withEntries } from "../../../../core/store/reducer";
import { sessionView, type SessionView } from "../../../../core/store/session_view";
import type { HostFiles } from "../../../../core/transport/host_link";
import { Emitter, type EventStream } from "../../../../core/util/stream";
import { appLogger } from "../../../utils/app_logger";

/** One read of a transcript file from a byte offset: the entries of its complete lines. */
export interface TranscriptChunk {
  readonly nextByte: number;
  readonly reset: boolean;
  readonly entries: readonly JsonObject[];
}

/**
 * A subagent's transcript while the Agent Hub shows it, polled from where the last read stopped with RPC
 * `get_subagent_messages`. omp answers only for subagents it saw start in this process; for the others (advisors,
 * agents restored from an earlier run) the same byte-offset read goes straight to the session file.
 */
export class AgentTranscript {
  readonly session: LiveSession;
  readonly agentId: string;
  /** Host-native path of the agent's session file, when known. */
  readonly sessionFile: string | undefined;
  /** File access to the machine, for reading `sessionFile` directly. */
  private readonly openFiles: (() => Promise<HostFiles>) | undefined;

  /** Poll every second while the agent runs, less often otherwise. */
  live = true;

  private readonly entries: JsonObject[] = [];
  private currentView: SessionView = sessionView();
  private failure: unknown;
  private isLoaded = false;
  private nextByte = 0;
  private readFile = false;
  private polling = false;
  private disposed = false;
  private timer: ReturnType<typeof setTimeout> | undefined;
  private files: HostFiles | undefined;
  private readonly changeEmitter = new Emitter<void>();

  constructor(options: {
    session: LiveSession;
    agentId: string;
    sessionFile: string | undefined;
    openFiles?: () => Promise<HostFiles>;
  }) {
    this.session = options.session;
    this.agentId = options.agentId;
    this.sessionFile = options.sessionFile;
    this.openFiles = options.openFiles;
    void this.poll();
  }

  get view(): SessionView {
    return this.currentView;
  }

  /** The last poll's failure; cleared by the next successful one. */
  get error(): unknown {
    return this.failure;
  }

  /** The first poll finished. */
  get loaded(): boolean {
    return this.isLoaded;
  }

  /** Emits after every change of `view`, `error` or `loaded`: the Dart ChangeNotifier's notifications. */
  get changes(): EventStream<void> {
    return this.changeEmitter.stream;
  }

  private async poll(): Promise<void> {
    if (this.polling || this.disposed) return;
    this.polling = true;
    try {
      const chunk = await this.fetch();
      if (this.disposed) return;
      if (chunk.reset) this.entries.length = 0;
      // The header and title slot are not conversation entries.
      const fresh = chunk.entries.filter(
        (entry) => typeof entry.id === "string" && entry.type !== "session" && entry.type !== "title",
      );
      this.nextByte = chunk.nextByte;
      const changed = fresh.length > 0 || chunk.reset || this.failure !== undefined || !this.isLoaded;
      this.entries.push(...fresh);
      if (fresh.length > 0 || chunk.reset) {
        const leaf = this.entries.at(-1);
        this.currentView =
          leaf === undefined ? sessionView() : withEntries(sessionView(), this.entries, { leafId: leaf.id as string });
      }
      this.failure = undefined;
      this.isLoaded = true;
      if (changed) this.changeEmitter.add();
    } catch (error) {
      if (this.disposed) return;
      this.failure = error;
      this.isLoaded = true;
      this.changeEmitter.add();
    } finally {
      this.polling = false;
      if (!this.disposed) this.timer = setTimeout(() => void this.poll(), this.live ? 1000 : 4000);
    }
  }

  private async fetch(): Promise<TranscriptChunk> {
    if (!this.readFile) {
      try {
        return await this.session.rpc.getSubagentMessages({ subagentId: this.agentId, fromByte: this.nextByte });
      } catch (error) {
        if (!(error instanceof RpcCommandException) || this.sessionFile === undefined || this.openFiles === undefined) {
          throw error;
        }
        appLogger.d(`get_subagent_messages for ${this.agentId} failed (${error.message}); reading ${this.sessionFile}`);
        this.readFile = true;
      }
    }
    const files = this.files ?? (this.files = await this.open());
    try {
      return await readTranscriptChunk(files, toSftpPath(this.sessionFile!), this.nextByte);
    } catch (error) {
      // The access may be dead (a dropped link): close it, and open a new one next time.
      this.files = undefined;
      closeQuietly(files);
      throw error;
    }
  }

  private async open(): Promise<HostFiles> {
    const files = await this.openFiles!();
    if (this.disposed) {
      closeQuietly(files);
      throw new Error("agent transcript disposed");
    }
    return files;
  }

  dispose(): void {
    this.disposed = true;
    clearTimeout(this.timer);
    if (this.files !== undefined) closeQuietly(this.files);
    this.changeEmitter.close();
  }
}

function closeQuietly(files: HostFiles): void {
  files.close().catch((error: unknown) => appLogger.w("closing file access failed", { error }));
}

/**
 * Reads the complete JSONL lines of `path` from byte `fromByte`, as omp's `readRpcSubagentTranscript` does: a trailing
 * partial line waits for the next read, and an offset past the end (the file was rewritten) restarts at 0.
 */
export async function readTranscriptChunk(files: HostFiles, path: string, fromByte: number): Promise<TranscriptChunk> {
  const stat = await files.stat(path);
  if (stat === null) return { nextByte: fromByte, reset: false, entries: [] };
  let start = fromByte;
  let reset = false;
  if (start > stat.size) {
    start = 0;
    reset = true;
  }
  if (start === stat.size) return { nextByte: start, reset, entries: [] };
  const bytes = await files.read(path, { offset: start });
  const end = bytes.lastIndexOf(0x0a);
  if (end < 0) return { nextByte: start, reset, entries: [] };
  return { nextByte: start + end + 1, reset, entries: parseTranscriptLines(bytes.subarray(0, end + 1)) };
}

/** The JSON objects of complete JSONL `bytes`. Throws FormatException for a line that is not a JSON object. */
export function parseTranscriptLines(bytes: Uint8Array): JsonObject[] {
  const entries: JsonObject[] = [];
  for (const line of new TextDecoder().decode(bytes).split(/\r\n|\r|\n/)) {
    if (line.trim() === "") continue;
    let value: unknown;
    try {
      value = JSON.parse(line);
    } catch (error) {
      if (!(error instanceof SyntaxError)) throw error;
      throw new FormatException(`transcript line is not JSON: ${error.message}`);
    }
    if (!isJsonObject(value)) throw new FormatException(`transcript line is not a JSON object: ${line}`);
    entries.push(value);
  }
  return entries;
}
