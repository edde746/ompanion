// An in-page core for a plain browser: the core.* methods, an echoing PTY, a pretend SSH machine, and an omp that
// replays harness fixtures as its stdout, so every view runs without a shell.
import textStream from "../../harness/fixtures/text-stream.out.jsonl?raw";
import toolBash from "../../harness/fixtures/tool-bash.out.jsonl?raw";
import type { Transport } from "./bridge";

type Emit = (message: unknown) => void;

interface MockStream {
  write(data: string): void;
  kill(): void;
  closeStdin(): void;
}

const sleep = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));

export function createMockCore(emit: Emit): Transport {
  let nextId = 0;
  const streams = new Map<string, MockStream>();
  const newId = (prefix: string) => `${prefix}${++nextId}`;
  // The app's documents and secrets live as long as the page.
  const documents = new Map<string, string>();
  const secrets = new Map<string, string>();

  const data = (stream: string, text: string) => emit({ event: "stream.data", params: { stream, fd: "stdout", data: text } });
  const exit = (stream: string, code: number | null) => {
    streams.delete(stream);
    emit({ event: "stream.exit", params: { stream, code } });
  };

  function dispatch(method: string, params: Record<string, unknown>): { result: unknown; after?: () => void } {
    switch (method) {
      case "core.info":
        return { result: { version: "mock", goos: "browser", goarch: "js", local: true, smoke: false, bench: false } };
      case "core.echo":
        return { result: params };
      case "core.log":
        console.log(`[mock core.log] ${String(params.line)}`);
        return { result: {} };
      case "core.exit":
        console.log(`[mock core.exit] ${String(params.code)}`);
        return { result: {} };
      case "core.flood": {
        const id = newId("s");
        return { result: { stream: id }, after: () => void flood(id, Number(params.bytes), Number(params.chunk)) };
      }
      case "ssh.connect":
        return { result: { machine: newId("m"), hostKeys: ["SHA256:mock-host-key"] } };
      case "ssh.close":
        return { result: {} };
      case "local.exec":
      case "ssh.exec": {
        const command = method === "ssh.exec" ? String(params.command) : (params.argv as string[]).join(" ");
        if (!/\bomp\b/.test(command)) throw new Error(`the mock core runs only omp, not: ${command}`);
        const id = newId("s");
        return { result: { stream: id }, after: () => streams.set(id, replayOmp(id)) };
      }
      case "pty.open": {
        const id = newId("s");
        return { result: { stream: id }, after: () => streams.set(id, echoPty(id)) };
      }
      case "pty.resize":
        return { result: {} };
      case "stream.write":
      case "stream.kill":
      case "stream.closeStdin": {
        const stream = streams.get(String(params.stream));
        if (!stream) throw new Error(`unknown stream ${String(params.stream)}`);
        if (method === "stream.write") stream.write(String(params.data));
        else if (method === "stream.kill") stream.kill();
        else stream.closeStdin();
        return { result: {} };
      }
      case "shell.info":
        return {
          result: { platform: guessPlatform(), osVersion: "", appVersion: "mock", build: "", device: "browser", push: false },
        };
      case "shell.flutterData":
        return { result: { database: null, secrets: {} } };
      case "shell.insets":
        return { result: { top: 0, right: 0, bottom: 0, left: 0, keyboard: 0 } };
      case "shell.secretGet":
        return { result: { value: secrets.get(String(params.key)) ?? null } };
      case "shell.secretSet":
        secrets.set(String(params.key), String(params.value));
        return { result: {} };
      case "shell.secretDelete":
        secrets.delete(String(params.key));
        return { result: {} };
      case "shell.backEnabled":
      case "shell.dragRegions":
      case "shell.timing":
        return { result: {} };
      case "store.read":
        return { result: { text: documents.get(String(params.name)) ?? null } };
      case "store.write":
        documents.set(String(params.name), String(params.text));
        return { result: {} };
      case "store.delete":
        documents.delete(String(params.name));
        return { result: {} };
      default:
        throw new Error(`unknown method "${method}"`);
    }
  }

  async function flood(id: string, bytes: number, chunk: number) {
    let pending = "";
    let sent = 0;
    for (let n = 0, left = bytes; left > 0; n++) {
      const line = `flood ${n} abcdefghijklmnopqrstuvwxyz0123456789\n`.slice(0, left);
      left -= line.length;
      pending += line;
      while (pending.length >= chunk) {
        data(id, pending.slice(0, chunk));
        pending = pending.slice(chunk);
        if (++sent % 16 === 0) await sleep(0);
      }
    }
    if (pending) data(id, pending);
    exit(id, 0);
  }

  function echoPty(id: string): MockStream {
    data(id, "mock pty: what you type comes back\r\n$ ");
    return {
      write: (text) => data(id, text.replace(/\r/g, "\r\n$ ")),
      kill: () => exit(id, null),
      closeStdin: () => exit(id, 0),
    };
  }

  // Plays a fixture's frames up to the negotiate response at once, then one recorded prompt per prompt sent,
  // with the ids and the prompt text of the request.
  function replayOmp(id: string): MockStream {
    const fixtures = [parseFixture(textStream), parseFixture(toolBash)];
    let turn = 0;
    let stdin = "";
    let queue = Promise.resolve();
    let alive = true;
    const play = (lines: string[], delayMs: number) => {
      queue = queue.then(async () => {
        for (const line of lines) {
          if (!alive) return;
          data(id, `${line}\n`);
          if (delayMs) await sleep(delayMs);
        }
      });
    };
    play(fixtures[0]!.startup, 0);

    const onLine = (line: string) => {
      const command = JSON.parse(line) as { id?: string; type: string; message?: string };
      const fixture = fixtures[turn % fixtures.length]!;
      switch (command.type) {
        case "negotiate_protocol":
          play([JSON.stringify({ ...fixture.negotiate, id: command.id })], 0);
          return;
        case "prompt":
          turn++;
          play(
            fixture.prompt.map((frame) => JSON.stringify(rewritePromptFrame(frame, command.id!, command.message!))),
            25,
          );
          return;
        case "extension_ui_response":
          return;
        default:
          play([JSON.stringify({ id: command.id, type: "response", command: command.type, success: false, error: "the mock omp only replays prompts" })], 0);
      }
    };

    return {
      write(text) {
        stdin += text;
        let newline: number;
        while ((newline = stdin.indexOf("\n")) >= 0) {
          const line = stdin.slice(0, newline);
          stdin = stdin.slice(newline + 1);
          if (line.trim()) onLine(line);
        }
      },
      kill() {
        alive = false;
        exit(id, null);
      },
      closeStdin() {
        alive = false;
        queue.then(() => exit(id, 0));
      },
    };
  }

  return {
    send(text) {
      const request = JSON.parse(text) as { id: number; method: string; params?: Record<string, unknown> };
      setTimeout(() => {
        let answer: { result: unknown; after?: () => void };
        try {
          answer = dispatch(request.method, request.params ?? {});
        } catch (error) {
          emit({ id: request.id, error: { message: error instanceof Error ? error.message : String(error) } });
          return;
        }
        emit({ id: request.id, result: answer.result });
        answer.after?.();
      });
    },
  };
}

interface Fixture {
  startup: string[];
  negotiate: Record<string, unknown>;
  prompt: Record<string, unknown>[];
}

/** Splits a recorded out.jsonl: what omp prints before the negotiate response, that response, and the first prompt's frames. */
function parseFixture(text: string): Fixture {
  const lines = text.split("\n").filter((line) => line.trim());
  const frames = lines.map((line) => JSON.parse(line) as Record<string, unknown>);
  const negotiateAt = frames.findIndex((frame) => frame.id === "negotiate");
  const finalAt = frames.findIndex((frame) => frame.id === "final-messages");
  if (negotiateAt < 0 || finalAt < 0) throw new Error("fixture lacks the negotiate or final-messages response");
  return {
    startup: lines.slice(0, negotiateAt),
    negotiate: frames[negotiateAt]!,
    prompt: frames.slice(negotiateAt + 1, finalAt),
  };
}

function rewritePromptFrame(frame: Record<string, unknown>, id: string, message: string): Record<string, unknown> {
  if (frame.id === "prompt-1") return { ...frame, id };
  const recorded = frame.message as { role?: string } | undefined;
  if ((frame.type === "message_start" || frame.type === "message_end") && recorded?.role === "user") {
    return { ...frame, message: { ...recorded, content: [{ type: "text", text: message }] } };
  }
  return frame;
}

/** The desktop the browser runs on, as `shell.info` names platforms. */
function guessPlatform(): string {
  const agent = navigator.userAgent;
  if (/Android/.test(agent)) return "android";
  if (/iPhone|iPad/.test(agent)) return "ios";
  if (/Macintosh/.test(agent)) return "macos";
  if (/Windows/.test(agent)) return "windows";
  return "linux";
}
