// Smoke-checks the review demo server (store/review-demo/provision.sh) through the app's own core code
// (ui/src/core): the same SSH link, probe, companion upload, session runtime and view reducer the app uses, on the Go
// core through its dev bridge, minus the screens. Run it with bun from the repository root, on studio
// (scripts/studio.sh: it builds and starts the core, which never runs on the developer's Mac):
//
//   REVIEW_PASSWORD="$(sed -n 's/^REVIEW_PASSWORD=//p' store/review-demo/.env)" \
//     bun store/review-demo/verify/verify.ts --host SERVER [--prompt]
//
// Steps, each printing one OK line: connect as root with the password, probe the machine and find omp, check the
// uploaded companion, open a session, run a command over the SSH link and one through the companion's `exec.bash`,
// browse and write files over SFTP, list the machine's sessions as the sidebar does, and check that omp offers exactly
// the demo's model. With `--prompt` it also sends one prompt that makes the model run a command: a real model call, a
// fraction of a cent on the demo's key, so it is off unless asked for. Exits non-zero on the first failure.
import * as fs from "node:fs/promises";
import * as os from "node:os";
import * as path from "node:path";
import { call, disconnect } from "../../../ui/src/bridge";
import { runCommand } from "../../../ui/src/core/host/scripts";
import { isJsonObject } from "../../../ui/src/core/rpc/json_fields";
import { MachineRuntime } from "../../../ui/src/core/session/machine_runtime";
import type { LiveSession } from "../../../ui/src/core/session/live_session";
import type { SshAuth } from "../../../ui/src/core/ssh/ssh_config";
import { sshHop, sshTarget } from "../../../ui/src/core/ssh/ssh_config";
import { SshLink } from "../../../ui/src/core/ssh/ssh_link";
import { textOf } from "../../../ui/src/core/store/content";
import type { TranscriptItem } from "../../../ui/src/core/store/transcript";
import type { HostLink } from "../../../ui/src/core/transport/host_link";

const repo = path.resolve(import.meta.dir, "../../..");
/** The demo's only model (home-template/.omp/agent/models.yml), so a reviewer cannot pick an expensive one. */
const demoModel = "demo/z-ai/glm-5.3-flash";

const usage = `verify: smoke-checks the review demo server.

  bun store/review-demo/verify/verify.ts --host HOST [--port PORT] [--user USER]
      (--password PASSWORD | --key FILE) [--project DIR] [--companion FILE] [--model ID] [--prompt]

Defaults: port 22, user root, project <home>/work/notes-api, companion the app's bundled ui/companion/ompx.js, model
${demoModel}. The password is REVIEW_PASSWORD in store/review-demo/.env (also read from the environment); --key signs
in with a private key instead (a stand-in host). --prompt sends one prompt to the demo's model, a real call on its key.
`;

interface Options {
  readonly host: string;
  readonly port: number;
  readonly user: string;
  readonly auth: SshAuth;
  readonly project?: string;
  readonly companion: string;
  readonly model: string;
  readonly prompt: boolean;
}

async function parse(args: readonly string[]): Promise<Options> {
  const value = (name: string) => {
    const at = args.indexOf(`--${name}`);
    if (at === -1) return undefined;
    const next = args[at + 1];
    if (next === undefined) throw new Error(`--${name} needs a value`);
    return next;
  };
  const host = value("host");
  if (!host) throw new Error("--host is required");
  const port = Number(value("port") ?? "22");
  if (!Number.isInteger(port) || port < 1 || port > 65535) throw new Error(`--port must be 1..65535, got ${value("port")}`);
  const key = value("key");
  const password = value("password") ?? process.env.REVIEW_PASSWORD;
  let auth: SshAuth;
  if (key !== undefined) auth = { kind: "SshKeyAuth", privateKeyPem: await Bun.file(key).text() };
  else if (password) auth = { kind: "SshPasswordAuth", password };
  else throw new Error("--password (or REVIEW_PASSWORD in the environment) or --key is required");
  return {
    host,
    port,
    user: value("user") ?? "root",
    auth,
    project: value("project"),
    companion: value("companion") ?? path.join(repo, "ui/companion/ompx.js"),
    model: value("model") ?? demoModel,
    prompt: args.includes("--prompt"),
  };
}

const step = (message: string) => console.log(`  ${message}`);
const ok = (message: string) => console.log(`OK ${message}`);
const firstLine = (text: string) => text.split("\n").find((line) => line.trim() !== "")?.trim() ?? "";
const clip = (text: string) => (text.length <= 200 ? text : `${text.slice(0, 200)}…`);

/** The Go core on a dev bridge of its own, with fresh HOME, data and cache directories; resolves to its stop. */
async function startCore(): Promise<() => Promise<void>> {
  const version = (await Bun.file(path.join(repo, "VERSION")).text()).trim();
  const binary = path.join(repo, "build/devbridge");
  const built = Bun.spawnSync(
    ["go", "build", "-ldflags", `-X ompanion.app/core.Version=${version}`, "-o", binary, "./cmd/devbridge"],
    { cwd: path.join(repo, "core"), stderr: "pipe" },
  );
  if (built.exitCode !== 0) throw new Error(`go build ./cmd/devbridge failed: ${built.stderr.toString()}`);
  const root = await fs.mkdtemp(path.join(os.tmpdir(), "review-demo-verify-"));
  const dirs = { HOME: `${root}/home`, OMPCORE_DATA_DIR: `${root}/data`, OMPCORE_CACHE_DIR: `${root}/cache` };
  for (const dir of Object.values(dirs)) await fs.mkdir(dir);
  const core = Bun.spawn([binary, "-listen", "127.0.0.1:0"], { env: { ...process.env, ...dirs }, stderr: "pipe" });
  const reader = core.stderr.getReader();
  let seen = "";
  for (;;) {
    const { value, done } = await reader.read();
    if (done) throw new Error(`the dev bridge exited before it listened: ${seen}`);
    seen += new TextDecoder().decode(value);
    const url = /ws:\/\/\S+\/bridge/.exec(seen)?.[0];
    if (url === undefined) continue;
    process.env.OMPCORE_DEVBRIDGE = url;
    break;
  }
  // Keep draining its log, so the core never blocks on a full pipe.
  void (async () => {
    while (!(await reader.read()).done);
  })();
  return async () => {
    await disconnect();
    core.kill();
    await core.exited;
    await fs.rm(root, { recursive: true, force: true });
  };
}

/** Prompts and waits until the run settles with an answer. */
async function prompt(session: LiveSession, text: string, timeoutMs = 4 * 60_000): Promise<{ text: string; items: TranscriptItem[] }> {
  const from = session.view.transcript.length;
  await session.rpc.prompt(text);
  const deadline = Date.now() + timeoutMs;
  for (;;) {
    const view = session.view;
    const added = view.transcript.slice(from);
    const answer = added
      .flatMap((item) => (item.kind === "AssistantItem" ? [textOf(item.content)] : []))
      .join("\n")
      .trim();
    if (!view.run.running && view.run.outcome.kind === "RunIdle" && answer !== "") return { text: answer, items: added };
    if (view.run.outcome.kind === "RunFailed") throw new Error(`the run failed: ${view.run.outcome.message ?? ""}`);
    if (Date.now() > deadline) {
      throw new Error(`no answer within ${timeoutMs / 1000}s (${added.length} new items, text "${clip(answer)}")`);
    }
    await Bun.sleep(100);
  }
}

async function list(link: HostLink, dir: string): Promise<string[]> {
  const files = await link.files();
  try {
    return (await files.list(dir)).map((entry) => `${entry.name}${entry.stat.isDirectory ? "/" : ""}`);
  } finally {
    await files.close();
  }
}

async function read(link: HostLink, file: string): Promise<string> {
  const files = await link.files();
  try {
    return new TextDecoder().decode(await files.read(file));
  } finally {
    await files.close();
  }
}

async function verify(options: Options): Promise<void> {
  const target = sshTarget({ target: sshHop({ host: options.host, port: options.port, user: options.user, auth: options.auth }) });
  // What the app's "Trust this host?" dialog decides: the key of the first connection is trusted (like the reviewer
  // tapping Trust), and a key that changes afterwards is refused.
  let trusted: string | undefined;
  const runtime = new MachineRuntime({
    connect: () =>
      SshLink.open(target, {
        verifyHostKey: async (check) => {
          if (trusted === undefined) step(`host key ${check.keyType} ${check.sha256Fingerprint} (trusted on first use)`);
          trusted ??= check.sha256Fingerprint;
          return check.sha256Fingerprint === trusted;
        },
      }),
    deviceId: "review-demo-verify",
    companionBytes: async () => new Uint8Array(await Bun.file(options.companion).arrayBuffer()),
  });
  let session: LiveSession | undefined;
  try {
    const probe = await runtime.connectAndProbe();
    const status = runtime.status;
    if (status.kind === "MachineNeedsOmp") throw new Error(`omp is missing or too old on the machine: ${status.reason}`);
    if (status.kind !== "MachineOnline") throw new Error(`unexpected machine status ${status.kind}`);
    ok(`probe: ${probe.os}/${probe.arch} libc=${probe.libc ?? "none"} home=${probe.home} omp=${probe.ompPath} ${probe.ompVersion}`);

    const link = runtime.link;
    const companionDir = `${probe.home}/.ompanion/companion/${probe.ompVersion ?? "unknown"}`;
    const companion = await list(link, companionDir);
    if (!companion.some((name) => name.endsWith(".js"))) {
      throw new Error(`no companion build under ${companionDir} (found ${companion.join(", ")})`);
    }
    ok(`companion uploaded: ${companion.join(", ")}`);

    const project = options.project ?? `${probe.home}/work/notes-api`;
    const listing = await list(link, project);
    ok(`file browser: ${project} lists ${listing.length} entries: ${listing.slice(0, 5).join(", ")}`);
    const readme = await read(link, `${project}/README.md`);
    ok(`file browser read: ${project}/README.md is ${readme.length} chars, first line "${firstLine(readme)}"`);

    session = await runtime.open({ kind: "NewSession", cwd: project });
    const model = session.view.config.model;
    ok(
      `session: run ${session.runId} cwd ${session.cwd} file ${session.sessionPath ?? "(not written yet)"} ` +
        `model ${model?.provider}/${model?.id}`,
    );
    const hello = session.companionHello;
    if (hello === undefined) throw new Error("the companion did not load in the session");
    ok(`companion loaded: ${hello.companionVersion} for omp ${hello.ompVersion}`);

    if (options.prompt) {
      const reply = await prompt(
        session,
        "Run `git log --oneline` in this directory with the bash tool, then tell me in one sentence how many commits the project has.",
      );
      const bash = reply.items.filter((item) => item.kind === "ToolResultItem" && item.toolName === "bash");
      const last = bash.at(-1);
      if (last === undefined || last.kind !== "ToolResultItem") throw new Error(`the model made no bash call: "${clip(reply.text)}"`);
      ok(`prompt: bash result "${firstLine(textOf(last.content))}", answer "${firstLine(reply.text)}"`);
    } else {
      ok("prompt: skipped (no model call without --prompt)");
    }

    const command = await runCommand(link, `id -un; uname -m; ls "${project}"`);
    if (command.exit.code !== 0) throw new Error(`the SSH command failed (exit ${command.exit.code}): ${command.stderr.trim()}`);
    ok(`ssh exec: ${command.stdout.trim().replaceAll("\n", " | ")}`);

    const exec = await Promise.race([
      session.companion.call("exec.bash", { command: "echo review-demo-exec" }),
      Bun.sleep(60_000).then(() => {
        throw new Error("exec.bash did not answer within 60 s");
      }),
    ]);
    ok(`companion exec.bash: ${JSON.stringify(exec)}`);

    const files = await link.files();
    try {
      const probePath = `${probe.home}/browser-probe.txt`;
      await files.write(probePath, new TextEncoder().encode("written by verify.ts\n"));
      const written = new TextDecoder().decode(await files.read(probePath));
      await files.remove(probePath);
      if (written.trim() !== "written by verify.ts") throw new Error(`the file browser wrote back "${written}"`);
      ok(`file browser write: wrote and removed ${probePath}`);
    } finally {
      await files.close();
    }

    const sessions = await runtime.listSessions();
    const opened = session;
    if (!sessions.some((summary) => summary.path === opened.sessionPath || summary.runId === opened.runId)) {
      throw new Error(`the new session is not in the session list of the machine (${sessions.length} sessions)`);
    }
    ok(`session list: ${sessions.length} session(s), newest "${sessions[0]?.title ?? "(untitled)"}"`);

    // What the machine's Configure pane and its model picker read: omp's own model list and the companion's settings
    // schema, both from the machine's control process.
    const control = await runtime.control();
    if (control.companionHello === undefined) throw new Error("the companion did not load in the control session");
    const models = await control.rpc.getAvailableModels();
    const ids = models.map((entry) => `${entry.provider}/${entry.id}`);
    if (ids.length !== 1 || ids[0] !== options.model) {
      throw new Error(`get_available_models should list only ${options.model}, got ${ids.join(", ")}`);
    }
    ok(`configure: get_available_models lists ${ids[0]} "${models[0]!.name}"`);

    const schema = await control.companion.call("settings.schema");
    const tabs = isJsonObject(schema) && Array.isArray(schema.tabs) ? schema.tabs.length : 0;
    const settings = isJsonObject(schema) && Array.isArray(schema.settings) ? schema.settings : [];
    if (tabs === 0 || settings.length === 0) throw new Error(`settings.schema returned ${JSON.stringify(schema)}`);
    ok(`configure: settings.schema has ${tabs} tab(s) and ${settings.length} setting(s)`);

    const values = await control.companion.call("settings.get");
    const effective = isJsonObject(values) && Array.isArray(values.settings) ? values.settings : [];
    const lsp = effective.find((entry) => isJsonObject(entry) && entry.path === "lsp.enabled");
    if (!isJsonObject(lsp)) throw new Error(`settings.get does not report lsp.enabled: ${clip(JSON.stringify(values))}`);
    ok(`configure: settings.get reports ${effective.length} value(s), lsp.enabled ${JSON.stringify(lsp.value)}`);

    // The app detaches and leaves the run alive on the machine; ompanion-demo-reset stops it there.
    await session.detach();
    session = undefined;
    ok("detach: the run keeps running on the machine");
  } finally {
    await session?.detach().catch((error: unknown) => step(`detaching after the failure failed too: ${String(error)}`));
    await runtime.dispose();
  }
}

let options: Options;
try {
  options = await parse(process.argv.slice(2));
} catch (error) {
  console.error(`verify: ${error instanceof Error ? error.message : String(error)}\n\n${usage}`);
  process.exit(64);
}
const stopCore = await startCore();
try {
  await call("core.info");
  await verify(options);
  console.log("all steps OK");
} catch (error) {
  console.error(`FAILED: ${error instanceof Error ? (error.stack ?? error.message) : String(error)}`);
  process.exitCode = 1;
} finally {
  await stopCore();
}
