// Port of test/screens/chat/composer_intent_test.dart.
import { describe, expect, test } from "bun:test";
import type { SlashCommand } from "../../../core/store/session_view";
import { type ComposerIntent, composerIntent } from "./composer_intent";

function command(name: string, source: string, aliases: string[] = []): SlashCommand {
  return { name, aliases, source, subcommands: [] };
}

const commands = [
  command("compact", "builtin"),
  command("force", "builtin", ["force:"]),
  command("pause", "extension"),
  command("skill:review", "skill", ["review"]),
];

function intent(text: string, options: { running?: boolean; followUp?: boolean; attachments?: boolean } = {}) {
  return composerIntent(text, {
    hasAttachments: options.attachments ?? false,
    running: options.running ?? false,
    followUp: options.followUp ?? false,
    commands,
  });
}

function as<K extends ComposerIntent["kind"]>(value: ComposerIntent, kind: K): Extract<ComposerIntent, { kind: K }> {
  expect(value.kind).toBe(kind);
  return value as Extract<ComposerIntent, { kind: K }>;
}

describe("prompts", () => {
  test("an idle session gets a plain prompt, trimmed", () => {
    const sent = as(intent("  fix the bug \n"), "SendPrompt");
    expect(sent.text).toBe("fix the bug");
    expect(sent.behavior).toBeUndefined();
  });

  test("while a run streams Enter steers and the modifier queues a follow-up", () => {
    expect(as(intent("stop that", { running: true }), "SendPrompt").behavior).toBe("steer");
    expect(as(intent("then this", { running: true, followUp: true }), "SendPrompt").behavior).toBe("followUp");
  });

  test("the follow-up modifier does nothing while idle", () => {
    expect(as(intent("hi", { followUp: true }), "SendPrompt").behavior).toBeUndefined();
  });

  test("attachments alone are a prompt; nothing at all is not", () => {
    expect(intent("", { attachments: true }).kind).toBe("SendPrompt");
    expect(intent("   ").kind).toBe("NothingToSend");
  });
});

describe("slash commands", () => {
  test("a listed command is sent as prompt text, arguments included", () => {
    const sent = as(intent("/compact keep the API notes"), "SendPrompt");
    expect(sent.text).toBe("/compact keep the API notes");
    expect(sent.command).toBe("compact");
  });

  test("aliases count", () => {
    expect(as(intent("/review"), "SendPrompt").command).toBe("skill:review");
  });

  test("a command while running steers like text", () => {
    expect(as(intent("/pause", { running: true }), "SendPrompt").behavior).toBe("steer");
  });

  test("an unlisted command is never sent", () => {
    expect(as(intent("/plan make it faster"), "UnknownCommand").name).toBe("plan");
  });

  test("a path is a prompt, not a command", () => {
    expect(intent("/usr/bin/env is missing").kind).toBe("SendPrompt");
    expect(as(intent("/tmp/x.log"), "SendPrompt").command).toBeUndefined();
  });

  // omp ends extension, custom and file command names at the first space only; `pause⏎now` would be no command and go
  // to the model.
  test("arguments after a new line or tab are sent after a space", () => {
    expect(as(intent("/pause\nfor a minute"), "SendPrompt").text).toBe("/pause for a minute");
    expect(as(intent("/pause\tnow\nand later"), "SendPrompt").text).toBe("/pause now\nand later");
    expect(as(intent("/pause  twice"), "SendPrompt").text).toBe("/pause  twice");
  });

  test("a builtin takes its arguments after a colon too", () => {
    const sent = as(intent("/force:bash list the files"), "SendPrompt");
    expect(sent.text).toBe("/force:bash list the files");
    expect(sent.command).toBe("force");
    expect(as(intent("/force:"), "SendPrompt").command).toBe("force");
  });

  test("only builtins split at a colon", () => {
    expect(intent("/pause:now").kind).toBe("UnknownCommand");
  });

  test("a bare slash sends nothing", () => {
    expect(intent("/").kind).toBe("NothingToSend");
  });
});

describe("shell and Python", () => {
  test("! runs bash in context, !! outside it", () => {
    const bash = as(intent("!ls -la"), "RunBash");
    expect(bash.command).toBe("ls -la");
    expect(bash.excludeFromContext).toBe(false);
    const quiet = as(intent("!! git status"), "RunBash");
    expect(quiet.command).toBe("git status");
    expect(quiet.excludeFromContext).toBe(true);
  });

  test("$ runs Python in context, $$ outside it", () => {
    const python = as(intent("$print(1)"), "RunPython");
    expect(python.code).toBe("print(1)");
    expect(python.excludeFromContext).toBe(false);
    expect(as(intent("$$ x = 2"), "RunPython").excludeFromContext).toBe(true);
  });

  test("exec wins over streaming: it never becomes a steer", () => {
    expect(intent("!make", { running: true }).kind).toBe("RunBash");
  });

  test("a bare prefix sends nothing", () => {
    expect(intent("!").kind).toBe("NothingToSend");
    expect(intent("!!  ").kind).toBe("NothingToSend");
    expect(intent("$$").kind).toBe("NothingToSend");
  });
});
