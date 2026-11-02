// Port of lib/screens/chat/transcript/transcript_view.dart.
import { createEffect, createMemo, createSignal, flush, For, onSettled, Show } from "solid-js";
import type { SessionView, Subagent } from "../../../../core/store/session_view";
import type { ToolResultItem, TranscriptItem, UserItem } from "../../../../core/store/transcript";
import { t } from "../../../i18n/i18n";
import { TurnExpansion } from "../../../sessions/turn_expansion";
import { ActivityMark } from "../../../widgets/activity_mark";
import { IconButton, TextButton } from "../../../widgets/button";
import * as Symbols from "../../../widgets/symbols";
import { TranscriptRowView } from "./message_rows";
import { RowExtents } from "./row_extents";
import { type TranscriptActions, TranscriptScope, TranscriptStorage } from "./transcript_actions";
import {
  awaitingReply,
  type TranscriptRow,
  TranscriptRowModel,
  transcriptRowContent,
} from "./transcript_rows";
import "./transcript_view.css";

export type { TranscriptActions } from "./transcript_actions";

/** How close to the bottom still counts as at the bottom. */
const pinDistance = 32;

/** Rows closer than this to the top edge ask for the page of history before them. */
const loadEarlierDistance = 400;

/** Rows are built this far beyond each edge of the viewport, so a scroll shows built rows. */
const overscan = 800;

/** How long after a wheel, touch, key or press, or after the last scroll event of its momentum, scrolls are the reader's. */
const readerWindowMs = 150;

/** Keys that scroll the transcript while the focus is in it. */
const scrollKeys = new Set(["ArrowUp", "ArrowDown", "PageUp", "PageDown", "Home", "End", " "]);

/** Where the transcript's text is one step up (`chatTextTheme`): the window's shorter side is at least 600 px. */
const roomyQuery = "(min-width: 600px) and (min-height: 600px)";

const noSubagents: readonly Subagent[] = [];

/** Measures how long each thinking block streamed while the transcript was open. */
class ThinkingClock {
  private readonly started = new Map<string, number>();
  private readonly durations = new Map<string, number>();

  observe(transcript: readonly TranscriptItem[]): void {
    const now = Date.now();
    const live = new Set<string>();
    // Only the newest items stream.
    for (let i = transcript.length - 1; i >= 0 && i >= transcript.length - 4; i--) {
      const item = transcript[i]!;
      const last = item.kind === "AssistantItem" ? item.content[item.content.length - 1] : undefined;
      if (item.kind === "AssistantItem" && item.streaming && last?.kind === "ThinkingBlock") {
        const rowKey = `${item.key}#${item.content.length - 1}`;
        live.add(rowKey);
        if (!this.started.has(rowKey)) this.started.set(rowKey, now);
      }
    }
    for (const [key, started] of this.started) {
      if (live.has(key)) continue;
      this.durations.set(key, now - started);
      this.started.delete(key);
    }
    if (this.durations.size > 512) this.durations.delete(this.durations.keys().next().value!);
  }

  durationOf(rowKey: string): number | undefined {
    return this.durations.get(rowKey);
  }
}

/** The session works on its latest turn, which then shows every row. */
function inProgress(view: SessionView): boolean {
  const run = view.run;
  return (
    run.running ||
    run.compacting !== undefined ||
    run.retrying !== undefined ||
    run.paused ||
    view.requests.length > 0
  );
}

export interface TranscriptViewProps {
  readonly view: SessionView;
  readonly actions: TranscriptActions;
  /** Settled turns fold (the main chat); a subagent's transcript shows every row. Default true. */
  readonly foldTurns?: boolean;
  /** Which turns the reader opened; kept by the caller to outlive this view. Without it the view keeps its own. */
  readonly turns?: TurnExpansion;
  /**
   * The session's link is closed: a run or a send its last view shows as going on is not answered here any more, so
   * the awaiting-reply row does not count on (the status strip hides its run chips the same way).
   */
  readonly closed?: boolean;
}

/** What one built row renders. */
interface Entry {
  readonly row: TranscriptRow;
  readonly result: ToolResultItem | undefined;
  readonly subagents: readonly Subagent[];
  readonly thoughtMs: number | undefined;
}

/** The rows of one update, and what the update asks of the scroll position. */
interface Update {
  readonly rows: readonly TranscriptRow[];
  /** The user just sent something: show it, even when they had scrolled up. */
  readonly sent: boolean;
  /** A tree navigation moved the leaf: the rebuilt transcript ends where the reader should now be. */
  readonly toEnd: boolean;
  /** An entry to reveal is not loaded yet: load earlier pages until it arrives. */
  readonly loadEarlier: boolean;
}

/**
 * The chat transcript of one session: the rows of `SessionView.transcript`, newest at the bottom.
 *
 * A transcript shorter than the pane starts at its top edge and does not scroll. A taller one stays at its bottom
 * while the reader is there (within `pinDistance`), from the update it overflows in. Anywhere else the row at the top
 * edge stays where it is: loading earlier history above it, a row above it growing or shrinking, and a reply
 * streaming below it move nothing on screen. Toggling a turn keeps its summary row where it is.
 *
 * Rows are windowed: only the rows within `overscan` of the viewport are in the DOM, between two spacers whose heights
 * are the other rows' extents (`RowExtents`: the height a row had when it was last built, else an estimate). A row
 * keeps its state across that through `TranscriptStorage`. A row built above the top edge seldom lays out at its
 * estimate, so building it moves the rows below. While the reader scrolls, the top spacer takes that move up instead
 * of the scroll offset (`slack`): on iOS a written offset stops the momentum, and WebKit applies it from the page's
 * copy of the offset, which trails the scroll, so the rows jump back by what the scroll did meanwhile. The spacer goes
 * below zero when it must, lifting the top rows out of reach above the top edge; a gap above the first row it holds
 * only out of sight. Once the scroll ends the offset takes the slack over, which nothing on screen shows.
 *
 * With `foldTurns`, a settled turn folds its work under a summary row (see `TranscriptRowModel`); the latest turn
 * shows every row while the session works on it: while it streams, compacts, retries or is paused, and while a
 * request waits for an answer.
 *
 * A row re-renders only when what it renders changed: its row's content (`transcriptRowContent`), tool result,
 * subagents or thought time; the reducer keeps unchanged parts identical, so a streaming update renders one row.
 */
export function TranscriptView(props: TranscriptViewProps) {
  const storage = new Map<string, unknown>();
  const extents = new RowExtents();
  const thinking = new ThinkingClock();
  const fold = () => props.foldTurns ?? true;

  let ownTurns: TurnExpansion | undefined;
  const turns = createMemo(() => props.turns ?? (ownTurns ??= new TurnExpansion()));
  const model = createMemo(() => {
    const expansion = turns();
    return new TranscriptRowModel({ isOpen: fold() ? (head: TranscriptItem) => expansion.isOpen(head) : undefined });
  });

  // The awaiting-reply row shows while the link is open and awaitingReply holds, counting one second at a time. The
  // count starts over for each wait.
  const awaits = createMemo(() => !props.closed && awaitingReply(props.view));
  const [seconds, setSeconds] = createSignal(0, { ownedWrite: true });
  createEffect(
    () => awaits(),
    (awaiting) => {
      if (!awaiting) return;
      const timer = setInterval(() => setSeconds((value) => value + 1), 1000);
      return () => {
        clearInterval(timer);
        setSeconds(0);
      };
    },
  );

  let updatedModel: TranscriptRowModel | undefined;
  let turnsVersion = -1;
  let lastItem: TranscriptItem | undefined;
  let pending: UserItem | undefined;
  const update = createMemo((): Update => {
    const rowModel = model();
    const expansion = turns();
    const version = expansion.changed();
    const view = props.view;
    const transcript = view.transcript;
    const initial = updatedModel === undefined;
    const turnsChanged = rowModel === updatedModel && version !== turnsVersion;
    updatedModel = rowModel;
    turnsVersion = version;

    thinking.observe(transcript);
    const newest = transcript[transcript.length - 1];
    const previous = lastItem;
    lastItem = newest;
    // The tail rows go on after the items' rows, so they stay the last ones.
    rowModel.update(transcript, { live: inProgress(view) });
    const message = props.closed ? undefined : view.pendingPrompt?.message;
    const sending = message !== undefined && message.key !== pending?.key;
    pending = message;
    rowModel.showPending(message);
    rowModel.showAwaiting(awaits() ? seconds() : undefined);

    // Opens the turn of the entry TurnExpansion.reveal asked for, once the transcript holds it.
    let loadEarlier = false;
    const reveal = expansion.pendingReveal;
    if (reveal !== undefined && fold()) {
      const index = transcript.findLastIndex((item) => item.entryId === reveal);
      if (index >= 0) {
        expansion.revealedIn(rowModel.headOf(index));
        rowModel.refold();
      } else {
        loadEarlier = true;
      }
    }
    if (turnsChanged) rowModel.refold();

    const typed =
      newest?.kind === "UserItem" &&
      newest.key !== previous?.key &&
      !newest.synthetic &&
      newest.attribution !== "agent";
    return {
      rows: rowModel.rows.slice(),
      sent: !initial && (sending || typed),
      toEnd: turnsChanged && expansion.takeJumpToEnd(),
      loadEarlier,
    };
  });

  // Row extents, summed: offsets[i] is the top of row i in the rows' column, offsets[rows.length] their height.
  const [measures, setMeasures] = createSignal(0, { ownedWrite: true });
  const offsets = createMemo(() => {
    measures();
    const rows = update().rows;
    const result = new Float64Array(rows.length + 1);
    rows.forEach((row, index) => (result[index + 1] = result[index]! + extents.of(row)));
    return result;
  });

  /** The built rows, `first` to `last` (exclusive), and the key of the first one. */
  const [range, setRange] = createSignal<{ first: number; last: number; key?: string }>(
    { first: 0, last: 0 },
    { ownedWrite: true, equals: (a, b) => a.first === b.first && a.last === b.last && a.key === b.key },
  );
  // Rows inserted or removed above the built ones (an earlier page, a refold) move their indexes: the built rows follow
  // their first row's key, so the rows on screen stay built and keep their place.
  const span = createMemo(() => {
    const rows = update().rows;
    const { first, last, key } = range();
    let shift = 0;
    if (key !== undefined && rows[first]?.key !== key) {
      const index = rows.findIndex((row) => row.key === key);
      if (index >= 0) shift = index - first;
    }
    return {
      first: Math.min(rows.length, Math.max(0, first + shift)),
      last: Math.min(rows.length, Math.max(0, last + shift)),
    };
  });
  const entries = createMemo((): Entry[] => {
    const rows = update().rows;
    const rowModel = model();
    const subagents = props.view.subagents;
    const { first, last } = span();
    return rows.slice(first, last).map((row) => ({
      row,
      result: row.kind === "ToolRow" ? rowModel.resultOf(row.callId) : undefined,
      subagents: row.kind === "ToolRow" && row.toolName === "task" ? subagents : noSubagents,
      thoughtMs: row.kind === "ThinkingRow" ? thinking.durationOf(row.key) : undefined,
    }));
  });
  /** The top spacer's height; below zero it lifts the rows after it above the column's top. */
  const topSpace = () => offsets()[span().first]! + slackHeight();
  const bottomSpace = () => {
    const all = offsets();
    return all[all.length - 1]! - all[span().last]!;
  };

  let scroller: HTMLDivElement | undefined;
  let column: HTMLDivElement | undefined;
  let content: HTMLDivElement | undefined;
  const built = new Map<string, HTMLElement>();
  const heights = new Map<string, number>();

  /** Follow the growth at the bottom. Starts true: a transcript opens at its newest row. */
  let pinned = true;
  /** A touch is on the transcript: its scroll is the reader's, not to be overridden by following the growth. */
  let touching = false;
  /** A mouse or pen button is down in the transcript: a scrollbar drag, or a selection scrolling past an edge. */
  let pressing = false;
  /**
   * Until when (performance.now()) a scroll event counts as the reader's: a wheel, touch, key or press, and the
   * momentum after it, which keeps extending it. Any other scroll event is the browser's or the view's own.
   */
  let readerUntil = 0;
  /** jumpToLatest's smooth scroll is under way: its scroll events are not to be corrected. */
  let jumping: number | undefined;
  /** The row at the top edge, and its top in the column's coordinates (offsetTop) when it was taken. */
  let anchor: { key: string; top: number } | undefined;
  /**
   * How much higher the top spacer is than the extents of the rows above the built ones: the moves it took up while
   * the reader scrolled. Rows from the first built one on lay out `slack` lower than their offsets.
   */
  let slack = 0;
  const [slackHeight, setSlackHeight] = createSignal(0, { ownedWrite: true });
  const setSlack = (value: number) => {
    slack = value;
    setSlackHeight(value);
  };
  let stopTimer: number | undefined;

  const reading = () => touching || pressing || performance.now() < readerUntil;
  const readerScrolls = () => {
    readerUntil = performance.now() + readerWindowMs;
    clearTimeout(stopTimer);
    stopTimer = window.setTimeout(readerStopped, readerWindowMs + 20);
  };

  /** The reader's scroll ended: the offset takes the spacer's slack over. */
  function readerStopped() {
    stopTimer = undefined;
    // A held touch or press schedules this again when it lets go.
    if (touching || pressing) return;
    const left = readerUntil - performance.now();
    if (left > 0) stopTimer = window.setTimeout(readerStopped, left + 20);
    else if (slack !== 0) settle();
  }

  const [atBottom, setAtBottom] = createSignal(true, { ownedWrite: true });
  const [loadingEarlier, setLoadingEarlier] = createSignal(false, { ownedWrite: true });
  /** `SessionView.historyLength` when earlier history was last requested; a request that brings nothing waits for it to change. */
  let requestedAt: number | undefined;

  const maxScroll = (element: HTMLElement) => element.scrollHeight - element.clientHeight;

  /** The first built row whose bottom is below the top edge. */
  function captureAnchor(element: HTMLElement) {
    const top = element.scrollTop;
    anchor = undefined;
    for (const entry of entries()) {
      const row = built.get(entry.row.key);
      if (row && row.offsetTop + row.offsetHeight > top) {
        anchor = { key: entry.row.key, top: row.offsetTop };
        return;
      }
    }
  }

  /** Builds the rows within `overscan` of the viewport; true when that changed which rows are built. */
  function updateRange(element: HTMLElement): boolean {
    const all = offsets();
    const count = all.length - 1;
    const columnTop = (column?.offsetTop ?? 0) + slack;
    const top = element.scrollTop - columnTop - overscan;
    const bottom = element.scrollTop + element.clientHeight - columnTop + overscan;
    // first: the first row whose bottom is below `top`; last: the first row whose top is at or below `bottom`.
    const first = Math.min(count, Math.max(0, lowerBound(all, top, 1) - 1));
    const last = Math.max(first, Math.min(count, lowerBound(all, bottom, 0)));
    const current = span();
    if (current.first === first && current.last === last) return false;
    setRange({ first, last, key: update().rows[first]?.key });
    return true;
  }

  /**
   * Records the heights of the built rows the observer has not reported yet, before the offsets are read: a row built
   * in one pass of `settle` and dropped in the next would otherwise leave its estimate in the spacer, and the passes
   * would flip between the two layouts, writing the offset back and forth.
   */
  function measureBuilt(): boolean {
    if (!column || measuredWidth === 0 || column.clientWidth !== measuredWidth) return false;
    let changed = false;
    for (const [key, element] of built) {
      if (!heights.has(key)) changed = record(key, Number.parseFloat(getComputedStyle(element).height)) || changed;
    }
    if (changed) setMeasures((value) => value + 1);
    return changed;
  }

  /**
   * The slack the spacer may hold: none once the reader's scroll ended. Above the first row a higher spacer is a gap at
   * the top, which it holds only while that is out of sight above the viewport.
   */
  function keepable(value: number, element: HTMLElement): number {
    if (!reading()) return 0;
    if (value <= 0 || span().first > 0) return value;
    return element.scrollTop >= (column?.offsetTop ?? 0) + value ? value : 0;
  }

  /**
   * Puts the scroll position where it belongs after the rows or their heights changed: at the bottom while pinned,
   * else where the anchor row keeps its place on screen. Runs before the browser paints (from effects and
   * ResizeObserver callbacks), so a correction never shows.
   */
  function settle() {
    const element = scroller;
    if (!element) return;
    for (let pass = 0; pass < 4; pass++) {
      flush();
      if (measureBuilt()) flush();
      const kept = keepable(slack, element);
      if (kept !== slack) {
        setSlack(kept);
        flush();
      }
      if (pinned && !touching) {
        if (slack !== 0) {
          setSlack(0);
          flush();
        }
        const target = maxScroll(element);
        // An unchanged offset is not written again: on iOS any write stops a momentum scroll.
        if (Math.abs(target - element.scrollTop) >= 1) element.scrollTop = target;
      } else if (anchor) {
        const row = built.get(anchor.key);
        if (row) {
          let shift = row.offsetTop - anchor.top;
          const next = Math.abs(shift) >= 1 ? keepable(slack - shift, element) : slack;
          if (next !== slack) {
            setSlack(next);
            flush();
            shift = row.offsetTop - anchor.top;
          }
          // Relative to the offset now, so a scroll since the anchor was taken stays.
          if (Math.abs(shift) >= 1) element.scrollTop += shift;
          anchor.top = row.offsetTop;
        }
      }
      if (!updateRange(element)) break;
    }
    captureAnchor(element);
    setAtBottom(element.scrollTop >= maxScroll(element) - pinDistance);
    if (element.scrollTop - slack < loadEarlierDistance) loadEarlier(false);
  }

  /**
   * Only the reader's scrolls decide whether the view follows the growth. The browser moves the offset on its own too:
   * a layout where the rows are shorter clamps it to that layout's bottom, and WebKit lays out mid-update whenever code
   * measures something (a table fitting its columns), so the scroll event can arrive once the rows grew back and the
   * clamped offset reads as scrolled up. Such a scroll puts a following view back at the bottom.
   */
  function onScroll() {
    const element = scroller;
    if (!element) return;
    const bottom = element.scrollTop >= maxScroll(element) - pinDistance;
    if (touching || pressing || performance.now() < readerUntil) {
      readerScrolls();
      pinned = bottom;
    } else if (bottom) {
      pinned = true;
    } else if (pinned && jumping === undefined) {
      settle();
      return;
    }
    setAtBottom(pinned || bottom);
    // The row the reader scrolled to stays put while the rows around it are built.
    captureAnchor(element);
    if (updateRange(element) || keepable(slack, element) !== slack) settle();
    if (element.scrollTop - slack < loadEarlierDistance) loadEarlier(false);
  }

  function loadEarlier(retry: boolean) {
    const load = props.actions.onLoadEarlier;
    const history = props.view.historyLength;
    if (!load || loadingEarlier() || (requestedAt === history && !retry)) return;
    requestedAt = history;
    setLoadingEarlier(true);
    void load().finally(() => setLoadingEarlier(false));
  }

  function jumpToLatest() {
    const element = scroller;
    if (!element) return;
    pinned = true;
    const distance = maxScroll(element) - element.scrollTop;
    // A long way up, the smooth scroll would build every row on its way: jump.
    if (distance > element.clientHeight * 2) {
      settle();
      return;
    }
    clearTimeout(jumping);
    element.scrollTo({ top: maxScroll(element), behavior: "smooth" });
    jumping = window.setTimeout(() => {
      jumping = undefined;
      // The reply may have grown while the scroll ran.
      if (pinned) settle();
    }, 300);
  }

  /** Opens or closes the turn of the summary row `key`; the summary row stays where it is on screen. */
  function toggleTurn(key: string, row: HTMLElement) {
    const rowModel = model();
    const position = rowModel.positionOf(key);
    const summary = position === undefined ? undefined : rowModel.rows[position];
    if (summary?.kind !== "TurnSummaryRow" || !scroller) return;
    const slot = row.closest<HTMLElement>(".transcript-row");
    pinned = false;
    if (slot) anchor = { key, top: slot.offsetTop };
    turns().setOpen(summary.head, !summary.open);
  }

  createEffect(
    () => update(),
    (next) => {
      // Forget the heights of rows that are gone, once there are many.
      if (heights.size > next.rows.length + 64) {
        const keys = new Set(next.rows.map((row) => row.key));
        extents.retain(keys);
        for (const key of heights.keys()) if (!keys.has(key)) heights.delete(key);
      }
      // After this flush, which builds the rows, and before the browser paints.
      queueMicrotask(() => {
        if (next.loadEarlier) loadEarlier(true);
        if (next.sent || next.toEnd) jumpToLatest();
        else settle();
      });
    },
  );

  /** The width the heights were measured at: another one wraps every row anew. */
  let measuredWidth = 0;
  const record = (key: string, measured: number): boolean => {
    // In layout units (1/64 px), so the observer's and getComputedStyle's numbers for one height agree.
    const height = Math.round(measured * 64) / 64;
    if (heights.get(key) === height) return false;
    heights.set(key, height);
    extents.measured(key, measuredWidth, height);
    return true;
  };
  const measure = new ResizeObserver((records) => {
    const width = column?.clientWidth ?? 0;
    let changed = false;
    if (width !== measuredWidth) {
      measuredWidth = width;
      heights.clear();
      for (const [key, element] of built) changed = record(key, element.getBoundingClientRect().height) || changed;
    }
    for (const entry of records) {
      const element = entry.target as HTMLElement;
      const key = element.dataset.key;
      if (key === undefined || !element.isConnected) continue;
      const height = entry.borderBoxSize[0]?.blockSize ?? element.getBoundingClientRect().height;
      changed = record(key, height) || changed;
    }
    if (changed) setMeasures((value) => value + 1);
    settle();
  });

  const roomy = window.matchMedia(roomyQuery);
  extents.bodySize = roomy.matches ? 15 : 14;
  onSettled(() => {
    const applyTextSize = () => {
      extents.bodySize = roomy.matches ? 15 : 14;
      setMeasures((value) => value + 1);
      settle();
    };
    roomy.addEventListener("change", applyTextSize);
    // Anywhere: a scrollbar drag or a selection ends wherever the pointer is let go.
    const release = () => {
      if (!pressing) return;
      pressing = false;
      readerScrolls();
    };
    window.addEventListener("pointerup", release);
    window.addEventListener("pointercancel", release);
    if (scroller) measure.observe(scroller);
    if (column) measure.observe(column);
    // Its height changes with the load-earlier row above the column too (button, spinner, gone), which moves the rows.
    if (content) measure.observe(content);
    return () => {
      roomy.removeEventListener("change", applyTextSize);
      window.removeEventListener("pointerup", release);
      window.removeEventListener("pointercancel", release);
      measure.disconnect();
      clearTimeout(jumping);
      clearTimeout(stopTimer);
    };
  });

  function Slot(slot: { entry: Entry }) {
    const row = createMemo(() => slot.entry.row, { equals: sameContent });
    const result = createMemo(() => slot.entry.result);
    const subagents = createMemo(() => slot.entry.subagents);
    const thoughtMs = createMemo(() => slot.entry.thoughtMs);
    let element: HTMLDivElement | undefined;
    onSettled(() => {
      const key = row().key;
      const current = element;
      if (!current) return;
      built.set(key, current);
      measure.observe(current);
      return () => {
        measure.unobserve(current);
        if (built.get(key) === current) built.delete(key);
      };
    });
    return (
      <div class="transcript-row" data-key={row().key} ref={(el) => (element = el)}>
        <TranscriptRowView
          row={row()}
          result={result()}
          subagents={subagents()}
          thoughtMs={thoughtMs()}
          onToggle={(target) => toggleTurn(row().key, target)}
        />
      </div>
    );
  }

  return (
    <TranscriptScope value={() => props.actions}>
      <TranscriptStorage value={storage}>
        <div class="transcript">
          <div
            class="transcript-scroll"
            ref={(el) => (scroller = el)}
            onScroll={onScroll}
            onWheel={(event) => {
              readerScrolls();
              // At once: a growth settled before the scroll event would put the view back at the bottom.
              if (event.deltaY < 0) pinned = false;
            }}
            onKeyDown={(event) => {
              if (scrollKeys.has(event.key)) readerScrolls();
            }}
            onPointerDown={(event) => {
              if (event.pointerType !== "touch") pressing = true;
            }}
            onTouchStart={() => {
              // A finger landing stops any momentum, so a written offset interrupts nothing: the offset takes the slack
              // over, and rows a fling lifted out of reach above the top come back for this drag.
              if (slack !== 0) {
                readerUntil = 0;
                settle();
              }
              touching = true;
            }}
            onTouchMove={readerScrolls}
            onTouchEnd={() => {
              touching = false;
              readerScrolls();
              onScroll();
            }}
          >
            <div class="transcript-content" ref={(el) => (content = el)}>
              <Show when={props.actions.onLoadEarlier}>
                <div class="transcript-load-earlier" style={{ visibility: topSpace() < 0 ? "hidden" : undefined }}>
                  <Show
                    when={!loadingEarlier()}
                    fallback={<ActivityMark size={20} />}
                  >
                    <TextButton icon={Symbols.history} onClick={() => loadEarlier(true)}>
                      {t.transcript.loadEarlier}
                    </TextButton>
                  </Show>
                </div>
              </Show>
              <div class="transcript-column" ref={(el) => (column = el)}>
                <div style={{ height: `${Math.max(0, topSpace())}px`, "margin-top": `${Math.min(0, topSpace())}px` }} />
                <For each={entries()} keyed={(entry) => entry.row.key}>
                  {(entry) => <Slot entry={entry()} />}
                </For>
                <div style={{ height: `${bottomSpace()}px` }} />
              </div>
            </div>
          </div>
          <div class={["transcript-jump", { "transcript-jump-shown": !atBottom() }]}>
            <IconButton
              class="transcript-jump-button"
              icon={Symbols.arrow_downward}
              tooltip={t.transcript.jumpToLatest}
              disabled={atBottom()}
              onClick={jumpToLatest}
            />
          </div>
        </div>
      </TranscriptStorage>
    </TranscriptScope>
  );
}

/** Rows that render the same: one key, and identical content parts. */
function sameContent(a: TranscriptRow, b: TranscriptRow): boolean {
  if (a === b) return true;
  if (a.key !== b.key || a.kind !== b.kind) return false;
  const before = transcriptRowContent(a);
  const after = transcriptRowContent(b);
  return before.length === after.length && before.every((part, index) => part === after[index]);
}

/** The first index from `from` whose value in the sorted `values` is above `target` (or values.length). */
function lowerBound(values: Float64Array, target: number, from: number): number {
  let low = from;
  let high = values.length;
  while (low < high) {
    const middle = (low + high) >> 1;
    if (values[middle]! <= target) low = middle + 1;
    else high = middle;
  }
  return low;
}
