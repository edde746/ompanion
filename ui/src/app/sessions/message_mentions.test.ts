// Port of test/sessions/message_mentions_test.dart.
import { expect, test } from "bun:test";
import {
  type MessageMention,
  messageMentionFolder,
  messageMentionName,
  messageMentionUrl,
  splitMentions,
} from "./message_mentions";
import { assembleMessage, fileMention } from "./prompt_attachments";

/** Text parts as they are, mentions as `<path>`, tagged models as `[agent name]`. */
function split(message: string): string[] {
  return splitMentions(message).map((part) => {
    switch (part.kind) {
      case "MessageText":
        return part.source;
      case "MessageMention":
        return `<${part.path}>`;
      case "MessageModel":
        return `[${part.agent} ${part.name}]`;
    }
  });
}

const mentions = (message: string): MessageMention[] =>
  splitMentions(message).filter((part): part is MessageMention => part.kind === "MessageMention");

test("the parts of a message join back to the exact message", () => {
  const message = "Review @\"/tmp/a b.txt\", (@src/x.ts) and local://paste-2.md.\n@'it\"s.md' done";
  expect(
    splitMentions(message)
      .map((part) => part.source)
      .join(""),
  ).toBe(message);
});

test("a model tag omp wrote is one part with its pseudonym and name; mentions around it still count", () => {
  const message = 'Have <model agent="m1" name="Fake Think"/> review @src/a.ts, then <model agent="m12" name=""/>.';
  expect(split(message)).toEqual(["Have ", "[m1 Fake Think]", " review ", "<src/a.ts>", ", then ", "[m12 ]", "."]);
  expect(
    splitMentions(message)
      .map((part) => part.source)
      .join(""),
  ).toBe(message);
});

test("text that only resembles a model tag stays text, as omp leaves it", () => {
  for (const message of ['<model agent="x1" name="A"/>', '<model agent="m1" name="A">', "^fake/fake-1 please"]) {
    expect(split(message)).toEqual([message]);
  }
});

test("the mentions the app writes for attachments come back as their paths", () => {
  const paths = ["/Users/x/.omp/agent/sessions/-proj/2026-01/local/meeting notes.txt", '/tmp/say "hi".md'];
  const message = assembleMessage(
    "Please review these.",
    paths.map((path) => fileMention(path)!),
  );
  expect(split(message)).toEqual(["Please review these. ", `<${paths[0]}>`, " ", `<${paths[1]}>`]);
});

test("an unquoted mention loses the punctuation around it as omp strips it", () => {
  expect(split('see @src/foo.ts, then (@lib/a.dart) and "@b.md"!')).toEqual([
    "see ",
    "<src/foo.ts>",
    ", then (",
    "<lib/a.dart>",
    ') and "',
    "<b.md>",
    '"!',
  ]);
  expect(split("@(`x`)")).toEqual(["<x>", "`)"]);
});

test("a quoted mention keeps its punctuation and loses only surrounding whitespace", () => {
  expect(split('@" notes (v2).txt " ok')).toEqual(["<notes (v2).txt>", " ok"]);
});

test("omp reads no mention inside a word, in an empty or blank quote, or made only of punctuation", () => {
  for (const message of ["mail me at me@example.com", 'x@"a.md"', '@"" then', '@" " then', "wow @!!", "@ alone"]) {
    expect(mentions(message)).toEqual([]);
  }
});

test("a mention ends at the next @, which starts a mention only after a boundary", () => {
  expect(split("@a.md@b.md @c.md")).toEqual(["<a.md>", "@b.md ", "<c.md>"]);
});

test("a local:// reference is a mention, cut like an unquoted one", () => {
  expect(split("Log: local://paste-3.md.")).toEqual(["Log: ", "<local://paste-3.md>", "."]);
  expect(split("@local://paste-1.md")).toEqual(["<local://paste-1.md>"]);
  expect(split("not a local:// thing, nor xlocal://y")).toEqual(["not a local:// thing, nor xlocal://y"]);
});

test("a mention's name is its path's last segment; a local:// one is no machine path", () => {
  const [file, folder, windows, paste] = mentions(
    '@"/tmp/meeting notes.txt" @src/widgets/ @"C:\\Users\\x\\a b.log" local://paste-1.md',
  ) as [MessageMention, MessageMention, MessageMention, MessageMention];
  expect([file, folder, windows, paste].map(messageMentionName)).toEqual([
    "meeting notes.txt",
    "widgets",
    "a b.log",
    "paste-1.md",
  ]);
  expect([file, folder, paste].map(messageMentionFolder)).toEqual([false, true, false]);
  expect([file, windows, paste].map(messageMentionUrl)).toEqual([false, false, true]);
});
