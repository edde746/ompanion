// The tool-card cases of test/transcript/transcript_view_test.dart ("an ask waiting for its answer…", "tool output
// footers") and test/transcript/chat_images_test.dart ("tool cards"), as the parsing they rest on.
import { describe, expect, test } from "bun:test";
import type { JsonObject } from "../../../../core/rpc/json_fields";
import type { ContentBlock, ToolCallBlock } from "../../../../core/store/content";
import {
  assistantItem,
  type StopReason,
  toolResultItem,
  type ToolState,
} from "../../../../core/store/transcript";
import {
  askQuestions,
  askWaits,
  bashCall,
  evalCall,
  imageType,
  readCall,
  type ToolData,
  toolData,
} from "./tool_data";
import { toolRowCall, toolRowOrphan } from "./transcript_rows";

const textBlock = (text: string): ContentBlock => ({ kind: "TextBlock", text });

const png = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=";

/** A call of `tool` with `args` in an assistant message, and its result when `result` has a state. */
function called(
  tool: string,
  args: JsonObject,
  result: { state?: ToolState; content?: ContentBlock[]; details?: unknown; isError?: boolean },
  stopReason: StopReason = "toolUse",
): ToolData {
  const call: ToolCallBlock = { kind: "ToolCallBlock", id: "c1", name: tool, arguments: args };
  const owner = assistantItem({ timestamp: 2, content: [call], provider: "fake", model: "fake-1", stopReason });
  const { state, ...fields } = result;
  return toolData({
    row: toolRowCall({ owner, index: 0, call }),
    result: state === undefined ? undefined : toolResultItem({ toolCallId: "c1", toolName: tool, state, ...fields }),
    subagents: [],
  });
}

/** chat_images_test's `card`: a done result whose call is not in the transcript. */
function orphan(tool: string, fields: { args: JsonObject; content: ContentBlock[]; details?: unknown }): ToolData {
  const result = toolResultItem({ toolCallId: "call-1", toolName: tool, state: "done", ...fields });
  return toolData({ row: toolRowOrphan({ orphan: result }), result, subagents: [] });
}

test("a call's status follows its result; a call its message abandoned did not finish", () => {
  const args = { command: "ls" };
  expect(called("bash", args, {}).status).toBe("pending");
  expect(called("bash", args, {}, "aborted").status).toBe("interrupted");
  expect(called("bash", args, { state: "running" }).status).toBe("running");
  expect(called("bash", args, { state: "background" }).status).toBe("background");
  expect(called("bash", args, { state: "interrupted" }).status).toBe("interrupted");
  expect(called("bash", args, { state: "done" }).status).toBe("done");
  expect(called("bash", args, { state: "done", isError: true }).status).toBe("failed");
});

test("an ask waiting for its answer shows one line, and the answer once it came", () => {
  const args = {
    i: "Asking for a choice",
    questions: [
      {
        id: "pick",
        question: "Which option should the demo take?",
        options: [{ label: "Option A" }, { label: "Option B" }],
      },
    ],
  };
  // The run goes on while the ask waits and after it is answered.
  const waiting = called("ask", args, { state: "running" });
  expect(waiting.intent).toBe("Asking for a choice");
  expect(askWaits(waiting)).toBe(true);

  const answered = called("ask", args, {
    state: "done",
    content: [textBlock("User answers:\npick: Option A")],
    details: {
      results: [
        {
          id: "pick",
          question: "Which option should the demo take?",
          options: ["Option A", "Option B"],
          selectedOptions: ["Option A"],
        },
      ],
    },
  });
  expect(askWaits(answered)).toBe(false);
  const [question, ...rest] = askQuestions(answered);
  expect(rest).toEqual([]);
  expect(question?.question).toBe("Which option should the demo take?");
  expect(question?.options.map((option) => option.label)).toEqual(["Option A", "Option B"]);
  expect(question?.selected).toEqual(["Option A"]);
  expect(question?.answered).toBe(true);
});

describe("tool output footers", () => {
  const output = (text: string, details: JsonObject) =>
    bashCall(called("bash", { command: "timed" }, { state: "done", content: [textBlock(text)], details })).output;

  test("bash hides the wall-time footer omp appended, and keeps a command's own one", () => {
    // omp 18.10.3 appends no footer to a run under a second.
    expect(output("Wall time: 0.50 seconds", { wallTimeMs: 500, wallTimeNoticeEmitted: false })).toBe(
      "Wall time: 0.50 seconds",
    );
    expect(
      output("Wall time: 0.50 seconds\n\nWall time: 1.50 seconds", { wallTimeMs: 1500, wallTimeNoticeEmitted: true }),
    ).toBe("Wall time: 0.50 seconds");
    // Older omp appends the footer to every run and has no `wallTimeNoticeEmitted`.
    expect(output("Wall time: 0.50 seconds\n\nWall time: 0.60 seconds", { wallTimeMs: 600 })).toBe(
      "Wall time: 0.50 seconds",
    );
  });

  test("eval keeps a wall-time line: omp appends none to it", () => {
    const data = called(
      "eval",
      { language: "py", code: "timed()" },
      { state: "done", content: [textBlock("done\nWall time: 1.50 seconds")], details: {} },
    );
    expect(evalCall(data).output).toBe("done\nWall time: 1.50 seconds");
  });
});

describe("tool cards", () => {
  const meta = { source: { type: "path", value: "/home/u/proj/pic.png" } };

  test("an image read shows the image, open, with its size and type", () => {
    const data = orphan("read", {
      args: { path: "pic.png" },
      content: [textBlock("Read image file [image/png]"), { kind: "InlineImageBlock", data: png, mimeType: "image/png" }],
      details: { fileSize: 26672, meta },
    });
    const call = readCall(data);
    expect(data.images.length).toBe(1);
    expect(call.pixels).toEqual({ width: 1, height: 1 });
    expect(imageType(data.images[0]?.mimeType ?? "")).toBe("PNG");
    expect(call.text).toBeUndefined();
    expect(call.fromMachine).toBe(false);
  });

  test("a text read stays closed until tapped", () => {
    const data = orphan("read", {
      args: { path: "notes.md" },
      content: [textBlock("alpha\nbeta")],
      details: { displayContent: { text: "alpha\nbeta", startLine: 1 }, totalLines: 2 },
    });
    const call = readCall(data);
    expect(data.images).toEqual([]);
    expect(call.fromMachine).toBe(false);
    expect(call.lines).toEqual(["alpha", "beta"]);
    expect(call.gutter).toEqual([1, 2]);
    expect(call.range).toEqual({ from: 1, to: 2 });
    expect(call.totalLines).toBe(2);
  });

  test("an image read by a model without image input shows the file from the machine", () => {
    const call = readCall(
      orphan("read", {
        args: { path: "pic.png" },
        content: [textBlock("Image metadata:\n- MIME: image/png\n- Dimensions: 640x360")],
        details: { fileSize: 26672, meta },
      }),
    );
    expect(call.fromMachine).toBe(true);
    expect(call.target).toBe("/home/u/proj/pic.png");
  });

  test("an image omp keeps in its blob store loads from the blob beside the session file", () => {
    const hash = "ab".repeat(32);
    const data = orphan("read", {
      args: { path: "pic.png" },
      content: [textBlock("Read image file [image/png]"), { kind: "BlobImageBlock", hash, mimeType: "image/png" }],
    });
    expect(data.images).toEqual([{ kind: "BlobImageBlock", hash, mimeType: "image/png" }]);
    expect(imageType(data.images[0]?.mimeType ?? "")).toBe("PNG");
    expect(readCall(data).pixels).toBeUndefined();
    expect(readCall(data).fromMachine).toBe(false);
  });
});
