/**
 * Rehearses the scripted store-screenshot session without the app: a fake provider, an isolated omp home, a
 * copy of one demo project, and the same `turns.ts` plan the capture runs, driving a real omp over its RPC
 * protocol. Prints what the transcript will show and what the tools did to the project, so the content can be
 * checked before a simulator or emulator spends minutes on a capture.
 *
 *   bun store/screenshots/demo/rehearse.ts --session hero [--keep]
 *   bun store/screenshots/demo/rehearse.ts --session deploy
 *
 * Needs `.tools/omp/18.3.1/omp-<platform>-<arch>` (`scripts/fetch_omp.sh`) and the built companion
 * (`scripts/build_companion.sh`). Deletes its temp directory unless `--keep`; kills omp and the provider.
 */
import * as fs from "node:fs/promises";
import * as os from "node:os";
import * as path from "node:path";
import type { Subprocess } from "bun";
import { FakeProvider } from "../../../testing/fake-provider/client.ts";
import { isRecord } from "../../../testing/json.ts";
import { createOmpHome, ompEnv } from "../../../testing/omp-home.ts";

const ROOT = path.join(import.meta.dir, "..", "..", "..");
const OMP = path.join(ROOT, ".tools", "omp", "18.3.1", `omp-${process.platform}-${process.arch}`);
const COMPANION = path.join(ROOT, "companion", "dist", "ompx.js");
const SESSION = argOf("--session") ?? "hero";
const KEEP = process.argv.includes("--keep");
const MODELS_YML = `providers:
  local:
    baseUrl: BASE_URL
    apiKey: fake-key
    api: openai-completions
    models:
      - id: Fast
        name: Fast
        reasoning: false
        input: [text]
        contextWindow: 128000
        maxTokens: 8192
      - id: Reasoning
        name: Reasoning
        reasoning: true
        input: [text]
        contextWindow: 128000
        maxTokens: 8192
`;

type Frame = Record<string, unknown>;

interface Rehearsal {
  dir: string;
  project: string;
}

async function prepare(): Promise<Rehearsal> {
  const dir = await fs.mkdtemp(path.join(os.tmpdir(), `ompanion-rehearse-${SESSION}-`));
  const project = path.join(dir, "project");
  const source = SESSION === "deploy" ? "pipeline" : "api-server";
  await fs.cp(path.join(import.meta.dir, "projects", source), project, { recursive: true });
  // The same history and toolchain the capture host gets, so `git diff` and `npm test` mean the same here.
  const prep = Bun.spawn(["sh", path.join(import.meta.dir, "prepare-project.sh"), project, source], { stdout: "ignore", stderr: "inherit" });
  if ((await prep.exited) !== 0) throw new Error("prepare-project.sh failed");
  return { dir, project };
}

async function main(): Promise<void> {
  if (!(await exists(OMP))) throw new Error(`missing ${OMP}; run scripts/fetch_omp.sh`);
  if (!(await exists(COMPANION))) throw new Error(`missing ${COMPANION}; run scripts/build_companion.sh`);
  const { dir, project } = await prepare();
  const home = path.join(dir, "home");
  const provider = await FakeProvider.start(0);
  const child = Bun.spawn([
    process.execPath,
    path.join(import.meta.dir, "turns.ts"),
    "--provider",
    provider.baseUrl.replace(/\/v1$/, ""),
    "--session",
    SESSION,
  ], { stdout: "inherit", stderr: "inherit" });

  let omp: Subprocess<"pipe", "pipe", "pipe"> | undefined;
  try {
    await createOmpHome(home, provider.port, "tools:\n  approvalMode: yolo\n");
    const models = path.join(home, ".omp", "agent", "models.yml");
    await fs.writeFile(models, MODELS_YML.replace("BASE_URL", provider.baseUrl));
    await fs.appendFile(path.join(home, ".omp", "agent", "config.yml"), "modelRoles:\n  default: local/Fast\n");
    const extension = path.join(home, ".ompanion", "companion", "18.3.1", "ompx.js");
    await fs.mkdir(path.dirname(extension), { recursive: true });
    await fs.copyFile(COMPANION, extension);

    omp = Bun.spawn([OMP, "--mode", "rpc-ui", "--model", "local/Fast", "-e", extension], {
      cwd: project,
      env: ompEnv(home),
      stdin: "pipe",
      stdout: "pipe",
      stderr: "pipe",
    });
    const stderr = new Response(omp.stderr).text();
    const frames: Frame[] = [];
    let send: (frame: Frame) => void = () => {};
    const waiting: Array<() => void> = [];
    const reading = (async () => {
      let buffer = "";
      const decoder = new TextDecoder("utf-8", { fatal: true });
      for await (const bytes of omp.stdout) {
        buffer += decoder.decode(bytes, { stream: true });
        for (let newline = buffer.indexOf("\n"); newline !== -1; newline = buffer.indexOf("\n")) {
          const line = buffer.slice(0, newline);
          buffer = buffer.slice(newline + 1);
          if (line !== "") frames.push(JSON.parse(line) as Frame);
        }
        for (const wake of waiting.splice(0)) wake();
      }
    })();
    send = (frame) => omp!.stdin.write(`${JSON.stringify(frame)}\n`);
    const waitFor = async (match: (frame: Frame) => boolean, what: string, timeoutMs = 120_000): Promise<Frame> => {
      const deadline = Date.now() + timeoutMs;
      for (let cursor = 0; ; ) {
        while (cursor < frames.length) {
          const frame = frames[cursor++];
          if (frame !== undefined && match(frame)) return frame;
        }
        if (Date.now() > deadline) throw new Error(`timed out waiting for ${what}`);
        await new Promise<void>((resolve) => {
          waiting.push(resolve);
          setTimeout(resolve, 500);
        });
      }
    };

    await waitFor((frame) => frame.type === "ready", "omp ready");
    send({ id: "negotiate", type: "negotiate_protocol", protocolVersion: 2 });
    await waitFor((frame) => frame.id === "negotiate", "protocol v2");
    send({ id: "prompt-1", type: "prompt", message: promptOf(SESSION) });

    // Approvals are answered while the run is live, unless the session exists to show a waiting one: the
    // deploy session leaves its last approval open, exactly as the capture does.
    const approvals = { answered: 0, stopped: false };
    const answering = answerApprovals(frames, send, approvals);

    await waitFor((frame) => frame.type === "session_settled", "the session to settle", 300_000);
    await Bun.sleep(1000);
    await child.exited;
    console.log(`\napprovals answered: ${approvals.answered}`);
    approvals.stopped = true;
    answering.catch(() => undefined);

    report(frames, await provider.requests());
    await inspect(project, omp);
  } finally {
    omp?.kill();
    await child.exited;
    await provider.stop();
    if (KEEP) console.log(`kept ${dir}`);
    else await fs.rm(dir, { recursive: true, force: true });
  }
}

/** Prints the transcript as the app will show it, plus how the provider routed every model request. */
function report(frames: Frame[], requests: Array<{ served: string; demo?: string }>): void {
  const served = requests.reduce<Record<string, number>>((counts, request) => {
    counts[request.served] = (counts[request.served] ?? 0) + 1;
    return counts;
  }, {});
  console.log(`\n=== provider ===\nrequests ${requests.length}, ${JSON.stringify(served)}`);
  console.log("\n=== transcript ===");
  for (const frame of frames) {
    if (frame.type === "tool_execution_start") console.log(`tool start  ${String(frame.toolName)} ${JSON.stringify(frame.args ?? {}).slice(0, 120)}`);
    if (frame.type === "tool_execution_end") {
      const result = JSON.stringify(frame.result ?? "");
      console.log(`tool end    ${String(frame.toolName)} ${result.slice(0, 200)}${result.length > 200 ? "…" : ""}`);
    }
    if (frame.type === "message_end" && isRecord(frame.message) && frame.message.role === "assistant") {
      const text = textOf(frame.message);
      if (text !== "") console.log(`assistant   ${text.slice(0, 400)}${text.length > 400 ? "…" : ""}`);
    }
    if (frame.type === "extension_ui_request") console.log(`request     ${String(frame.title ?? frame.method ?? "")}`);
    if (frame.type === "auto_retry_start") console.log(`retry       ${JSON.stringify(frame).slice(0, 200)}`);
    if (frame.type === "error" || frame.type === "prompt_result") console.log(`${String(frame.type)}   ${JSON.stringify(frame).slice(0, 300)}`);
  }
}


/** Answers approval dialogs while the run is live; the deploy session leaves its last one open. */
async function answerApprovals(frames: Frame[], send: (frame: Frame) => void, state: { answered: number; stopped: boolean }): Promise<void> {
  const seen = new Set<unknown>();
  while (!state.stopped) {
    await Bun.sleep(250);
    for (const frame of frames) {
      if (frame.type !== "extension_ui_request" || !Array.isArray(frame.options) || seen.has(frame.id)) continue;
      seen.add(frame.id);
      state.answered += 1;
      if (SESSION === "deploy" && state.answered > 1) continue;
      if (typeof frame.id !== "string") continue;
      const options = frame.options.filter((option): option is string => typeof option === "string");
      const approve = options.find((option) => option.toLowerCase().startsWith("approve"));
      send({ type: "extension_ui_request", id: frame.id, value: approve ?? options[0] ?? "Deny" });
    }
  }
}

function textOf(message: Frame): string {
  const content = message.content;
  if (!Array.isArray(content)) return typeof content === "string" ? content : "";
  return content
    .map((part) => (isRecord(part) && typeof part.text === "string" ? part.text : ""))
    .join("")
    .trim();
}

/** Shows what the tools left behind: the diff, the status, and the project's own test suite. */
async function inspect(project: string, omp: Subprocess<"pipe", "pipe", "pipe">): Promise<void> {
  console.log("\n=== project ===");
  for (const command of ["git status --short", "git diff", "npm test"]) {
    const proc = Bun.spawn(["sh", "-c", command], { cwd: project, env: { ...process.env, HOME: process.env.HOME ?? "" }, stdout: "pipe", stderr: "pipe" });
    const [out, err, code] = await Promise.all([new Response(proc.stdout).text(), new Response(proc.stderr).text(), proc.exited]);
    console.log(`\n$ ${command}   (exit ${code})\n${out}${err}`.slice(0, 6000));
  }
  omp.kill();
}

function promptOf(session: string): string {
  return session === "deploy"
    ? "Rotate the deploy token in deploy.sh and smoke-test the staging deploy."
    : "Add rate limiting to the upload endpoint so one client cannot exhaust the put path, then run the tests.";
}

async function exists(file: string): Promise<boolean> {
  return await fs.access(file).then(() => true, () => false);
}

function argOf(flag: string): string | undefined {
  const index = process.argv.indexOf(flag);
  return index === -1 ? undefined : process.argv[index + 1];
}

await main();
