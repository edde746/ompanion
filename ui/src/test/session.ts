// Port of packages/omp_core/test/session/support.dart. A file using DevMachine calls useCore() (src/test/core.ts).
import type { TCPSocketListener } from "bun";
import * as fs from "node:fs/promises";
import * as os from "node:os";
import * as path from "node:path";
import { textOf } from "../core/store/content";
import type { SessionView } from "../core/store/session_view";
import type { LinkState, LiveSession } from "../core/session/live_session";
import { MachineRuntime } from "../core/session/machine_runtime";
import { withTimeout } from "../core/util/async";
import { isolatedEnvironment, stopRuns } from "./channel";
import { localLink } from "./core";
import { repoRoot } from "./omp";

/** The companion build the app ships (`ui/companion/ompx.js`, from `scripts/build_companion.sh`). */
export async function companionBytes(): Promise<Uint8Array> {
  const file = Bun.file(`${repoRoot}/ui/companion/ompx.js`);
  if (!(await file.exists())) throw new Error(`${file.name} is missing; run scripts/build_companion.sh`);
  return new Uint8Array(await file.arrayBuffer());
}

/**
 * An HTTP proxy that forwards nothing: it records the first line of every request (`CONNECT host:443 …` for HTTPS)
 * and closes the connection. omp (Bun's fetch) honours the proxy variables, so a machine with [environment] cannot
 * reach any host outside this computer's loopback.
 */
export class ProxyRecorder {
  readonly requests: string[] = [];
  private readonly server: TCPSocketListener<{ text: string; recorded: boolean }>;

  constructor() {
    this.server = Bun.listen<{ text: string; recorded: boolean }>({
      hostname: "127.0.0.1",
      port: 0,
      socket: {
        open: (socket) => {
          socket.data = { text: "", recorded: false };
        },
        data: (socket, chunk) => {
          if (socket.data.recorded) return;
          socket.data.text += chunk.toString("latin1");
          const end = socket.data.text.indexOf("\n");
          if (end < 0) return;
          socket.data.recorded = true;
          this.requests.push(socket.data.text.slice(0, end).replace(/\r$/, ""));
          socket.end();
        },
      },
    });
  }

  get environment(): Record<string, string> {
    const proxy = `http://127.0.0.1:${this.server.port}`;
    return {
      HTTP_PROXY: proxy,
      HTTPS_PROXY: proxy,
      http_proxy: proxy,
      https_proxy: proxy,
      NO_PROXY: "127.0.0.1,localhost",
      no_proxy: "127.0.0.1,localhost",
    };
  }

  close(): void {
    this.server.stop(true);
  }
}

/**
 * A machine on this computer: an isolated omp home from `harness/dev-machine.sh` (the fake provider, the pinned omp at
 * `~/.local/bin/omp`, `modelRoles.default: fake/fake-1`, `~/demo-project`).
 */
export class DevMachine {
  private constructor(readonly root: string) {}

  static async create(port: number): Promise<DevMachine> {
    const machine = new DevMachine(await fs.mkdtemp(path.join(os.tmpdir(), "ompanion-session-")));
    const setup = Bun.spawn(["sh", `${repoRoot}/harness/dev-machine.sh`, machine.home, String(port)], {
      stdout: "ignore",
      stderr: "pipe",
    });
    const [code, stderr] = await Promise.all([setup.exited, new Response(setup.stderr).text()]);
    if (code !== 0) throw new Error(`dev-machine.sh failed: ${stderr.trim()}`);
    return machine;
  }

  get home(): string {
    return `${this.root}/home`;
  }

  get project(): string {
    return `${this.home}/demo-project`;
  }

  get environment(): Record<string, string> {
    return isolatedEnvironment(this.home);
  }

  /** [extraEnvironment] adds variables to every process on the machine, e.g. [ProxyRecorder.environment]. */
  runtime(
    deviceId: string,
    options: { overlay?: Record<string, string>; extraEnvironment?: Record<string, string>; idleExitMs?: number } = {},
  ): MachineRuntime {
    return new MachineRuntime({
      connect: async () => localLink({ ...this.environment, ...options.extraEnvironment }),
      deviceId,
      companionBytes,
      overlay: options.overlay,
      idleExitMs: options.idleExitMs,
    });
  }

  /** Stops every run still alive, then deletes the machine, also when stopping the runs fails. */
  async dispose(): Promise<void> {
    const link = localLink(this.environment);
    try {
      await stopRuns(link);
    } finally {
      await link.close();
      await fs.rm(this.root, { recursive: true, force: true });
    }
  }
}

/** The first view of [session] (the current one included) that satisfies [test]. */
export async function viewWhere(
  session: LiveSession,
  test: (view: SessionView) => boolean,
  options: { timeoutMs?: number } = {},
): Promise<SessionView> {
  if (test(session.view)) return session.view;
  return withTimeout(session.views.where(test).first(), options.timeoutMs ?? 30_000);
}

/** The first link state of [session] (the current one included) that satisfies [test]. */
export async function linkWhere(
  session: LiveSession,
  test: (state: LinkState) => boolean,
  options: { timeoutMs?: number } = {},
): Promise<LinkState> {
  if (test(session.linkState)) return session.linkState;
  return withTimeout(session.linkStates.where(test).first(), options.timeoutMs ?? 60_000);
}

/** The assistant texts of [view], in order. */
export function answers(view: SessionView): string[] {
  return view.transcript.flatMap((item) => {
    if (item.kind !== "AssistantItem") return [];
    const text = textOf(item.content);
    return text === "" ? [] : [text];
  });
}

/** The user texts of [view], in order. */
export function prompts(view: SessionView): string[] {
  return view.transcript.flatMap((item) => (item.kind === "UserItem" ? [textOf(item.content)] : []));
}

export function idle(view: SessionView): boolean {
  return !view.run.running;
}
