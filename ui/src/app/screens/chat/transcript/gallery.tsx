// Dev gallery of the transcript, for screenshots (`ui/scripts/shots/transcript.ts`): `?gallery=transcript&fixture=<name>`
// shows one transcript, at most `&width=<px>` wide (the chat pane's width in the app). Fixtures: the recorded omp
// sessions in harness/fixtures that show transcript rows, replayed through core/store's reducer; `answer`
// (bench/answer.md as a settled reply), `tools` (every tool body and status), `messages` (every message row
// kind, with a pending prompt waiting for its reply), `ansi` (command output in every SGR colour and attribute),
// `long` (a 2,000-row transcript, with how long its first frame took), `stream` (answer.md streaming in, checking that
// settled blocks keep their DOM) and `history` (earlier pages loading above the top row, checking that it stays put).
// `&open=1` opens every settled turn and closed tool line; `&scroll=<px>` scrolls down to that offset once the
// transcript is on screen. main.tsx loads it only for `?gallery=transcript`; the recordings are lazy chunks, and the
// large or row-less ones (big-frame, the companion-only ones) stay out of the build.
import { createMemo, createSignal, For, Loading, Match, onSettled, Show, Switch } from "solid-js";
import { RpcFrameDecoder } from "../../../../core/rpc/frame_decoder";
import { asJsonObject, type JsonObject } from "../../../../core/rpc/json_fields";
import {
  reduce,
  withCompanionSnapshot,
  withEntries,
  withMessages,
  withState,
  withSubagents,
} from "../../../../core/store/reducer";
import { runIdle, type SessionView, sessionView } from "../../../../core/store/session_view";
import { decodeAssistant, decodeMessage, type TranscriptItem, type UserItem } from "../../../../core/store/transcript";
import { splitLines } from "../../../../core/util/text";
import { TurnExpansion } from "../../../sessions/turn_expansion";
import { deferred } from "../../../../deferred";
import { showSnackBar } from "../../../widgets/snackbar";
import answer from "../../../../../../bench/answer.md?raw";
import type { TranscriptActions } from "./transcript_actions";
import { messageGallery } from "./gallery_messages";
import { toolGallery, toolGallerySubagents } from "./gallery_tools";
import { TranscriptView } from "./transcript_view";
import "./gallery.css";

const outFiles = import.meta.glob<string>(
  "../../../../../../harness/fixtures/{abort,approval,ask,compaction,error-retry,subagent,text-stream,thinking,todo,tool-bash,tool-read-edit}.out.jsonl",
  { query: "?raw", import: "default" },
);
const inFiles = import.meta.glob<string>(
  "../../../../../../harness/fixtures/{abort,approval,ask,compaction,error-retry,subagent,text-stream,thinking,todo,tool-bash,tool-read-edit}.in.jsonl",
  { query: "?raw", import: "default" },
);

const recordings = Object.keys(outFiles)
  .map((path) => path.slice(path.lastIndexOf("/") + 1, -".out.jsonl".length))
  .sort();

const scenarios = ["answer", "tools", "messages", "ansi", "long", "stream", "history", ...recordings];

function fixtureFile(files: Record<string, () => Promise<string>>, name: string, direction: string) {
  const path = Object.keys(files).find((key) => key.endsWith(`/${name}.${direction}.jsonl`));
  if (!path) throw new Error(`no fixture ${name}.${direction}.jsonl`);
  return files[path]!();
}

function objects(value: unknown): JsonObject[] {
  if (!Array.isArray(value)) throw new Error("expected an array");
  return value.map((item) => asJsonObject(item, "element"));
}

/**
 * A recorded session reduced the way the app's session store does (fixture_replay.test.ts's Replay): every frame
 * through `reduce`, state and history responses through the seeding functions, each dialog answered by the line the
 * recorder sent.
 */
async function replay(name: string): Promise<SessionView> {
  const answers = new Map<string, JsonObject>();
  for (const line of splitLines(await fixtureFile(inFiles, name, "in"))) {
    const answer = asJsonObject(JSON.parse(line), `${name}.in.jsonl line`);
    if (answer.type === "extension_ui_response" && typeof answer.id === "string") answers.set(answer.id, answer);
  }
  const decoder = new RpcFrameDecoder();
  let view = sessionView();
  let entriesSeeded = false;
  for (const line of splitLines(await fixtureFile(outFiles, name, "out"))) {
    const frame = decoder.push(line);
    if (frame === undefined) continue;
    if (frame.type === "response" && frame.success === true && typeof frame.command === "string") {
      const data = frame.data;
      if (frame.command === "get_state") view = withState(view, asJsonObject(data, "get_state"));
      if (frame.command === "get_messages_page") {
        view = withMessages(view, objects(asJsonObject(data, "page").messages));
      }
      if (frame.command === "get_entries" && !entriesSeeded) {
        entriesSeeded = true;
        const entries = asJsonObject(data, "entries");
        view = withEntries(view, objects(entries.entries), { leafId: entries.leafId as string | undefined });
      }
      if (frame.command === "get_subagents") {
        view = withSubagents(view, objects(asJsonObject(data, "subagents").subagents));
      }
    }
    if (frame.type === "ompx" && frame.kind === "reply" && frame.ok === true && typeof frame.callId === "string") {
      const result = asJsonObject(frame.result, "ompx result");
      if (frame.callId.endsWith(":snapshot")) view = withCompanionSnapshot(view, result);
      if (frame.callId.endsWith(":queue")) view = withCompanionSnapshot(view, { queue: result });
    }
    view = reduce(view, frame);
    if ((frame.type === "extension_ui_request" || frame.type === "ompx") && typeof frame.id === "string") {
      const answer = answers.get(frame.id);
      if (answer !== undefined) view = reduce(view, answer);
    }
  }
  return view;
}

const started = Date.UTC(2026, 9, 30, 9, 41);

function user(text: string, index: number): JsonObject {
  return { role: "user", content: text, timestamp: started + index * 60_000 };
}

function assistant(content: JsonObject[], index: number, extra: JsonObject = {}): JsonObject {
  return {
    role: "assistant",
    content,
    provider: "anthropic",
    model: "claude-sonnet-4-5",
    usage: { input: 1840, output: 912, cacheRead: 22_310, totalTokens: 25_062, cost: { total: 0.0213 } },
    stopReason: "stop",
    duration: 14_200,
    timestamp: started + index * 60_000 + 30_000,
    ...extra,
  };
}

function items(messages: JsonObject[]): TranscriptItem[] {
  return messages.flatMap((message, index) => decodeMessage(message, { entryId: `g${index}` }) ?? []);
}

function answerView(): SessionView {
  return sessionView({
    transcript: items([
      user("Write me a field guide to the markdown you render: every block kind, with examples.", 0),
      assistant([{ type: "text", text: answer }], 0),
    ]),
  });
}

/** Every message row, then a prompt on its way with the wait for its reply. */
function messagesView(): SessionView {
  const message = items([user("And now the release notes, please.", 99)])[0] as UserItem;
  // A running session: its latest turn shows every row instead of folding them.
  return sessionView({
    transcript: messageGallery(),
    pendingPrompt: { message },
    run: { running: true, outcome: runIdle, paused: false },
  });
}

const sgrColors = ["black", "red", "green", "yellow", "blue", "magenta", "cyan", "white"];

function sgr(code: number | string, text: string): string {
  return `\u001b[${code}m${text}\u001b[0m`;
}

/** A command whose output shows the 16 colours on the surface and as backgrounds, the attributes and the wider sets. */
function ansiView(): SessionView {
  const output = [
    sgrColors.map((color, index) => sgr(30 + index, color)).join(" "),
    sgrColors.map((color, index) => sgr(90 + index, color)).join(" "),
    sgrColors.map((_, index) => sgr(40 + index, ` ${40 + index} `)).join(""),
    sgrColors.map((_, index) => sgr(100 + index, ` ${100 + index} `)).join(""),
    [sgr(1, "bold"), sgr(2, "dim"), sgr(3, "italic"), sgr(4, "underline"), sgr(9, "strike"), sgr(7, "inverse")].join(
      " ",
    ),
    [sgr("31;7", "red inverse"), sgr("30;47", "black on white"), sgr("97;44", "bright white on blue")].join(" "),
    [sgr("38;5;208", "xterm 208"), sgr("38;5;33", "xterm 33"), sgr("38;2;255;105;180", "24-bit #FF69B4")].join(" "),
    `${sgr(32, "✓")} 41 pass  ${sgr(31, "✗ 1 fail")}  ${sgr(33, "2 warnings")} ${sgr(2, "[1.20s]")}`,
  ].join("\n");
  return sessionView({
    transcript: items([
      user("Show me the terminal's colours.", 0),
      assistant([{ type: "toolCall", id: "colors", name: "bash", arguments: { command: "sh scripts/colors.sh" } }], 0, {
        stopReason: "toolUse",
      }),
      {
        role: "toolResult",
        toolCallId: "colors",
        toolName: "bash",
        content: [{ type: "text", text: output }],
        isError: false,
        timestamp: started + 40_000,
      },
      assistant([{ type: "text", text: "Those are the sixteen colours, then the same as backgrounds." }], 0),
    ]),
  });
}

/** 500 turns of four rows each: a prompt, a reply with a paragraph and a list, a tool call, a closing paragraph. */
function longView(): SessionView {
  const messages: JsonObject[] = [];
  for (let turn = 0; turn < 500; turn++) {
    const id = `call-${turn}`;
    messages.push(user(`Step ${turn + 1}: check the parser on input ${turn}.`, turn));
    messages.push(
      assistant(
        [
          { type: "text", text: `Turn ${turn + 1}. The parser reads **${turn}** like this:\n\n- tokens\n- tree` },
          { type: "toolCall", id, name: "bash", arguments: { command: `bun test parser --seed ${turn}` } },
        ],
        turn,
        { stopReason: "toolUse" },
      ),
    );
    messages.push({
      role: "toolResult",
      toolCallId: id,
      toolName: "bash",
      content: [{ type: "text", text: `✓ parser ${turn}\n1 pass` }],
      isError: false,
      timestamp: started + turn * 60_000 + 40_000,
    });
    messages.push(assistant([{ type: "text", text: `Seed ${turn} passes.` }], turn));
  }
  return sessionView({ transcript: items(messages) });
}

async function load(name: string): Promise<SessionView> {
  switch (name) {
    case "answer":
      return answerView();
    case "tools":
      // A running session: its one turn shows every row instead of folding them.
      return sessionView({
        transcript: toolGallery(),
        subagents: toolGallerySubagents(),
        run: { running: true, outcome: runIdle, paused: false },
      });
    case "messages":
      return messagesView();
    case "ansi":
      return ansiView();
    case "long":
      return longView();
    default:
      return replay(name);
  }
}

const actions: TranscriptActions = {
  onBranchFrom: (entryId) => showSnackBar(`branch from ${entryId}`),
  onResetTo: (entryId, kind) => showSnackBar(`reset to ${entryId} (${kind})`),
  canReset: true,
  onCopy: (text) => void navigator.clipboard.writeText(text).then(() => showSnackBar("copied")),
  onOpenFile: (path, options) => showSnackBar(`open ${path}${options?.line ? `:${options.line}` : ""}`),
  onOpenSubagent: (id) => showSnackBar(`open subagent ${id}`),
};

/**
 * `stream`: answer.md streaming into a reply, 512 bytes every 16 ms (eight times the bench's pace), with the run going
 * until it is whole. Before every update it checks that the blocks above the growing one in the last row kept their
 * DOM nodes (a settled block never renders again) and reports the count when the reply is whole.
 */
function Stream() {
  const prompt = items([user("Stream the field guide.", 0)]);
  const [length, setLength] = createSignal(0);
  const [report, setReport] = createSignal("");
  const view = createMemo(() => {
    const streaming = length() < answer.length;
    const reply = decodeAssistant(assistant([{ type: "text", text: answer.slice(0, length()) }], 0), {
      entryId: "reply",
      streaming,
    });
    return sessionView({ transcript: [...prompt, reply], run: { running: streaming, outcome: runIdle, paused: false } });
  });
  onSettled(() => {
    const startedAt = performance.now();
    let settled: { block: Element; row: Element }[] = [];
    let kept = 0;
    let lost = 0;
    let updates = 0;
    const timer = setInterval(() => {
      for (const { block, row } of settled) {
        if (!row.isConnected) continue;
        if (block.isConnected) kept++;
        else lost++;
      }
      const rows = document.querySelectorAll(".transcript-row");
      const row = rows[rows.length - 1];
      settled = row ? [...row.querySelectorAll(".markdown > .markdown-block")].slice(0, -1).map((block) => ({ block, row })) : [];
      const next = Math.min(answer.length, Math.floor((performance.now() - startedAt) / 16) * 512);
      if (next === length()) return;
      updates++;
      setLength(next);
      if (next < answer.length) return;
      clearInterval(timer);
      setReport(`stream: ${updates} updates · settled blocks kept ${kept} of ${kept + lost}`);
    }, 16);
    return () => clearInterval(timer);
  });
  return (
    <>
      <TranscriptView view={view()} actions={actions} />
      <Show when={report()}>
        <div class="gallery-measure">{report()}</div>
      </Show>
    </>
  );
}

/**
 * `history`: the last 100 items of the `long` transcript, loading 200 earlier ones each time the reader nears the top
 * (the gallery starts there). Reports how far the row at the top edge moved across each load: loading earlier
 * history must move nothing on screen.
 */
function History() {
  const all = longView().transcript;
  const [start, setStart] = createSignal(all.length - 100);
  const view = createMemo(() => sessionView({ transcript: all.slice(start()), historyLength: all.length - start() }));
  const [report, setReport] = createSignal("");
  let pages = 0;
  let moved = 0;
  const loadEarlier = async () => {
    const edge = document.querySelector(".transcript-scroll")?.getBoundingClientRect().top ?? 0;
    const rows = [...document.querySelectorAll<HTMLElement>(".transcript-row")];
    const row = rows.find((candidate) => candidate.getBoundingClientRect().bottom > edge);
    const before = row?.getBoundingClientRect().top ?? 0;
    setStart((value) => Math.max(0, value - 200));
    const frames = deferred<void>();
    requestAnimationFrame(() => requestAnimationFrame(() => frames.resolve()));
    await frames.promise;
    const after = row?.isConnected ? row.getBoundingClientRect().top : Number.NaN;
    moved = Math.max(moved, Math.abs(after - before));
    pages++;
    setReport(`history: ${pages} pages loaded · top row moved ${Math.round(moved * 10) / 10} px`);
  };
  return (
    <>
      <TranscriptView view={view()} actions={{ ...actions, onLoadEarlier: loadEarlier }} />
      <Show when={report()}>
        <div class="gallery-measure">{report()}</div>
      </Show>
      <ScrollTo top={0} />
    </>
  );
}

/** Rows built and the time from the view's arrival to its first frame, for the `long` fixture. */
function Measure(props: { since: number; items: number }) {
  const [text, setText] = createSignal("");
  onSettled(() => {
    requestAnimationFrame(() =>
      requestAnimationFrame(() => {
        const built = document.querySelectorAll(".transcript-row").length;
        const ms = Math.round(performance.now() - props.since);
        setText(`${props.items} items · ${built} rows built · first frame ${ms} ms`);
      }),
    );
  });
  return <div class="gallery-measure">{text()}</div>;
}

/**
 * `&scroll=<px>`: scrolls the transcript from its top down to that offset once it is on screen, 300 px a frame as a
 * reader would, so the rows on the way are built and measured: one jump into rows not built yet lands on estimated
 * heights, and a jump to their estimated bottom pins the list there. Each step is a wheel event and its scroll: the
 * view takes only the reader's scrolls as leaving the bottom.
 */
function ScrollTo(props: { top: number }) {
  onSettled(() => {
    let at = 0;
    const step = () => {
      const scroller = document.querySelector(".transcript-scroll");
      if (!scroller) return;
      scroller.dispatchEvent(new WheelEvent("wheel", { deltaY: at - scroller.scrollTop }));
      scroller.scrollTop = at;
      if (at >= props.top) return;
      at = Math.min(props.top, at + 300);
      requestAnimationFrame(step);
    };
    requestAnimationFrame(() => requestAnimationFrame(step));
  });
  return null;
}

/** `&open=1`: opens every closed tool line once the transcript is on screen. */
function OpenTools() {
  onSettled(() => {
    requestAnimationFrame(() => {
      for (const line of document.querySelectorAll<HTMLElement>('.tool-card-line[aria-expanded="false"]')) line.click();
    });
  });
  return null;
}

export default function TranscriptGallery() {
  const query = new URLSearchParams(location.search);
  const name = query.get("fixture");
  const width = Number(query.get("width") ?? "0");
  const open = query.get("open") === "1";
  // `&open=1` also opens every settled turn.
  const turns = new TurnExpansion();
  let since = 0;
  // Lazy: the `stream` scenario builds its own views.
  const view = createMemo(
    async () => {
      const loaded = await load(name ?? "answer");
      if (open) for (const item of loaded.transcript) if (item.kind === "UserItem") turns.setOpen(item, true);
      since = performance.now();
      return loaded;
    },
    { lazy: true },
  );
  return (
    <Show
      when={name}
      fallback={
        <nav class="gallery-index">
          <For each={scenarios}>{(scenario) => <a href={`?gallery=transcript&fixture=${scenario}`}>{scenario}</a>}</For>
        </nav>
      }
    >
      <div class="gallery-pane" style={width > 0 ? { "max-width": `${width}px` } : undefined}>
        <Switch>
          <Match when={name === "stream"}>
            <Stream />
          </Match>
          <Match when={name === "history"}>
            <History />
          </Match>
          <Match when={true}>
            <Loading>
              <TranscriptView view={view()} actions={actions} turns={turns} />
              <Show when={name === "long"}>
                <Measure since={since} items={view().transcript.length} />
              </Show>
              <Show when={open}>
                <OpenTools />
              </Show>
              <Show when={query.get("scroll")}>{(scroll) => <ScrollTo top={Number(scroll())} />}</Show>
            </Loading>
          </Match>
        </Switch>
      </div>
    </Show>
  );
}
