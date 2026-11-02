// What a slice's scenario file, scripts/shots/<slice>.ts, exports: `export const screens: Screen[]`, and
// `export function stop(): Promise<string[]>` when it starts something for the whole run. scripts/shots.ts says how
// they run.
import type { Page } from "playwright-core";
import type { FakeProvider } from "../../harness/fake-provider/client.ts";
// For its `window.ompDev`, which ShotContext's call and exec use.
import type {} from "../src/app/dev_api";

export interface ExecResult {
  readonly stdout: string;
  readonly stderr: string;
  readonly code: number | null;
}

export interface ShotContext {
  readonly page: Page;
  readonly size: "desktop" | "phone";
  /** The core's HOME, a fresh temporary one; in an OMP=1 run omp is `<home>/.local/bin/omp`. */
  readonly home: string;
  /** The fake provider omp talks to in an OMP=1 run (harness/fake-provider/client.ts); queue its turns here. */
  readonly provider: FakeProvider | undefined;
  /** A core method, called through the page's bridge as the app calls it (docs/contracts/bridge.md). */
  call<T>(method: string, params?: unknown): Promise<T>;
  /** `local.exec` of a `/bin/sh -c` command in the core, through the page; resolves when it exits. */
  exec(command: string): Promise<ExecResult>;
  /**
   * Shoots the page as it is now into `<slice>-<step>-<size>-<theme>.png` (`…-webkit.png` in WebKit), as the runner
   * shoots the end of `reach`: a journey's steps, each a picture of its own.
   */
  snap(step: string): Promise<void>;
}

export interface Screen {
  /** Unique within its slice; the shot is `<slice>-<name>-<size>-<theme>.png`. */
  readonly name: string;
  /** Added to the page's query, e.g. `gallery=transcript&fixture=tools` (main.tsx's dev galleries). */
  readonly query?: string;
  /** Runs only in OMP=1 runs, which install omp and the fake provider. */
  readonly omp?: boolean;
  /**
   * Runs on a core, HOME and fake provider of its own at every size and theme, from a fresh start, instead of on the
   * run's shared one where every other screen's steps already left their state.
   */
  readonly fresh?: boolean;
  /**
   * The sizes it runs at, when not every size the run asks for: a screen of a desktop shell's own services
   * (shell.info `paths`), which the phone size, pretending iOS, never has.
   */
  readonly sizes?: readonly ShotContext["size"][];
  /**
   * Added to the environment of the screen's core, which is then its own as with `fresh`: e.g. the dev bridge's
   * `OMPCORE_FLUTTER_DB` (docs/contracts/bridge.md, Dev bridge).
   */
  readonly env?: Readonly<Record<string, string>>;
  /** Steps from a fresh start to the picture; throwing fails the shot (the run exits 1, the others still run). */
  readonly reach?: (context: ShotContext) => Promise<void>;
}
