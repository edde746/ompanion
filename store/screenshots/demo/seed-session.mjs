/**
 * Writes one past omp session into a demo host's home, so the machine list has history: it runs a real omp
 * over its RPC protocol against the fake provider, waits for the turn to finish, and puts a title in front of
 * the session file (RPC mode generates none).
 *
 *   node store/screenshots/demo/seed-session.mjs <omp> <home> <cwd> <title> <prompt>
 *
 * `demo/seed-host.sh` runs this on the demo host. It gives up after [BAIL_MS] instead of holding the seed.
 */
import { spawn } from "node:child_process";
import { readdirSync, readFileSync, statSync, writeFileSync } from "node:fs";
import { join } from "node:path";

const BAIL_MS = 40_000;
/** How long the prompt is given before the session is closed; the fake provider answers at once. */
const PROMPT_MS = 12_000;

const [omp, home, cwd, title, prompt] = process.argv.slice(2);
if (!omp || !home || !cwd || !title || !prompt) {
  console.error("usage: seed-session.mjs <omp> <home> <cwd> <title> <prompt>");
  process.exit(2);
}

const child = spawn(omp, ["--mode", "rpc-ui", "--model", "local/Fast"], {
  cwd,
  // Its own process group: omp starts workers, and a seed must not leave any of them asking the provider
  // for turns while the capture's own plan is queued.
  detached: true,
  env: { HOME: home, PATH: process.env.PATH, LANG: process.env.LANG, SHELL: process.env.SHELL },
  stdio: ["pipe", "pipe", "pipe"],
});

let errors = "";
child.stderr.on("data", (chunk) => {
  errors += chunk;
});

const bail = setTimeout(() => {
  console.error(`timed out waiting for omp; last stderr:\n${errors.slice(-1500)}`);
  try {
    process.kill(-child.pid, "SIGKILL");
  } catch {
    child.kill("SIGKILL");
  }
}, BAIL_MS);
child.on("exit", () => clearTimeout(bail));

const send = (frame) => child.stdin.write(`${JSON.stringify(frame)}\n`);
let buffer = "";
let sent = false;
child.stdout.on("data", (chunk) => {
  buffer += chunk;
  for (let newline = buffer.indexOf("\n"); newline !== -1; newline = buffer.indexOf("\n")) {
    const line = buffer.slice(0, newline);
    buffer = buffer.slice(newline + 1);
    if (line.trim() === "") continue;
    let frame;
    try {
      frame = JSON.parse(line);
    } catch {
      continue;
    }
    if (frame.type === "ready") send({ id: "negotiate", type: "negotiate_protocol", protocolVersion: 2 });
    else if (frame.id === "negotiate" && !sent) {
      sent = true;
      send({ id: "prompt-1", type: "prompt", message: prompt });
      // The session file is written as soon as the prompt is accepted, so the run needs no reply protocol: stop
      // omp after a fixed wait instead of waiting for frames it may chunk or delay.
      setTimeout(() => {
        child.stdin.end();
        try {
          process.kill(-child.pid, "SIGKILL");
        } catch {
          child.kill("SIGKILL");
        }
      }, PROMPT_MS);
    }
  }
});

const code = await new Promise((done) => child.on("exit", done));
if (code !== 0) console.error(`omp exited ${code}: ${errors.slice(-500)}`);

/** Newest session file under the home, whatever profile directory omp chose. */
function newestSession(dir) {
  let newest;
  for (const entry of readdirSync(dir, { withFileTypes: true })) {
    const path = join(dir, entry.name);
    if (entry.isDirectory()) {
      const found = newestSession(path);
      if (found && (!newest || statSync(found).mtimeMs > statSync(newest).mtimeMs)) newest = found;
    } else if (/^\d{4}-.*\.jsonl$/.test(entry.name)) {
      if (!newest || statSync(path).mtimeMs > statSync(newest).mtimeMs) newest = path;
    }
  }
  return newest;
}

const sessions = join(home, ".omp", "agent", "sessions");
const newest = newestSession(sessions);
if (!newest) {
  console.error(`no session file under ${sessions}`);
  process.exit(1);
}
const body = readFileSync(newest, "utf8");
// The title slot omp's own listing reads first; a session without one is listed as untitled.
writeFileSync(newest, `${JSON.stringify({ type: "title", title, source: "user" })}\n${body}`);
console.log(`seeded ${title} (${newest})`);
