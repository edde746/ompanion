// Port of lib/sessions/exec_runs.dart.
import { type Accessor, createSignal, type Setter } from "solid-js";
import type { LiveSession } from "../../core/session/live_session";
import type { SessionView } from "../../core/store/session_view";
import type { ExecutionKind, TranscriptItem } from "../../core/store/transcript";
import { isJsonObject } from "../../core/rpc/json_fields";
import type { Subscription } from "../../core/util/stream";

/** One `!`/`!!` or `$`/`$$` run: companion `exec.bash` / `exec.python`, with output streamed through `exec.chunk` events. */
export class ExecRun {
  readonly startedAt = Date.now();
  output = "";
  running = true;
  exitCode: number | undefined;
  cancelled = false;
  truncated = false;
  error: unknown;

  constructor(
    readonly kind: ExecutionKind,
    /** The command or the Python code. */
    readonly source: string,
    readonly excludeFromContext: boolean,
    /**
     * Identities of transcript rows for the same command that existed before this run, so an earlier run of the same
     * command is not taken for this one's row. Identities, not times: the host's clock may differ.
     */
    private readonly earlierRows: ReadonlySet<string>,
  ) {}

  isRowOf(item: TranscriptItem): boolean {
    return (
      item.kind === "ExecutionItem" &&
      item.executionKind === this.kind &&
      item.command === this.source &&
      item.excludeFromContext === this.excludeFromContext &&
      !this.earlierRows.has(item.identity)
    );
  }
}

/**
 * Rows searched from the end of the transcript: a held run lands before the next prompt's turn, which adds far fewer
 * rows than this before the check runs again.
 */
const handOverWindow = 400;

/**
 * The exec runs started from one session's composer, newest last.
 *
 * A run shows here while it streams and until its transcript row exists: omp records the run as a
 * `bashExecution`/`pythonExecution` message that reaches every device through the companion's `message.appended`. On
 * an idle session that happens right after the run; while a turn streams omp holds the message until the next prompt,
 * so a finished run stays here until then. A run whose message never arrives (the session changed first, or the call
 * failed) stays until dismissed.
 */
export class ExecRuns {
  /** Bumped wherever the Dart ChangeNotifier notifies; read it to follow the runs. */
  readonly changed: Accessor<number>;
  private readonly setChanged: Setter<number>;
  private readonly list: ExecRun[] = [];
  private readonly watches = new Map<ExecRun, Subscription>();
  private disposed = false;

  constructor() {
    [this.changed, this.setChanged] = createSignal(0);
  }

  get runs(): readonly ExecRun[] {
    return [...this.list];
  }

  get anyRunning(): boolean {
    return this.list.some((run) => run.running);
  }

  start(session: LiveSession, kind: ExecutionKind, source: string, options: { excludeFromContext: boolean }): void {
    const earlier = new Set<string>();
    for (const item of session.view.transcript) {
      if (item.kind === "ExecutionItem" && item.executionKind === kind && item.command === source) {
        earlier.add(item.identity);
      }
    }
    const run = new ExecRun(kind, source, options.excludeFromContext, earlier);
    this.list.push(run);
    this.notify();
    this.watches.set(
      run,
      session.views.listen((view) => this.handOver(run, view)),
    );
    try {
      const call = session.companion.start(kind === "bash" ? "exec.bash" : "exec.python", {
        [kind === "bash" ? "command" : "code"]: source,
        ...(options.excludeFromContext ? { excludeFromContext: true } : {}),
      });
      call.events.listen((event) => {
        if (event.event !== "exec.chunk" || !isJsonObject(event.data)) return;
        const text = event.data.text;
        if (typeof text !== "string") return;
        run.output += text;
        this.notify();
      });
      call.result.then(
        (result) => {
          if (isJsonObject(result)) {
            if (typeof result.output === "string") run.output = result.output;
            if (typeof result.exitCode === "number" && Number.isInteger(result.exitCode)) run.exitCode = result.exitCode;
            run.cancelled = result.cancelled === true;
            run.truncated = result.truncated === true;
          }
          run.running = false;
          this.notify();
          // On an idle session the row arrived before this reply.
          this.handOver(run, session.view);
        },
        (error: unknown) => this.fail(run, error),
      );
    } catch (error) {
      this.fail(run, error);
    }
  }

  /** Cancels the running user bash and Python, like Esc in the TUI; the runs still reply, cancelled. */
  async abort(session: LiveSession): Promise<void> {
    await session.companion.call("exec.abort");
  }

  dismiss(run: ExecRun): void {
    this.watches.get(run)?.cancel();
    this.watches.delete(run);
    const index = this.list.indexOf(run);
    if (index < 0) return;
    this.list.splice(index, 1);
    this.notify();
  }

  /** Drops a finished `run` once `view` holds its transcript row, which shows the same command and output. */
  private handOver(run: ExecRun, view: SessionView): void {
    if (run.running || !this.list.includes(run)) return;
    // The row is appended when omp records the run; later turns only add rows after it.
    const transcript = view.transcript;
    for (let i = transcript.length - 1; i >= 0 && i >= transcript.length - handOverWindow; i--) {
      if (run.isRowOf(transcript[i]!)) {
        this.dismiss(run);
        return;
      }
    }
  }

  private fail(run: ExecRun, error: unknown): void {
    run.running = false;
    run.error = error;
    // Its error stays visible until dismissed.
    this.watches.get(run)?.cancel();
    this.watches.delete(run);
    this.notify();
  }

  private notify(): void {
    if (!this.disposed) this.setChanged((count) => count + 1);
  }

  dispose(): void {
    this.disposed = true;
    for (const watch of this.watches.values()) watch.cancel();
    this.watches.clear();
  }
}
