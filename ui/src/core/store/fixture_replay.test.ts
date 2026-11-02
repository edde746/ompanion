// Port of packages/omp_core/test/store/fixture_replay_test.dart.
import { expect, test } from "bun:test";
import { fixtureNames, outFrames, uiAnswers } from "../../test/fixtures";
import { asJsonObject, type JsonObject } from "../rpc/json_fields";
import { textOf, type ThinkingBlock } from "./content";
import {
  reduce,
  withCompanionSnapshot,
  withEntries,
  withMessages,
  withState,
  withSubagents,
} from "./reducer";
import {
  sessionView,
  sessionViewStatus,
  sessionViewToolResults,
  type CompanionRequest,
  type RunRetrying,
  type RunStatus,
  type SessionView,
  type UiRequest,
} from "./session_view";
import type { AssistantItem, CompactionItem, ExecutionItem, TranscriptItem } from "./transcript";

function objects(value: unknown): JsonObject[] {
  if (!Array.isArray(value)) throw new Error("expected an array");
  return value.map((item) => asJsonObject(item, "element"));
}

/**
 * Reduces a recorded session the way the app's session store does: every frame through `reduce`, state and history
 * responses through the seeding functions, and each dialog answered by the line the recorder sent (what another
 * device's `extension_ui_response` on `in.jsonl` looks like).
 */
class Replay {
  view: SessionView = sessionView();
  finalMessages: JsonObject[] | undefined;
  /** Every request that was open at some point. */
  readonly opened: UiRequest[] = [];
  /** Every status the view passed through, in order. */
  readonly statuses: RunStatus[] = [];
  /** Every view the replay produced. */
  readonly views: SessionView[] = [];
  /** A `message.appended` companion event was recorded. */
  announced = false;
  /** Index in `views` of the view the first `message.appended` event produced. */
  appendedAt: number | undefined;

  constructor(readonly name: string) {
    const answers = uiAnswers(name);
    let entriesSeeded = false;
    for (const frame of outFrames(name)) {
      if (frame.type === "response" && frame.success === true && typeof frame.command === "string") {
        const data = frame.data;
        switch (frame.command) {
          case "get_state":
            this.view = withState(this.view, asJsonObject(data, "get_state"));
            break;
          case "get_messages_page":
            this.view = withMessages(this.view, objects(asJsonObject(data, "page").messages));
            break;
          case "get_entries":
            // The unfiltered read; the later `since` read is a subset of it.
            if (entriesSeeded) break;
            entriesSeeded = true;
            this.view = withEntries(this.view, objects(asJsonObject(data, "entries").entries), {
              leafId: asJsonObject(data, "entries").leafId as string | undefined,
            });
            break;
          case "get_subagents":
            this.view = withSubagents(this.view, objects(asJsonObject(data, "subagents").subagents));
            break;
          case "get_messages":
            if (frame.id === "final-messages") this.finalMessages = objects(asJsonObject(data, "messages").messages);
            break;
        }
      }
      if (frame.type === "ompx" && frame.kind === "reply" && frame.ok === true && typeof frame.callId === "string") {
        const result = asJsonObject(frame.result, "ompx result");
        if (frame.callId.endsWith(":snapshot")) this.view = withCompanionSnapshot(this.view, result);
        if (frame.callId.endsWith(":queue")) this.view = withCompanionSnapshot(this.view, { queue: result });
      }
      this.step(frame);
      if ((frame.type === "extension_ui_request" || frame.type === "ompx") && typeof frame.id === "string") {
        const answer = answers.get(frame.id);
        if (answer !== undefined) this.step(answer);
      }
    }
  }

  private step(frame: JsonObject) {
    const appended = frame.type === "ompx" && frame.event === "message.appended";
    this.view = reduce(this.view, frame);
    this.views.push(this.view);
    if (appended) {
      this.announced = true;
      this.appendedAt ??= this.views.length - 1;
    }
    for (const request of this.view.requests) {
      if (!this.opened.some((seen) => seen.id === request.id)) this.opened.push(request);
    }
    const status = sessionViewStatus(this.view);
    if (this.statuses.length === 0 || this.statuses[this.statuses.length - 1] !== status) this.statuses.push(status);
  }

  /** omp's own transcript at the end of the recording, as the view models it. */
  get reference(): readonly TranscriptItem[] {
    return withMessages(sessionView(), this.finalMessages ?? []).transcript;
  }

  live(reference: TranscriptItem): TranscriptItem | undefined {
    return this.view.transcript.find((item) => item.identity === reference.identity);
  }
}

function textOfItem(item: TranscriptItem): string | undefined {
  switch (item.kind) {
    case "UserItem":
    case "AssistantItem":
    case "ToolResultItem":
    case "CustomItem":
      return textOf(item.content);
    case "CompactionItem":
      return item.summary;
    default:
      return undefined;
  }
}

/**
 * Recordings whose final `get_messages` is omp's rewritten context rather than everything that was shown: a compaction
 * drops the summarized turns, an auto-retry drops the failed attempt.
 */
const rewritten = new Set(["compaction", "compaction-prompt", "error-retry"]);

/** Recordings without session frames: nothing is shown live, the transcript only comes from seeding. */
const seededOnly = new Set(["big-frame"]);

const kinds = (items: readonly TranscriptItem[]) => items.map((item) => item.kind);

const checks: Record<string, (replay: Replay) => void> = {
  abort: (replay) => {
    expect(replay.statuses.some((status) => status.kind === "RunAborted")).toBe(true);
    // The second prompt completed.
    expect(sessionViewStatus(replay.view).kind).toBe("RunIdle");
  },
  approval: (replay) => {
    const approvals = replay.opened.filter((request) => request.kind === "ApprovalRequest");
    expect(approvals.map((approval) => [approval.toolName, approval.toolCallId])).toEqual([["bash", "call_1_0"]]);
  },
  ask: (replay) => {
    expect(replay.opened.map((request) => request.kind)).toEqual(["SelectRequest", "SelectRequest", "EditorRequest"]);
  },
  "big-frame": (replay) => {
    expect(replay.view.transcript).toEqual([]);
    expect(replay.reference).toHaveLength(6);
    const lastItem = replay.reference[replay.reference.length - 1] as AssistantItem;
    expect(textOf(lastItem.content).length).toBeGreaterThan(400000);
  },
  "companion-ask": (replay) => {
    expect(replay.opened).toHaveLength(1);
    const ask = replay.opened[0] as CompanionRequest;
    expect(ask.method).toBe("ask");
    expect(ask.params.questions).toHaveLength(2);
  },
  "companion-exec": (replay) => {
    expect(replay.announced).toBe(true);
    expect(replay.view.transcript).toHaveLength(1);
    const execution = replay.view.transcript[0] as ExecutionItem;
    expect([execution.executionKind, execution.output]).toEqual(["bash", "one\ntwo\nthree\n"]);
  },
  "companion-exec-streaming": (replay) => {
    // omp holds a command run while a turn streams until the next prompt; the companion pushes it then.
    const appendedAt = replay.appendedAt as number;
    expect(
      replay.views.slice(0, appendedAt).map((view) => view.transcript.filter((item) => item.kind === "ExecutionItem").length),
    ).toEqual(new Array<number>(appendedAt).fill(0));
    expect(kinds((replay.views[appendedAt] as SessionView).transcript)).toEqual([
      "UserItem",
      "AssistantItem",
      "ExecutionItem",
    ]);
    const rows = replay.view.transcript;
    expect(kinds(rows)).toEqual(["UserItem", "AssistantItem", "ExecutionItem", "UserItem", "AssistantItem"]);
    expect((rows[2] as ExecutionItem).command).toBe("echo while-streaming");
  },
  "companion-pause": (replay) => {
    expect(replay.views.some((view) => view.run.paused && view.run.pausedAt !== undefined)).toBe(true);
    expect(replay.view.run.paused).toBe(false);
  },
  "companion-queue": (replay) => {
    expect(replay.views.map((view) => view.queue.followUp)).toContainEqual(["Then summarize it."]);
    expect(replay.view.queue.count).toBe(0);
  },
  compaction: (replay) => {
    const summaries = replay.reference.filter((item): item is CompactionItem => item.kind === "CompactionItem");
    expect(summaries).toHaveLength(1);
    const shown = replay.view.transcript.filter((item): item is CompactionItem => item.kind === "CompactionItem");
    expect(shown.map((item) => item.summary)).toEqual([summaries[0]?.summary as string]);
    // The summarized turn stays visible.
    expect(replay.view.transcript.filter((item) => item.kind === "UserItem")).toHaveLength(2);
  },
  "compaction-prompt": (replay) => {
    // Compacting shows before it ends.
    expect(replay.statuses.filter((status) => status.kind === "RunCompacting")).toHaveLength(1);
    const summaries = replay.reference.filter((item): item is CompactionItem => item.kind === "CompactionItem");
    expect(summaries).toHaveLength(1);
    const dividers = replay.view.transcript.filter((item): item is CompactionItem => item.kind === "CompactionItem");
    expect(dividers).toHaveLength(1);
    expect(dividers[0]?.summary).toBe(summaries[0]?.summary as string);
    // Built from the committed entry.
    expect(dividers[0]?.entryId).toBeDefined();
    expect(sessionViewStatus(replay.view).kind).toBe("RunIdle");
  },
  "error-retry": (replay) => {
    const retrying = replay.statuses.filter((status): status is RunRetrying => status.kind === "RunRetrying");
    expect(retrying.map((status) => [status.attempt, status.maxAttempts])).toEqual([[1, 10]]);
    const failed = replay.view.transcript.find((item): item is AssistantItem => item.kind === "AssistantItem");
    expect([failed?.stopReason, failed?.retryRecovery?.recovered]).toEqual(["error", true]);
  },
  "session-resume": (replay) => {
    expect(replay.view.historyLength).toBe(4);
    expect(replay.view.transcript.map((item) => item.entryId !== undefined)).toEqual([true, true, true, true, false, false]);
  },
  "steer-followup": (replay) => {
    expect(replay.view.transcript.filter((item) => item.kind === "UserItem")).toHaveLength(3);
  },
  subagent: (replay) => {
    expect(replay.view.subagents).toHaveLength(1);
    const echo = replay.view.subagents[0];
    expect([echo?.id, echo?.status, echo?.parentToolCallId]).toEqual(["Echo", "completed", "call_1_0"]);
    // The session settled.
    expect(sessionViewToolResults(replay.view).get("call_1_0")?.state).toBe("done");
  },
  "text-stream": (replay) => {
    const lastItem = replay.view.transcript[replay.view.transcript.length - 1] as AssistantItem;
    expect(textOf(lastItem.content)).toStartWith("# Fixture notes");
  },
  thinking: (replay) => {
    const lastItem = replay.view.transcript[replay.view.transcript.length - 1] as AssistantItem;
    const thinking = lastItem.content.filter((block): block is ThinkingBlock => block.kind === "ThinkingBlock");
    expect(thinking.map((block) => block.signature)).toEqual(["reasoning_content"]);
  },
  todo: (replay) => {
    expect(replay.view.todoPhases).toHaveLength(1);
    const phase = replay.view.todoPhases[0];
    expect(phase?.name).toBe("Fixtures");
    expect(phase?.tasks.map((task) => task.status)).toEqual(["completed", "completed"]);
  },
};

const names = fixtureNames();

test("fixtures are present", () => expect(names.length).toBeGreaterThan(0));

for (const name of names) {
  test(`${name}: the reduced view matches omp's final transcript`, () => {
    const replay = new Replay(name);
    // Every recording ends with get_messages.
    expect(replay.finalMessages).toBeDefined();

    expect(replay.view.run.running).toBe(false);
    // Every dialog was answered.
    expect(replay.view.requests).toEqual([]);
    for (const item of replay.view.transcript) {
      if (item.kind === "AssistantItem" && item.streaming) throw new Error(`${item.key} still streams`);
      if (item.kind === "ToolResultItem" && (item.state === "running" || item.state === "background")) {
        throw new Error(`${item.key} still runs`);
      }
    }

    // Rows omp showed live. It sends no frame for a user execution; only the companion's `message.appended` does.
    const shown = seededOnly.has(name)
      ? []
      : replay.reference.filter((item) => item.kind !== "ExecutionItem" || replay.announced);
    for (const expected of shown) {
      const actual = replay.live(expected);
      if (actual === undefined) throw new Error(`missing ${expected.identity}`);
      expect(textOfItem(actual)).toBe(textOfItem(expected) as string);
      if (expected.kind === "ToolResultItem" && actual.kind === "ToolResultItem") {
        expect([actual.isError, actual.state]).toEqual([expected.isError, "done"]);
      }
    }
    if (!rewritten.has(name)) {
      expect(replay.view.transcript.map((item) => item.identity)).toEqual(shown.map((item) => item.identity));
    }
    checks[name]?.(replay);
  });
}
