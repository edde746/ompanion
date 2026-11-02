// A real omp for e2e tests, run through the core on this computer: the tested binary, an isolated home whose only
// provider is the fake one (harness/), and the attached LineChannel over its stdio. Port of the Dart tests'
// omp_binary.dart and rpc/omp_process.dart. A file using launch() calls useCore() (src/test/core.ts).
import * as fs from "node:fs/promises";
import * as os from "node:os";
import * as path from "node:path";
import { createOmpHome, OMP_VERSION } from "../../../harness/omp-home";
import { hostProbe, type HostProbe, hostProbeReleaseAsset } from "../core/host/probe";
import { shQuote } from "../core/host/scripts";
import { BridgeLink } from "../core/transport/bridge_link";
import type { HostExit, HostProcess } from "../core/transport/host_link";
import { decodeLines, type LineChannel } from "../core/transport/line_channel";
import { withTimeout } from "../core/util/async";
import { Emitter, type EventStream, type Subscription } from "../core/util/stream";

export { FakeProvider } from "../../../harness/fake-provider/client";

export const repoRoot = path.resolve(import.meta.dir, "../../..");

/** The omp version the tests run: `$OMP_VERSION`, else `harness/omp-version`. */
export const testedOmpVersion = OMP_VERSION;

/** A release asset of [testedOmpVersion] in `.tools/`, where `scripts/fetch_omp.sh` puts it. */
export function ompAsset(name: string): string {
  return path.join(repoRoot, ".tools", "omp", testedOmpVersion, name);
}

/** This computer as a probe of it reads (glibc on Linux); its release asset names [ompBinary]. */
export const thisComputer: HostProbe = hostProbe({
  commandShell: "posix",
  os: process.platform === "darwin" ? "macos" : "linux",
  kernel: process.platform === "darwin" ? "Darwin" : "Linux",
  arch: omparch(process.arch),
  libc: process.platform === "linux" ? "glibc" : undefined,
  home: "/unused",
  agentDir: "/unused",
});

function omparch(arch: string): string {
  if (arch === "arm64") return "arm64";
  if (arch === "x64") return "x64";
  throw new Error(`omp has no build for ${process.platform} ${arch}`);
}

/** The [testedOmpVersion] release binary for this computer. */
export const ompBinary = ompAsset(hostProbeReleaseAsset(thisComputer)!);

/** An isolated omp home (harness/omp-home.sh) plus a working directory outside the repository. */
export class OmpHome {
  private constructor(readonly root: string) {}

  get home(): string {
    return `${this.root}/home`;
  }

  get work(): string {
    return `${this.root}/work`;
  }

  /** [providerPort] is the fake provider's; by default nothing listens there, for tests that run no model turn. */
  static async create(options: { providerPort?: number } = {}): Promise<OmpHome> {
    const ompHome = new OmpHome(await fs.mkdtemp(path.join(os.tmpdir(), "omp-rpc-")));
    await fs.mkdir(ompHome.work);
    await createOmpHome(ompHome.home, options.providerPort ?? 9);
    return ompHome;
  }

  delete(): Promise<void> {
    return fs.rm(this.root, { recursive: true, force: true });
  }

  /**
   * Starts `omp --mode rpc-ui --no-session --model fake/fake-1 [args]` with only this home's environment (no
   * provider keys), attached to its stdio.
   */
  async launch(args: string[] = []): Promise<OmpProcess> {
    const link = new BridgeLink("local", { environment: { HOME: this.home } });
    const command = [
      `cd ${shQuote(this.work)} &&`,
      'exec env -i HOME="$HOME" PATH="$PATH" TMPDIR="${TMPDIR:-/tmp}" USER="$USER" LANG="${LANG:-C.UTF-8}"',
      shQuote(ompBinary),
      "--mode rpc-ui --no-session --model fake/fake-1",
      ...args.map(shQuote),
    ].join(" ");
    return new OmpProcess(link, await link.exec(command));
  }
}

/**
 * A running omp and the attached LineChannel over its stdio. stdout is read until omp exits even after the client
 * stops listening: omp flushes output while it shuts down, and a closed pipe makes it exit 1.
 */
export class OmpProcess implements LineChannel {
  private readonly emitter = new Emitter<string>({ buffered: true });
  private readonly stdoutSubscription: Subscription;
  private readonly stderrSubscription: Subscription;

  /** omp's stderr, for failure messages. */
  stderr = "";

  /** `rpc_chunk` lines seen so far. */
  chunkLines = 0;

  constructor(
    private readonly link: BridgeLink,
    readonly process: HostProcess,
  ) {
    const decoder = new TextDecoder();
    this.stderrSubscription = process.stderr.listen((bytes) => {
      this.stderr += decoder.decode(bytes, { stream: true });
    });
    this.stdoutSubscription = decodeLines(process.stdout).listen(
      (line) => {
        if (line.startsWith('{"type":"rpc_chunk"')) this.chunkLines++;
        this.emitter.add(line);
      },
      { done: () => this.emitter.close() },
    );
  }

  get lines(): EventStream<string> {
    return this.emitter.stream;
  }

  async send(line: string): Promise<void> {
    this.process.write(new TextEncoder().encode(`${line}\n`));
  }

  /** Closing stdin is omp's graceful stop: it drains accepted commands and exits 0. */
  close(): Promise<void> {
    return this.process.closeStdin();
  }

  /** Waits for omp to exit after [close]; kills it after [timeoutMs]. */
  async exit(options: { timeoutMs?: number } = {}): Promise<HostExit> {
    try {
      return await withTimeout(this.process.exit, options.timeoutMs ?? 20_000, () => {
        this.process.kill();
        return this.process.exit;
      });
    } finally {
      this.stdoutSubscription.cancel();
      this.stderrSubscription.cancel();
      this.emitter.close();
      await this.link.close();
    }
  }
}
