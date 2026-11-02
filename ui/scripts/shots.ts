// Screenshots of the built app on a real core, for comparing with the store screenshots, still the Flutter app's
// (store/microsoft/screenshots, store/fastlane/ios/screenshots,
// store/fastlane/android/metadata/android/en-US/images/phoneScreenshots), and flows against a real omp. Runs on studio
// through scripts/shots.sh, which builds ui/dist and the dev bridge first (docs/app.md, "Shots"):
//
//   scripts/studio.sh <you> --fetch build/shots -- sh ui/scripts/shots.sh [options]
//
// Every scripts/shots/<slice>.ts exports `screens: Screen[]` (scripts/shot_types.ts). Each screen is shot at every
// size and theme, each in a fresh browser context on the run's one core (on a core of its own when the screen is
// `fresh`), after its `reach` steps, into build/shots/<slice>-<name>-<size>-<theme>.png
// (`…-<theme>-webkit.png` in WebKit).
// A slice that starts something for the whole run also exports `stop(): Promise<string[]>`, which ends it and resolves
// to the processes that outlived it. A run fails when a process it started in one of its temporary directories
// outlives it (scripts/shot_processes.ts).
//
//   --only <prefix>        only screens whose `<slice>-<name>` starts with it (repeatable)
//   --sizes desktop,phone  desktop is 1440 × 900; phone 390 × 844 at 3×, as an iPhone with its insets
//   --themes light,dark    the system appearance the browser reports
//   --browser <name>       chromium (default: the installed Google Chrome) or webkit (Playwright's WebKit, the engine
//                          of the Apple shells' WKWebView; installed into Playwright's cache on first use)
//   --shot <name>=<query>  an ad-hoc page instead of the slices, e.g. `transcript-tools='gallery=transcript&fixture=tools'`
//   --smoke                the page's smoke checks (docs/contracts/bridge.md, "Smoke runs") instead of pictures;
//                          SMOKE=1 too
//   --omp                  OMP=1 too: the fake provider and the tested omp in the core's HOME; only then do `omp` screens run
//
// Each run has its own core on a free port, its own temporary HOME (never the account's) and its own fake provider,
// so runs in several studio.sh stages go side by side.
import * as fs from "node:fs/promises";
import * as os from "node:os";
import * as path from "node:path";
import type { Subprocess } from "bun";
import { type Browser, chromium, webkit } from "playwright-core";
import type { FakeProvider } from "../../harness/fake-provider/client.ts";
import { endAndRemove } from "./shot_processes";
import type { ExecResult, Screen, ShotContext } from "./shot_types";

const sizes = {
  desktop: { width: 1440, height: 900, query: "", scale: 1 },
  // An iPhone 16's points and insets: the status bar with the Dynamic Island, the home indicator.
  phone: { width: 390, height: 844, query: "&platform=ios&insets=59,0,34,0", scale: 3 },
} as const;
type SizeName = keyof typeof sizes;
const themes = ["light", "dark"] as const;
type Theme = (typeof themes)[number];
const browsers = ["chromium", "webkit"] as const;
type BrowserName = (typeof browsers)[number];

const chrome = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome";
const repo = path.resolve(import.meta.dir, "../..");
const out = path.join(repo, "build/shots");

/** Filled in from the arguments, so not read-only. */
interface Options {
  only: string[];
  sizes: SizeName[];
  themes: Theme[];
  shots: string[];
  smoke: boolean;
  omp: boolean;
  browser: BrowserName;
}

function parseOptions(args: readonly string[]): Options {
  const options: Options = {
    only: [],
    sizes: ["desktop", "phone"],
    themes: [...themes],
    shots: [],
    smoke: process.env.SMOKE === "1",
    omp: process.env.OMP === "1",
    browser: "chromium",
  };
  const value = (index: number) => {
    const next = args[index + 1];
    if (next === undefined) throw new Error(`${args[index]} needs a value`);
    return next;
  };
  for (let index = 0; index < args.length; index++) {
    const arg = args[index]!;
    if (arg === "--smoke") options.smoke = true;
    else if (arg === "--omp") options.omp = true;
    else if (arg === "--only") options.only.push(value(index++));
    else if (arg === "--shot") options.shots.push(value(index++));
    else if (arg === "--sizes") options.sizes = listOf(value(index++), Object.keys(sizes) as SizeName[]);
    else if (arg === "--themes") options.themes = listOf(value(index++), themes);
    else if (arg === "--browser") options.browser = oneOf(value(index++), browsers);
    else throw new Error(`unknown option ${arg}`);
  }
  return options;
}

function oneOf<T extends string>(item: string, allowed: readonly T[]): T {
  if (!allowed.includes(item as T)) throw new Error(`${item}: expected one of ${allowed.join(", ")}`);
  return item as T;
}

function listOf<T extends string>(list: string, allowed: readonly T[]): T[] {
  return list.split(",").map((item) => oneOf(item, allowed));
}

interface Shot extends Screen {
  /** `<slice>-<name>`, or the ad-hoc shot's name. */
  readonly id: string;
  /** The scenario file's name, or the ad-hoc shot's; a journey's steps are `<slice>-<step>`. */
  readonly slice: string;
}

/** The `stop` of every slice the run loaded. */
const sliceStops: (() => Promise<string[]>)[] = [];

async function loadShots(options: Options): Promise<Shot[]> {
  if (options.shots.length > 0) {
    return options.shots.map((shot) => {
      const split = shot.indexOf("=");
      if (split < 1) throw new Error(`--shot ${shot}: expected <name>=<query>`);
      const name = shot.slice(0, split);
      return { id: name, slice: name, name, query: shot.slice(split + 1) };
    });
  }
  const shots: Shot[] = [];
  const dir = path.join(import.meta.dir, "shots");
  for (const file of [...new Bun.Glob("*.ts").scanSync(dir)].sort()) {
    const slice = path.basename(file, ".ts");
    // Not even imported when no --only prefix can match its screens, so a broken slice stops only its own runs.
    const head = `${slice}-`;
    const wanted = (prefix: string) => head.startsWith(prefix) || prefix.startsWith(head);
    if (options.only.length > 0 && !options.only.some(wanted)) continue;
    const module = (await import(path.join(dir, file))) as { screens?: Screen[]; stop?: () => Promise<string[]> };
    if (!module.screens) throw new Error(`scripts/shots/${file} exports no screens`);
    for (const screen of module.screens) shots.push({ ...screen, id: `${slice}-${screen.name}`, slice });
    if (module.stop) sliceStops.push(module.stop);
  }
  return shots.filter(
    (shot) =>
      (options.only.length === 0 || options.only.some((prefix) => shot.id.startsWith(prefix))) &&
      (!shot.omp || options.omp),
  );
}

/** The dev bridge on a free port, its log in `<tmp>/devbridge.log`; resolves to the page's address. */
async function startCore(
  tmp: string,
  home: string,
  smoke: boolean,
  env: Readonly<Record<string, string>>,
): Promise<{ core: Subprocess; base: string }> {
  const core = Bun.spawn([path.join(repo, "build/devbridge"), "-listen", "127.0.0.1:0", "-static", path.join(repo, "ui/dist")], {
    env: {
      ...process.env,
      HOME: home,
      // app/dev_overrides.ts: "this computer" runs in this HOME, and the probe skips the account's system paths.
      OMPANION_LOCAL_HOME: home,
      OMPCORE_DATA_DIR: path.join(tmp, "data"),
      OMPCORE_CACHE_DIR: path.join(tmp, "cache"),
      OMPCORE_SMOKE: smoke ? "1" : "",
      ...env,
    },
    stdin: "ignore",
    stdout: "ignore",
    stderr: "pipe",
  });
  const log = Bun.file(path.join(tmp, "devbridge.log")).writer();
  const decoder = new TextDecoder();
  const reader = core.stderr.getReader();
  let seen = "";
  let base: string | undefined;
  while (base === undefined) {
    const { value, done } = await reader.read();
    if (done) throw new Error(`the dev bridge exited (${await core.exited}) before serving:\n${seen}`);
    const text = decoder.decode(value, { stream: true });
    log.write(text);
    seen += text;
    const match = /serving the core at ws:\/\/(\S+)\/bridge/.exec(seen);
    if (match) base = `http://${match[1]}/`;
  }
  // Keep draining its log, so the core never blocks on a full pipe.
  void (async () => {
    for (;;) {
      const { value, done } = await reader.read();
      if (done) break;
      log.write(value);
    }
    await log.end();
  })();
  return { core, base };
}

/** The fake provider and the tested omp at `<home>/.local/bin/omp` (harness/dev-machine.sh). */
async function startOmp(home: string): Promise<FakeProvider> {
  const { FakeProvider } = await import("../../harness/fake-provider/client.ts");
  const provider = await FakeProvider.start();
  const setup = Bun.spawnSync(["sh", path.join(repo, "harness/dev-machine.sh"), home, String(provider.port)], {
    stdout: "inherit",
    stderr: "inherit",
  });
  if (setup.exitCode !== 0) {
    await provider.stop();
    throw new Error(`harness/dev-machine.sh exited ${setup.exitCode}`);
  }
  return provider;
}

/** A core on its own temporary HOME, data and cache directories; in an OMP=1 run with its own fake provider and omp. */
interface Run {
  readonly home: string;
  /** The page's address on the dev bridge. */
  readonly base: string;
  readonly provider: FakeProvider | undefined;
  /** Stops the core and every process it started in the HOME; false when one outlived them (then killed). */
  stop(): Promise<boolean>;
}

async function startRun(omp: boolean, smoke: boolean, env: Readonly<Record<string, string>>): Promise<Run> {
  const tmp = await fs.mkdtemp(path.join(os.tmpdir(), "ompanion-shots-"));
  const home = path.join(tmp, "home");
  let provider: FakeProvider | undefined;
  let core: Subprocess | undefined;
  const stop = async () => {
    core?.kill();
    await core?.exited;
    await provider?.stop();
    const left = await endAndRemove(tmp);
    for (const line of left) console.error(`LEFT RUNNING ${line}`);
    return left.length === 0;
  };
  try {
    await fs.mkdir(home);
    if (omp) provider = await startOmp(home);
    const started = await startCore(tmp, home, smoke, env);
    core = started.core;
    return { home, base: started.base, provider, stop };
  } catch (error) {
    await stop();
    throw error;
  }
}

async function runSmoke(browser: Browser, base: string): Promise<boolean> {
  const page = await browser.newPage();
  page.on("console", (message) => console.log(`console.${message.type()}: ${message.text()}`));
  page.on("pageerror", (error) => console.log(`pageerror: ${error.message}`));
  await page.goto(`${base}?devbridge=${encodeURIComponent(bridgeUrl(base))}`);
  try {
    await page.waitForFunction(() => document.querySelector(".smoke-lines")?.textContent?.includes("SMOKE-DONE"), null, {
      timeout: 120_000,
    });
  } finally {
    console.log(await page.evaluate(() => document.body.innerText));
  }
  const lines = (await page.locator(".smoke-lines").textContent()) ?? "";
  const done = /SMOKE-DONE (\{.*\})/.exec(lines);
  const counts = done ? (JSON.parse(done[1]!) as { passed: number; total: number }) : undefined;
  return counts !== undefined && counts.passed === counts.total;
}

async function runShot(
  browser: Browser,
  run: Run,
  shot: Shot,
  size: SizeName,
  theme: Theme,
  browserName: BrowserName,
): Promise<boolean> {
  const { base, home, provider } = run;
  const { width, height, scale, query } = sizes[size];
  const context = await browser.newContext({
    viewport: { width, height },
    deviceScaleFactor: scale,
    colorScheme: theme,
    locale: "en-US",
    // The pictures show where things rest. With the system's reduced motion the app's motion runs at 5 % of its
    // length (app/motion.ts), so a scenario's next step does not read a page that is still sliding in as shown.
    reducedMotion: "reduce",
  });
  const suffix = `${size}-${theme}${browserName === "webkit" ? "-webkit" : ""}`;
  const name = `${shot.id}-${suffix}`;
  try {
    const page = await context.newPage();
    page.on("pageerror", (error) => console.error(`${name}: ${error.message}`));
    page.on("console", (message) => {
      if (message.type() === "error") console.error(`${name}: console: ${message.text()}`);
    });
    page.on("response", (response) => {
      if (response.status() >= 400) console.error(`${name}: ${response.status()} ${response.url()}`);
    });
    const shoot = async (id: string) => {
      // Fonts and the core's answers settle; the pointer leaves, so no tooltip or hover tone is in the picture; motion
      // that ends (a page transition, a menu or dialog opening, a ripple) ends, so the picture shows where it rests.
      await page.waitForTimeout(500);
      await page.mouse.move(0, height - 1);
      await page.evaluate(() =>
        Promise.all(
          document
            .getAnimations()
            .filter((animation) => animation.playState === "running")
            .filter((animation) => animation.effect?.getComputedTiming().endTime !== Infinity)
            .map(
              (animation) =>
                new Promise<void>((resolve) => {
                  animation.addEventListener("finish", () => resolve(), { once: true });
                  animation.addEventListener("cancel", () => resolve(), { once: true });
                }),
            ),
        ),
      );
      const file = path.join(out, `${id}-${suffix}.png`);
      await page.screenshot({ path: file });
      console.log(`shot ${path.relative(repo, file)}`);
    };
    const extra = shot.query ? `&${shot.query}` : "";
    await page.goto(`${base}?devbridge=${encodeURIComponent(bridgeUrl(base))}${query}${extra}`);
    // A gallery's root may have no box of its own (its parts lay out inside it), so attached is enough there.
    if (shot.query) await page.waitForSelector("#root > *", { state: "attached" });
    else await page.waitForSelector(".shell-wide, .shell-narrow");
    const shotContext: ShotContext = {
      page,
      size,
      home,
      provider,
      call: async <T>(method: string, params?: unknown) =>
        (await page.evaluate(
          ([method, params]) => {
            if (!window.ompDev) throw new Error("the page has no window.ompDev: not on the dev bridge");
            return window.ompDev.call(method, params);
          },
          [method, params] as const,
        )) as T,
      exec: (command) =>
        page.evaluate(async (command): Promise<ExecResult> => {
          if (!window.ompDev) throw new Error("the page has no window.ompDev: not on the dev bridge");
          const stream = await window.ompDev.openStream("local.exec", { command });
          let stdout = "";
          let stderr = "";
          stream.listen({
            data: (data, fd) => {
              if (fd === "stdout") stdout += data;
              else stderr += data;
            },
          });
          const exit = await stream.exited;
          return { stdout, stderr, code: exit.code };
        }, command),
      snap: (step) => shoot(`${shot.slice}-${step}`),
    };
    await shot.reach?.(shotContext);
    await shoot(shot.id);
    return true;
  } catch (error) {
    console.error(`FAILED ${name}: ${error instanceof Error ? error.message : String(error)}`);
    return false;
  } finally {
    await context.close();
  }
}

function bridgeUrl(base: string): string {
  return new URL("bridge", base.replace(/^http/, "ws")).href;
}

/** Chrome as installed, or the WebKit build of this playwright-core, installed into Playwright's cache when missing. */
async function launch(name: BrowserName): Promise<Browser> {
  if (name === "chromium") return chromium.launch({ executablePath: chrome, headless: true });
  if (!(await Bun.file(webkit.executablePath()).exists())) {
    const install = Bun.spawnSync([process.execPath, "x", "playwright-core", "install", "webkit"], {
      cwd: path.join(repo, "ui"),
      stdout: "inherit",
      stderr: "inherit",
    });
    if (install.exitCode !== 0) throw new Error(`playwright-core install webkit exited ${install.exitCode}`);
  }
  return webkit.launch({ headless: true });
}

const options = parseOptions(process.argv.slice(2));
const shots = options.smoke ? [] : await loadShots(options);
if (!options.smoke && shots.length === 0) throw new Error("no screen matches");

let browser: Browser | undefined;
const live = new Set<Run>();
let passed = true;

async function begin(env: Readonly<Record<string, string>> = {}): Promise<Run> {
  const run = await startRun(options.omp, options.smoke, env);
  live.add(run);
  return run;
}

async function end(run: Run): Promise<void> {
  live.delete(run);
  if (!(await run.stop())) passed = false;
}

async function cleanUp(): Promise<void> {
  await browser?.close();
  for (const run of [...live]) await end(run);
  for (const stop of sliceStops) {
    const left = await stop();
    for (const line of left) console.error(`LEFT RUNNING ${line}`);
    if (left.length > 0) passed = false;
  }
}
for (const signal of ["SIGINT", "SIGTERM"] as const) {
  process.on(signal, () => {
    void cleanUp().finally(() => process.exit(1));
  });
}

try {
  browser = await launch(options.browser);
  console.log(`browser: ${options.browser} ${browser.version()}`);
  if (options.smoke) {
    passed = await runSmoke(browser, (await begin()).base);
  } else {
    // A run replaces its own browser's pictures and keeps the other browser's.
    await fs.mkdir(out, { recursive: true });
    for (const file of await fs.readdir(out)) {
      if (file.endsWith(".png") && file.endsWith("-webkit.png") === (options.browser === "webkit")) {
        await fs.rm(path.join(out, file));
      }
    }
    let shared: Run | undefined;
    for (const shot of shots) {
      for (const size of options.sizes.filter((wanted) => shot.sizes?.includes(wanted) ?? true)) {
        for (const theme of options.themes) {
          const own = shot.fresh === true || shot.env !== undefined;
          const run = own ? await begin(shot.env) : (shared ??= await begin());
          try {
            if (!(await runShot(browser, run, shot, size, theme, options.browser))) passed = false;
          } finally {
            if (own) await end(run);
          }
        }
      }
    }
  }
} finally {
  await cleanUp();
}
process.exit(passed ? 0 : 1);
