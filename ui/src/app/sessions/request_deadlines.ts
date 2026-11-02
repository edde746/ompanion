// Port of lib/sessions/request_deadlines.dart.
import type { LiveSession } from "../../core/session/live_session";
import type { SessionView, UiRequest } from "../../core/store/session_view";
import type { Subscription } from "../../core/util/stream";

/**
 * Deadlines of one session's timed dialogs (`select`, `confirm` and `input` with a `timeout`), counted from when this
 * device first saw each one, whether the session's chat is on screen or not. omp resolves a timed-out dialog by itself
 * and sends no frame, so at its deadline the dialog leaves the view here.
 */
export class RequestDeadlines {
  private readonly subscription: Subscription;
  /** Epoch ms of each deadline, and its timer. */
  private readonly timers = new Map<string, { readonly at: number; readonly timer: ReturnType<typeof setTimeout> }>();
  private lastRequests: readonly UiRequest[] | undefined;

  constructor(private readonly session: LiveSession) {
    this.subscription = session.views.listen((view) => this.onView(view));
    this.onView(session.view);
  }

  /** When omp stops waiting for request `id` (epoch ms), or undefined when it waits forever. */
  of(id: string): number | undefined {
    return this.timers.get(id)?.at;
  }

  private onView(view: SessionView): void {
    // The reducer keeps an unchanged request list identical; most views are streamed tokens.
    if (view.requests === this.lastRequests) return;
    this.lastRequests = view.requests;
    const open = new Set(view.requests.map((request) => request.id));
    for (const [id, entry] of this.timers) {
      if (open.has(id)) continue;
      clearTimeout(entry.timer);
      this.timers.delete(id);
    }
    for (const request of view.requests) {
      if (request.kind !== "SelectRequest" && request.kind !== "ConfirmRequest" && request.kind !== "InputRequest") {
        continue;
      }
      const timeoutMs = request.timeout;
      if (timeoutMs === undefined || this.timers.has(request.id)) continue;
      const id = request.id;
      this.timers.set(id, {
        at: Date.now() + timeoutMs,
        timer: setTimeout(() => this.session.dismissRequest(id), timeoutMs),
      });
    }
  }

  dispose(): void {
    this.subscription.cancel();
    for (const { timer } of this.timers.values()) clearTimeout(timer);
    this.timers.clear();
  }
}
