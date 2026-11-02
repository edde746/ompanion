// Port of test/screens/chat/{slash_palette,model_mention_palette}_test.dart.
import { describe, expect, test } from "bun:test";
import { type RpcModel, rpcModelFromJson } from "../../../core/rpc/results";
import type { SlashCommand } from "../../../core/store/session_view";
import { collapsedAt } from "../../sessions/composer_draft";
import {
  filterCommands,
  filterModels,
  mentionQuery,
  modelDisplayName,
  modelSelector,
  paletteQuery,
} from "./composer_palettes";

function command(name: string, source: string, aliases: string[] = []): SlashCommand {
  return { name, aliases, source, subcommands: [] };
}

const commands = [
  command("session", "builtin"),
  command("compact", "builtin", ["squash"]),
  command("copy", "builtin"),
  command("model", "builtin"),
  command("ompx", "extension"),
  command("pause", "extension"),
];

const names = (query: string) => filterCommands(commands, query).map((command) => command.name);

describe("paletteQuery", () => {
  test("is the name typed after the slash", () => {
    expect(paletteQuery("/")).toBe("");
    expect(paletteQuery("/com")).toBe("com");
  });

  test("closes at the first space, for arguments", () => {
    expect(paletteQuery("/compact now")).toBeUndefined();
  });

  test("is absent for paths and plain text", () => {
    expect(paletteQuery("/usr/bin")).toBeUndefined();
    expect(paletteQuery("hello /com")).toBeUndefined();
  });
});

describe("filterCommands", () => {
  test("an empty query lists every command in session order", () => {
    expect(names("")).toEqual(commands.map((command) => command.name));
  });

  test("ranks name prefix, then alias prefix, then substring, then letters in order", () => {
    expect(names("co")).toEqual(["compact", "copy"]);
    expect(names("sq")).toEqual(["compact"]);
    expect(names("ss")).toEqual(["session"]);
    expect(names("mdl")).toEqual(["model"]);
  });

  test("orders every match by rank, not by session order", () => {
    expect(names("s")).toEqual(["session", "compact", "pause"]);
  });

  test("is case-insensitive", () => {
    expect(names("PAU")).toEqual(["pause"]);
  });

  test("drops commands that do not match", () => {
    expect(names("xyz")).toEqual([]);
  });
});

function model(provider: string, id: string, name: string): RpcModel {
  return rpcModelFromJson({ provider, id, name, reasoning: false, input: ["text"] });
}

/** `text` with the cursor at `|`, or at the end without one. */
function query(text: string) {
  const cursor = text.indexOf("|");
  const plain = text.replace("|", "");
  return mentionQuery({ text: plain, selection: collapsedAt(cursor < 0 ? plain.length : cursor) });
}

describe("mentionQuery", () => {
  test("is the token from a ^ that starts the text or follows whitespace, up to the cursor", () => {
    expect(query("^")).toEqual({ start: 0, query: "" });
    expect(query("Have ^fake/fa")).toEqual({ start: 5, query: "fake/fa" });
    expect(query("line\n^op| rest")).toEqual({ start: 5, query: "op" });
  });

  test("is absent inside a word, after the token ended, or with a selection", () => {
    expect(query("x^fake")).toBeUndefined();
    expect(query("^fake/fake-1 ")).toBeUndefined();
    expect(mentionQuery({ text: "a ^b", selection: { start: 2, end: 4 } })).toBeUndefined();
  });

  test("is absent in a ! or $ draft, which runs as typed", () => {
    for (const text of ["!echo ^", "  !!ls ^fa", '$print("^")', "$$ x = ^"]) expect(query(text)).toBeUndefined();
    // A command argument takes mentions.
    expect(query("/btw ask ^")).toEqual({ start: 9, query: "" });
  });
});

test("the model omp matches a mention against is provider/id; its name drops quotes and falls back to the id", () => {
  expect(modelSelector(model("fake", "fake-1", "Fake One"))).toBe("fake/fake-1");
  expect(modelDisplayName(model("fake", "fake-1", ' Say "hi" '))).toBe("Say hi");
  expect(modelDisplayName(model("fake", "fake-1", "  "))).toBe("fake-1");
});

test("the list keeps models holding the query in their selector or name, by provider, then name", () => {
  const models = [
    model("zeta", "z-think", "Zed Think"),
    model("fake", "fake-think", "Fake Think"),
    model("fake", "fake-1", "Fake One"),
    model("anthropic", "claude-opus", "Opus"),
  ];
  const selectors = (text: string) => filterModels(models, text).map(modelSelector);
  expect(selectors("")).toEqual(["anthropic/claude-opus", "fake/fake-1", "fake/fake-think", "zeta/z-think"]);
  expect(selectors("THINK")).toEqual(["fake/fake-think", "zeta/z-think"]);
  expect(selectors("fake/fake-t")).toEqual(["fake/fake-think"]);
  expect(selectors("opus")).toEqual(["anthropic/claude-opus"]);
  expect(selectors("nothing")).toEqual([]);
});
