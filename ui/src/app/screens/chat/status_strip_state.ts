// The decisions of lib/screens/chat/status_strip.dart: what the status strip says, which command outputs and extension
// widgets show, and what a notice says.
import type { LiveSession } from "../../../core/session/live_session";
import {
  type ExtensionWidget,
  type Notice,
  type RunState,
  type RunStatus,
  runStateStatus,
  type SessionView,
  type WidgetPlacement,
} from "../../../core/store/session_view";
import { t } from "../../i18n/i18n";

/** How long Stopped shows after a stop. */
export const stoppedForMs = 4000;

interface Stop {
  active: boolean;
  readonly timer: ReturnType<typeof setTimeout>;
}

/**
 * Each session's current stop, active while Stopped shows. Kept per session, not per strip: a strip built again
 * (another layout, the chat opened again) must not show an old stop anew.
 */
export class StopMarks {
  private readonly stops = new WeakMap<LiveSession, Stop>();

  /** `onEnd` runs when a stop's time is up, so the strips showing it update. */
  constructor(
    private readonly onEnd: () => void,
    private readonly forMs = stoppedForMs,
  ) {}

  /** Whether Stopped still shows for `session` in `status`. */
  shows(session: LiveSession, status: RunStatus): boolean {
    const current = this.stops.get(session);
    if (status.kind !== "RunAborted") {
      if (current !== undefined) clearTimeout(current.timer);
      this.stops.delete(session);
      return false;
    }
    if (current !== undefined) return current.active;
    const stop: Stop = {
      active: true,
      timer: setTimeout(() => {
        stop.active = false;
        this.onEnd();
      }, this.forMs),
    };
    this.stops.set(session, stop);
    return true;
  }
}

/** A run state the strip names; the strip gives each its icon and colour. */
export interface StripChip {
  readonly kind: "parked" | "compacting" | "retrying" | "failed" | "stopped";
  readonly text: string;
}

/**
 * The run states the strip shows: a parked run while paused, compacting, retrying, a failed run, and Stopped while
 * `stopped` (the transcript's Interrupted marker stays). A closed session (`live` false) has no run left to describe.
 */
export function stripChips(options: { live: boolean; run: RunState; stopped: boolean }): StripChip[] {
  if (!options.live) return [];
  const { run } = options;
  const chips: StripChip[] = [];
  if (run.paused && run.running) chips.push({ kind: "parked", text: t.chat.parked });
  const status = runStateStatus(run);
  switch (status.kind) {
    case "RunCompacting":
      chips.push({ kind: "compacting", text: t.chat.compacting });
      break;
    case "RunRetrying":
      chips.push({
        kind: "retrying",
        text: t.chat.retrying({ attempt: status.attempt, max: status.maxAttempts, error: status.errorMessage }),
      });
      break;
    case "RunFailed":
      chips.push({ kind: "failed", text: t.chat.failed({ error: status.message ?? t.chat.failedUnknown }) });
      break;
    case "RunAborted":
      if (options.stopped) chips.push({ kind: "stopped", text: t.chat.aborted });
      break;
    case "RunStreaming":
    case "RunIdle":
      break;
  }
  return chips;
}

/** The highest `seq` of `view`'s command outputs, -1 without any: the ones there when the chat opens count as seen. */
export function latestOutputSeq(view: SessionView): number {
  return view.commandOutputs.at(-1)?.seq ?? -1;
}

/** The notices or command outputs after `seq`, the last one shown or dismissed. */
export function newerThan<T extends { readonly seq: number }>(items: readonly T[], seq: number): T[] {
  return items.filter((item) => item.seq > seq);
}

/**
 * The extension widgets with lines for `placement`, by key. `aboveEditor` also takes widgets without a placement, as
 * omp's TUI does.
 */
export function placedWidgets(
  widgets: ReadonlyMap<string, ExtensionWidget>,
  placement: WidgetPlacement,
): [string, ExtensionWidget][] {
  return [...widgets].filter(([, widget]) => (widget.placement ?? "aboveEditor") === placement && widget.lines.length > 0);
}

/** Whether `notice` shows as an error. */
export function noticeIsError(notice: Notice): boolean {
  switch (notice.kind) {
    case "MessageNotice":
      return notice.level === "error";
    case "ExtensionErrorNotice":
      return true;
    case "CompactionNotice":
      return !notice.aborted;
    case "RetryFallbackNotice":
      return false;
  }
}

export function noticeText(notice: Notice): string {
  switch (notice.kind) {
    case "MessageNotice":
      return notice.source === undefined ? notice.message : `${notice.source}: ${notice.message}`;
    case "ExtensionErrorNotice":
      return t.chat.extensionError({ path: notice.extensionPath, event: notice.event, error: notice.error });
    case "RetryFallbackNotice":
      return notice.succeeded
        ? t.chat.fallbackServed({ model: notice.to })
        : t.chat.fallbackApplied({ from: notice.from ?? "?", to: notice.to, reason: notice.reason ?? "" });
    case "CompactionNotice":
      return notice.aborted ? t.chat.compactionCancelled : t.chat.compactionFailed({ error: notice.errorMessage ?? "" });
  }
}
