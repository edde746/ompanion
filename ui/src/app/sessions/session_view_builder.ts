// lib/sessions/session_view_builder.dart: a live session's view and link state as Solid accessors. Each follows the
// session the accessor names, and gives the session's current value right after it changes.
import { type Accessor, createEffect, createMemo, createSignal } from "solid-js";
import type { LinkState, LiveSession } from "../../core/session/live_session";
import type { SessionView } from "../../core/store/session_view";
import type { EventStream } from "../../core/util/stream";

/** Counts the events of the stream `streamOf` names for the current session, so a memo can follow them. */
function ticks<T>(session: Accessor<LiveSession>, streamOf: (session: LiveSession) => EventStream<T>): Accessor<number> {
  const [tick, setTick] = createSignal(0);
  createEffect(session, (current) => {
    const subscription = streamOf(current).listen(() => setTick((count) => count + 1));
    return () => subscription.cancel();
  });
  return tick;
}

/** Every new view of `session`. */
export function sessionView(session: Accessor<LiveSession>): Accessor<SessionView> {
  const tick = ticks(session, (current) => current.views);
  return createMemo(() => {
    tick();
    return session().view;
  });
}

/**
 * `select` of the session's view, changing only when that value changes (`equals`, default `===`): a sidebar badge
 * that must not follow every streamed token.
 */
export function sessionViewSelector<T>(
  session: Accessor<LiveSession>,
  select: (view: SessionView) => T,
  equals: (a: T, b: T) => boolean = (a, b) => a === b,
): Accessor<T> {
  const tick = ticks(session, (current) => current.views);
  return createMemo(
    () => {
      tick();
      return select(session().view);
    },
    { equals },
  );
}

/** Every new link state of `session`. */
export function linkState(session: Accessor<LiveSession>): Accessor<LinkState> {
  const tick = ticks(session, (current) => current.linkStates);
  return createMemo(() => {
    tick();
    return session().linkState;
  });
}
