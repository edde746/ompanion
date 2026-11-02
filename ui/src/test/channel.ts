// Port of packages/omp_core/test/channel/support.dart. A file using TestHost calls useCore() (src/test/core.ts).
import * as fs from "node:fs/promises";
import * as os from "node:os";
import * as path from "node:path";
import { createOmpHome } from "../../../harness/omp-home";
import { detachedRunLive, listRuns, removeDeadRuns, stopRun } from "../core/channel/detached_run";
import { followScript, type AttachTools } from "../core/channel/follow";
import { logScript } from "../core/channel/log_script";
import { probeHost } from "../core/host/probe";
import { isJsonObject, type JsonObject } from "../core/rpc/json_fields";
import type { BridgeLink } from "../core/transport/bridge_link";
import { withTimeout } from "../core/util/async";
import type { EventStream, Subscription } from "../core/util/stream";
import { deferred } from "../deferred";
import { localLink } from "./core";
import { ompBinary } from "./omp";

/** PowerShell 7, when installed: it runs the Windows scripts that do not need Windows itself. */
export const pwsh: string | undefined = Bun.which("pwsh") ?? undefined;

/** The scripts omp runs as Bun ([logScript], [followScript]) written into [dir] (created), run by this computer's omp. */
export async function localTools(dir: string): Promise<AttachTools> {
  await fs.mkdir(dir, { recursive: true });
  await Bun.write(`${dir}/log.js`, logScript);
  await Bun.write(`${dir}/follow.js`, followScript);
  return { bun: ompBinary, log: `${dir}/log.js`, follow: `${dir}/follow.js` };
}

/**
 * Only system directories on PATH, so the user's own omp is never found; omp's directory overrides are cleared (an
 * explicitly empty value selects the default).
 */
export function isolatedEnvironment(home: string): Record<string, string> {
  return {
    HOME: home,
    PATH: "/usr/bin:/bin:/usr/sbin:/sbin",
    PI_CODING_AGENT_DIR: "",
    OMP_PROFILE: "",
    PI_PROFILE: "",
    PI_CONFIG_DIR: "",
    XDG_DATA_HOME: "",
    XDG_STATE_HOME: "",
    XDG_CACHE_HOME: "",
  };
}

/**
 * A temporary machine for tests on this computer: `home/` is an isolated omp home (harness/omp-home.sh, fake provider
 * on a port nothing listens on, so no model turn can run) with the release binary linked at `~/.local/bin/omp`, and
 * `work dir/` is a project directory whose name needs quoting.
 */
export class TestHost {
  private constructor(
    readonly root: string,
    /** The attach scripts, in [root]. */
    readonly tools: AttachTools,
    public link: BridgeLink,
  ) {}

  static async create(): Promise<TestHost> {
    const root = await fs.mkdtemp(path.join(os.tmpdir(), "ompanion-host-"));
    const home = `${root}/home`;
    await fs.mkdir(home);
    await fs.mkdir(`${root}/work dir`);
    await createOmpHome(home, 9);
    await fs.mkdir(`${home}/.local/bin`, { recursive: true });
    await fs.symlink(ompBinary, `${home}/.local/bin/omp`);
    return new TestHost(root, await localTools(root), localLink(isolatedEnvironment(home)));
  }

  get home(): string {
    return `${this.root}/home`;
  }

  get work(): string {
    return `${this.root}/work dir`;
  }

  /** Replaces [link] with a new one, as after the bridge to the core dropped the old one. */
  async reconnect(): Promise<void> {
    await this.link.close();
    this.link = localLink(isolatedEnvironment(this.home));
  }

  /** Stops every run still alive (force), then deletes everything, also when stopping the runs fails. */
  async dispose(): Promise<void> {
    try {
      await stopRuns(this.link);
    } finally {
      await this.link.close();
      await fs.rm(this.root, { recursive: true, force: true });
    }
  }
}

/** Stops every run on [link]'s machine that is still alive (force) and removes the run directories. */
export async function stopRuns(link: BridgeLink): Promise<void> {
  const probe = await probeHost(link);
  for (const run of await listRuns(link, probe)) {
    if (detachedRunLive(run)) await stopRun(link, probe, run, { force: true, timeoutMs: 10_000 });
  }
  await removeDeadRuns(link, probe);
}

/** Collects the JSON frames of a channel and waits for particular ones. */
export class Frames {
  readonly raw: string[] = [];
  readonly frames: JsonObject[] = [];
  error: Error | undefined;
  done = false;
  private signal = deferred<void>();
  private readonly subscription: Subscription;

  constructor(lines: EventStream<string>) {
    this.subscription = lines.listen(
      (line) => {
        this.raw.push(line);
        let value: unknown;
        try {
          value = JSON.parse(line);
        } catch (error) {
          if (!(error instanceof SyntaxError)) throw error;
          return;
        }
        if (isJsonObject(value)) {
          this.frames.push(value);
          this.changed();
        }
      },
      {
        error: (error) => {
          this.error = error;
          this.changed();
        },
        done: () => {
          this.done = true;
          this.changed();
        },
      },
    );
  }

  private changed(): void {
    const signal = this.signal;
    this.signal = deferred<void>();
    signal.resolve();
  }

  private types(): string {
    return JSON.stringify(this.frames.map((frame) => frame["type"]));
  }

  /** The first frame (from [from] on) matching [test]. */
  async next(test: (frame: JsonObject) => boolean, options: { from?: number; timeoutMs?: number } = {}): Promise<JsonObject> {
    const deadline = Date.now() + (options.timeoutMs ?? 30_000);
    for (;;) {
      for (let i = options.from ?? 0; i < this.frames.length; i++) {
        const frame = this.frames[i]!;
        if (test(frame)) return frame;
      }
      if (this.error !== undefined) throw new Error(`channel failed: ${String(this.error)}`);
      if (this.done) throw new Error(`channel ended; frames: ${this.types()}`);
      const left = deadline - Date.now();
      if (left <= 0) throw new Error(`no matching frame; got ${this.types()}`);
      await withTimeout(this.signal.promise, left, () => undefined);
    }
  }

  response(id: string): Promise<JsonObject> {
    return this.next((frame) => frame["type"] === "response" && frame["id"] === id);
  }

  /** Waits until the lines stream ends. */
  async ended(options: { timeoutMs?: number } = {}): Promise<void> {
    const deadline = Date.now() + (options.timeoutMs ?? 30_000);
    while (!this.done) {
      const left = deadline - Date.now();
      if (left <= 0) throw new Error("channel did not end");
      await withTimeout(this.signal.promise, left, () => undefined);
    }
  }

  cancel(): void {
    this.subscription.cancel();
  }
}

export function getState(id: string): string {
  return JSON.stringify({ id, type: "get_state" });
}
