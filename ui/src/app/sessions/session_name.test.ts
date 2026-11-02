// Port of test/sessions/session_name_test.dart.
import { expect, test } from "bun:test";
import type { SessionSummary } from "../../core/host/session_listing";
import { sessionView } from "../../core/store/session_view";
import { userItem } from "../../core/store/transcript";
import { firstUserMessage, liveSessionName, sessionName } from "./session_name";

function user(text: string, options: { synthetic?: boolean; attribution?: string } = {}) {
  return userItem({ timestamp: text.length, content: [{ kind: "TextBlock", text }], ...options });
}

function file(options: { title?: string; firstMessage?: string } = {}): SessionSummary {
  return { path: "/s.jsonl", size: 1, modifiedMs: Date.UTC(2026, 0, 1), id: "s", ...options };
}

test("the omp title wins over the first message", () => {
  expect(sessionName({ title: "Fix the login", firstMessage: "hello" })).toBe("Fix the login");
});

test("without a title the first message names the session, on one line", () => {
  expect(sessionName({ title: "  ", firstMessage: "  refactor the\n\n  parser\tplease " })).toBe(
    "refactor the parser please",
  );
});

test("a title from the first message leaves out its file mentions and local:// references", () => {
  expect(
    sessionName({
      firstMessage:
        'Please review these. @"/Users/x/.omp/agent/sessions/-p/2026/local/meeting notes.txt" ' +
        "@src/foo.ts\nand local://paste-1.md",
    }),
  ).toBe("Please review these. and");
});

test("a first message of mentions only is named after its first file", () => {
  expect(sessionName({ firstMessage: '@"/tmp/up/meeting notes.txt" @b.md' })).toBe("meeting notes.txt");
  expect(sessionName({ firstMessage: " local://paste-2.md " })).toBe("paste-2.md");
});

test("a quoted mention the listing cut short leaves no path fragment in the title", () => {
  expect(sessionName({ firstMessage: 'Please review these. @"/tmp/AttachmentDelivery-home/.omp/agent/sess' })).toBe(
    "Please review these.",
  );
});

test("a tagged model names itself in a title from the first message; a tag the listing cut short drops", () => {
  expect(sessionName({ firstMessage: 'Have <model agent="m1" name="Fake Think"/> review this change' })).toBe(
    "Have Fake Think review this change",
  );
  expect(sessionName({ firstMessage: 'Have <model agent="m1" name="Fake Th' })).toBe("Have");
});

test("a session with neither is a new session", () => {
  expect(sessionName({})).toBe("New session");
  expect(sessionName({ firstMessage: " \n " })).toBe("New session");
});

test("the first message typed by the user, not an injected one", () => {
  const view = sessionView({
    transcript: [
      user("auto-continue", { synthetic: true }),
      user("handoff context", { attribution: "agent" }),
      user("add a dark theme", { attribution: "user" }),
      user("and a light one"),
    ],
  });
  expect(firstUserMessage(view)).toBe("add a dark theme");
  expect(firstUserMessage(sessionView())).toBeUndefined();
});

test("an open session is named like its file in the sidebar, then by its transcript", () => {
  const view = sessionView({ transcript: [user("a later page of the transcript")] });
  expect(liveSessionName(view, file({ firstMessage: "the first prompt" }))).toBe("the first prompt");
  expect(liveSessionName(view, undefined)).toBe("a later page of the transcript");
  const titled = sessionView({ config: { ...sessionView().config, sessionName: "Titled" } });
  expect(liveSessionName(titled, file({ firstMessage: "x" }))).toBe("Titled");
});
