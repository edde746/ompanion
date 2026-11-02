// Smoke mode (docs/contracts/bridge.md, "Smoke runs"): every check writes `SMOKE <json>` through core.log, then
// `SMOKE-DONE`, then core.exit. Each check has its own deadline, so a broken one reports instead of hanging the run.
// Loads only in a smoke run, with its stylesheet.
import "./styles.css";
import { render } from "@solidjs/web";
import { createSignal, onSettled } from "solid-js";
import { AgentFrame } from "./AgentFrame";
import { coreInfoMs, firstPaintMs } from "./app/boot_timing";
import { AppDatabase } from "./app/database/app_database";
import { flutterData, hasFlutterData } from "./app/database/flutter_data";
import { importFlutterData, sameJson } from "./app/database/flutter_import";
import { measureEcho, measureFlood } from "./bridge_measure";
import { call, type CoreInfo, onEvent, openStream, type Stream, transportName } from "./bridge";
import { asJsonObject, object, optObject } from "./core/rpc/json_fields";
import { toSftpPath } from "./core/host/scripts";
import { base64Decode } from "./core/util/base64";
import { deferred } from "./deferred";
import { Markdown } from "./Markdown";

interface CheckResult {
  check: string;
  pass: boolean;
  [measurement: string]: unknown;
}

interface Context {
  info: CoreInfo;
  /** A visible element the check may render into; emptied after the check. */
  stage: HTMLElement;
  /** Runs fn when the check ends, however it ends. */
  defer(fn: () => void): void;
}

interface Check {
  name: string;
  timeoutMs: number;
  desktopOnly?: boolean;
  run(context: Context): Promise<Record<string, unknown>>;
}

const round = (value: number) => Math.round(value * 1000) / 1000;

const markdownSample = [
  "# Smoke heading",
  "",
  "- first item",
  "- second item with $e^{i\\pi} + 1 = 0$",
  "",
  "| a | b |",
  "|---|---|",
  "| 1 | 2 |",
  "",
  "```ts",
  "const answer: number = 42;",
  "```",
  "",
].join("\n");

const probeUrl = "https://example.com/ompanion-smoke-probe";

/** Proves, from inside the frame, that inline script runs and that fetch and an image load of an outside URL fail. */
const htmlProbeSample = `<!doctype html>
<html><body style="margin:0;font-family:sans-serif">
<h1 style="margin:8px">Agent HTML probe</h1>
<p id="status" style="margin:8px">inline script did not run</p>
<div style="height:120px;margin:8px;background:linear-gradient(90deg,#4a8,#48a)"></div>
<script>
  document.getElementById("status").textContent = "inline script ran";
  var violations = [];
  document.addEventListener("securitypolicyviolation", function (event) {
    violations.push({ directive: event.effectiveDirective, blocked: event.blockedURI });
  });
  var fetched = fetch("${probeUrl}.json").then(function () { return "loaded"; }, function () { return "blocked"; });
  var image = new Promise(function (resolve) {
    var img = new Image();
    img.onload = function () { resolve("loaded"); };
    img.onerror = function () { resolve("blocked"); };
    img.src = "${probeUrl}.png";
  });
  Promise.all([fetched, image]).then(function (results) {
    // Violation events are queued as tasks; let them arrive first.
    setTimeout(function () {
      parent.postMessage({ type: "probe", inlineScript: true, fetch: results[0], image: results[1], violations: violations }, "*");
    }, 100);
  });
</script>
</body></html>`;

function timeout(ms: number, name: string): Promise<never> {
  const { promise, reject } = deferred<never>();
  setTimeout(() => reject(new Error(`${name} timed out after ${ms} ms`)), ms);
  return promise;
}

/** Collects a stream's output and exit. */
async function collect(stream: Stream): Promise<{ stdout: string; stderr: string; code: number | null; error?: string }> {
  let stdout = "";
  let stderr = "";
  stream.listen({
    data(data, fd) {
      if (fd === "stdout") stdout += data;
      else stderr += data;
    },
  });
  const exit = await stream.exited;
  return { stdout, stderr, code: exit.code, error: exit.error };
}

const checks: Check[] = [
  {
    name: "info",
    timeoutMs: 5000,
    async run() {
      const info = await call<CoreInfo>("core.info");
      // Startup as the page saw it: its first painted frame and the core's first answer, in ms since it began loading.
      return { epochMs: Date.now(), info, firstPaintMs: round(await firstPaintMs), coreInfoMs: round(coreInfoMs() ?? -1) };
    },
  },
  {
    name: "echo",
    timeoutMs: 20000,
    run: () => measureEcho(200).then((result) => ({ ...result })),
  },
  {
    name: "flood",
    timeoutMs: 60000,
    async run(context) {
      const result = await measureFlood(20_000_000, 65_536, {
        onStream: (stream) => context.defer(() => void (stream.done || stream.kill())),
      });
      return { ...result };
    },
  },
  {
    name: "markdown",
    timeoutMs: 5000,
    async run(context) {
      const host = context.stage.appendChild(document.createElement("div"));
      context.defer(render(() => <Markdown text={markdownSample} />, host));
      const count = (selector: string) => host.querySelectorAll(selector).length;
      const counts = () => ({
        heading: count("h1"),
        listItems: count("ul > li"),
        table: count("table"),
        tableCells: count("td"),
        codeBlock: count(".code-block pre"),
        math: count(".katex"),
      });
      // markdown-it and KaTeX load with import() after the first render: wait for them inside the check's deadline.
      const deadline = performance.now() + 4500;
      let found = counts();
      while (Object.values(found).some((n) => n === 0) && performance.now() < deadline) {
        await new Promise((resolve) => setTimeout(resolve, 50));
        found = counts();
      }
      const missing = Object.entries(found).filter(([, n]) => n === 0).map(([name]) => name);
      if (missing.length) throw new Error(`missing: ${missing.join(", ")}`);
      return found;
    },
  },
  {
    name: "html",
    timeoutMs: 10000,
    async run(context) {
      const host = context.stage.appendChild(document.createElement("div"));
      const probe = deferred<Record<string, unknown>>();
      const height = deferred<number>();
      context.defer(
        render(
          () => (
            <AgentFrame
              html={htmlProbeSample}
              onHeight={(h) => h > 0 && height.resolve(h)}
              onMessage={(data) => {
                if (typeof data === "object" && data !== null && "type" in data && data.type === "probe") {
                  probe.resolve(data as Record<string, unknown>);
                }
              }}
            />
          ),
          host,
        ),
      );
      const [result, heightPx] = await Promise.all([probe.promise, height.promise]);
      const violations = Array.isArray(result.violations) ? (result.violations as { directive: string }[]) : [];
      const directives = violations.map((violation) => violation.directive);
      const measured = {
        inlineScript: result.inlineScript === true,
        heightPx,
        fetch: result.fetch,
        image: result.image,
        violations: directives,
      };
      if (!measured.inlineScript) throw new Error("the inline script did not run");
      if (result.fetch !== "blocked" || !directives.includes("connect-src")) {
        throw new Error(`fetch was not blocked by the frame's policy: ${JSON.stringify(measured)}`);
      }
      if (result.image !== "blocked" || !directives.includes("img-src")) {
        throw new Error(`the image was not blocked by the frame's policy: ${JSON.stringify(measured)}`);
      }
      return measured;
    },
  },
  {
    name: "terminal",
    timeoutMs: 15000,
    async run(context) {
      const { createTerminal, written, bufferLines } = await import("./term");
      const host = context.stage.appendChild(document.createElement("div"));
      host.className = "smoke-terminal";
      const term = createTerminal({ cols: 80, rows: 12, convertEol: !context.info.local });
      context.defer(() => term.dispose());
      term.open(host);
      let marker: string;
      let source: string;
      if (context.info.local) {
        marker = `smoke-terminal-${Math.random().toString(36).slice(2, 8)}`;
        const argv = context.info.goos === "windows" ? ["cmd", "/c", `echo ${marker}`] : ["sh", "-c", `echo ${marker}`];
        const stream = await openStream("pty.open", { argv, cols: 80, rows: 12 });
        context.defer(() => void (stream.done || stream.kill()));
        stream.listen({ data: (data) => term.write(data) });
        const exit = await stream.exited;
        if (exit.code !== 0) throw new Error(`pty exited ${exit.code} ${exit.error ?? ""}`);
        source = "pty.open";
      } else {
        let tail = "";
        await measureFlood(200_000, 4096, {
          onStream: (stream) => context.defer(() => void (stream.done || stream.kill())),
          onData(data) {
            term.write(data);
            tail = (tail + data).slice(-200);
          },
        });
        marker = tail.trimEnd().split("\n").pop()!;
        source = "core.flood";
      }
      await written(term);
      const lines = bufferLines(term);
      if (!lines.some((line) => line.trim() === marker)) throw new Error(`xterm does not show "${marker}"`);
      return { source, marker, rows: lines.length };
    },
  },
  {
    name: "exec",
    timeoutMs: 10000,
    desktopOnly: true,
    async run(context) {
      const argv = context.info.goos === "windows" ? ["cmd", "/c", "echo smoke-ok"] : ["sh", "-c", "echo smoke-ok"];
      const stream = await openStream("local.exec", { argv });
      context.defer(() => void (stream.done || stream.kill()));
      const { stdout, stderr, code, error } = await collect(stream);
      if (code !== 0) throw new Error(`exited ${code} ${error ?? ""} ${stderr}`);
      if (stdout.trim() !== "smoke-ok") throw new Error(`stdout was ${JSON.stringify(stdout)}`);
      return { stdout: stdout.trim(), code };
    },
  },
  {
    name: "pty",
    timeoutMs: 15000,
    desktopOnly: true,
    async run(context) {
      const { createTerminal, written, bufferLines } = await import("./term");
      // A terminal that is never opened still parses what it is given: the shell's redraws and escapes resolve to
      // the rows a person would see.
      const term = createTerminal({ cols: 120, rows: 30 });
      context.defer(() => term.dispose());
      const marker = `smoke-pty-${Math.random().toString(36).slice(2, 8)}`;
      const stream = await openStream("pty.open", { cols: 120, rows: 30 });
      context.defer(() => void (stream.done || stream.kill()));
      const seen = deferred<void>();
      const prompted = deferred<void>();
      let bytes = 0;
      let lastData = 0;
      // The output row is the marker alone, or after a prompt when the shell has no line editing (dash prints its
      // prompt and the output on one row); the echoed command row is the one that says echo.
      const shown = (line: string) => line.trim().endsWith(marker) && !line.includes("echo");
      stream.listen({
        data(data) {
          bytes += data.length;
          lastData = performance.now();
          prompted.resolve();
          term.write(data, () => {
            if (bufferLines(term).some(shown)) seen.resolve();
          });
        },
        exit: (exit) => {
          const error = new Error(`the shell exited ${exit.code} ${exit.error ?? ""}`);
          prompted.reject(error);
          seen.reject(error);
        },
      });
      // Type once the shell is listening: after its first output, and once a banner or rc output has gone quiet.
      const start = performance.now();
      await prompted.promise;
      while (performance.now() - lastData < 200 && performance.now() - start < 3000) {
        await new Promise((resolve) => setTimeout(resolve, 50));
      }
      const promptMs = round(performance.now() - start);
      await stream.write(`echo ${marker}\r`);
      await seen.promise;
      await written(term);
      return { marker, bytes, promptMs };
    },
  },
  {
    name: "shell",
    timeoutMs: 5000,
    async run(context) {
      const info = await call<{ platform: string; osVersion: string; appVersion: string; device: string; push: boolean }>(
        "shell.info",
      );
      const expected: Record<string, string> = { darwin: "macos", ios: "ios", android: "android", windows: "windows", linux: "linux" };
      if (info.platform !== expected[context.info.goos]) {
        throw new Error(`shell.info says ${info.platform} on goos ${context.info.goos}`);
      }
      return { platform: info.platform, osVersion: info.osVersion, appVersion: info.appVersion, device: info.device };
    },
  },
  {
    name: "secret",
    timeoutMs: 5000,
    async run() {
      const key = "smoke.secret";
      const value = `secret-${Math.random().toString(36).slice(2, 10)} ✓`;
      await call("shell.secretSet", { key, value });
      const read = await call<{ value: string | null }>("shell.secretGet", { key });
      await call("shell.secretDelete", { key });
      const gone = await call<{ value: string | null }>("shell.secretGet", { key });
      if (read.value !== value) throw new Error(`read back ${JSON.stringify(read.value)}`);
      if (gone.value !== null) throw new Error(`still there after delete: ${JSON.stringify(gone.value)}`);
      return {};
    },
  },
  {
    // Only the OS shows whether a notification came, so this check runs when a harness asks for it with
    // OMPCORE_SMOKE_NOTIFY=<seconds> and then reads the system's notifications: "shown now" at once, "scheduled" at
    // atMs (it replaced "replaced", scheduled under the same id), and nothing of "smoke.cancelled".
    name: "notify",
    timeoutMs: 10000,
    async run() {
      const { env } = await call<{ env: Record<string, string> }>("core.env", { names: ["OMPCORE_SMOKE_NOTIFY"] });
      const seconds = Number(env.OMPCORE_SMOKE_NOTIFY);
      if (!seconds) return { skipped: true };
      const atMs = Date.now() + seconds * 1000;
      const title = "ompanion smoke";
      await call("shell.notify", { id: "smoke.now", title, body: "shown now" });
      await call("shell.notifySchedule", { id: "smoke.later", atMs, title, body: "replaced" });
      await call("shell.notifySchedule", { id: "smoke.later", atMs, title, body: "scheduled" });
      await call("shell.notifySchedule", { id: "smoke.cancelled", atMs, title, body: "cancelled" });
      await call("shell.notifyCancel", { id: "smoke.cancelled" });
      return { atMs };
    },
  },
  {
    // Desktop paths (shell.pickFiles, shell.clipboardFiles, shell.drag and shell.drop) need someone to choose, copy and
    // drag. With OMPCORE_SMOKE_PATHS=<folder>, a harness copied <folder>/a.txt and <folder>/sub before the launch, and
    // acts on each `SMOKE-STEP <step>` line: chooses a.txt and b.txt in the open panel (pick-files), the folder sub
    // in the folder panel (pick-folder), and drags a.txt and sub onto the window (drop, left out with
    // OMPCORE_SMOKE_NO_DROP=1 where the harness cannot drag).
    name: "paths",
    timeoutMs: 120000,
    desktopOnly: true,
    async run(context) {
      const names = ["OMPCORE_SMOKE_PATHS", "OMPCORE_SMOKE_NO_DROP"];
      const { env } = await call<{ env: Record<string, string> }>("core.env", { names });
      const folder = env.OMPCORE_SMOKE_PATHS;
      if (!folder) return { skipped: true };
      const separator = context.info.goos === "windows" ? "\\" : "/";
      const expect = (what: string, paths: string[], names: string[]) => {
        const want = names.map((name) => `${folder}${separator}${name}`).sort();
        if (JSON.stringify([...paths].sort()) !== JSON.stringify(want)) {
          throw new Error(`${what} gave ${JSON.stringify(paths)}, not ${JSON.stringify(want)}`);
        }
      };
      const step = (name: string) => call("core.log", { line: `SMOKE-STEP ${name}` });
      type Paths = { paths: string[] };

      const copied = await call<Paths>("shell.clipboardFiles");
      expect("shell.clipboardFiles", copied.paths, ["a.txt", "sub"]);
      await step("pick-files");
      const files = await call<Paths>("shell.pickFiles", { multiple: true, startIn: folder });
      expect("shell.pickFiles", files.paths, ["a.txt", "b.txt"]);
      await step("pick-folder");
      const folders = await call<Paths>("shell.pickFiles", { directory: true, startIn: folder });
      expect("shell.pickFiles directory", folders.paths, ["sub"]);

      if (env.OMPCORE_SMOKE_NO_DROP === "1") {
        return { clipboard: copied.paths, files: files.paths, folder: folders.paths, drop: "skipped" };
      }
      const dragging = deferred<void>();
      const dropped = deferred<string[]>();
      context.defer(onEvent<{ active: boolean }>("shell.drag", ({ active }) => active && dragging.resolve()));
      context.defer(onEvent<Paths>("shell.drop", ({ paths }) => dropped.resolve(paths)));
      await step("drop");
      await dragging.promise;
      const drop = await dropped.promise;
      expect("shell.drop", drop, ["a.txt", "sub"]);
      return { clipboard: copied.paths, files: files.paths, folder: folders.paths, drop };
    },
  },
  {
    name: "store",
    timeoutMs: 5000,
    async run() {
      const text = JSON.stringify({ smoke: Date.now(), text: "ünïcode" });
      await call("store.write", { name: "smoke", text });
      const read = await call<{ text: string | null }>("store.read", { name: "smoke" });
      await call("store.delete", { name: "smoke" });
      const gone = await call<{ text: string | null }>("store.read", { name: "smoke" });
      if (read.text !== text) throw new Error(`read back ${JSON.stringify(read.text)}`);
      if (gone.text !== null) throw new Error("still there after delete");
      return {};
    },
  },
  {
    // A harness that left the Flutter app's data behind (harness/flutter-seed) names the seed's expected.json, at a
    // path the app can read, with OMPCORE_EXPECT_IMPORT. A smoke run never boots the app, so the check imports as
    // boot does, then compares the documents and secrets with the file and sees the Flutter data set aside.
    name: "flutter-import",
    timeoutMs: 60000,
    async run() {
      const { env } = await call<{ env: Record<string, string> }>("core.env", { names: ["OMPCORE_EXPECT_IMPORT"] });
      const file = env.OMPCORE_EXPECT_IMPORT;
      if (!file) return { skipped: true };
      // The harness names a native path; fs paths are in SFTP form (`C:\…` is `/C:/…`).
      const { data } = await call<{ data: string }>("fs.read", { machine: "local", path: toSftpPath(file) });
      const expected = asJsonObject(JSON.parse(new TextDecoder().decode(base64Decode(data))), file);
      const found = await flutterData();
      if (!hasFlutterData(found)) throw new Error("shell.flutterData found no Flutter data");
      await importFlutterData(new AppDatabase(), found);
      const documents = object(expected, "store");
      const secrets = optObject(expected, "secrets") ?? {};
      const differ: string[] = [];
      for (const [name, rows] of Object.entries(documents)) {
        const { text } = await call<{ text: string | null }>("store.read", { name });
        if (text === null || !sameJson(JSON.parse(text), rows)) differ.push(name);
      }
      for (const [key, value] of Object.entries(secrets)) {
        const { value: stored } = await call<{ value: string | null }>("shell.secretGet", { key });
        if (stored !== value) differ.push(key);
      }
      if (differ.length > 0) throw new Error(`not as ${file} says: ${differ.join(", ")}`);
      if (hasFlutterData(await flutterData())) throw new Error("the Flutter data is still there after the import");
      return { documents: Object.keys(documents).length, secrets: Object.keys(secrets).length };
    },
  },
  {
    name: "cache",
    timeoutMs: 10000,
    async run(context) {
      // A 1×1 PNG written into the core's cache directory must load through the shell's `cache/` route.
      const png = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFBQIAX8jx0gAAAABJRU5ErkJggg==";
      const paths = await call<{ data: string; cache: string }>("core.paths");
      const name = `smoke-${Date.now()}.png`;
      await call("fs.write", { machine: "local", path: `${paths.cache}/${name}`, data: png });
      context.defer(() => void call("fs.remove", { machine: "local", path: `${paths.cache}/${name}` }));
      const image = document.createElement("img");
      context.stage.append(image);
      const loaded = deferred<void>();
      image.onload = () => loaded.resolve();
      image.onerror = () => loaded.reject(new Error(`cache/${name} did not load`));
      image.src = `cache/${name}`;
      await loaded.promise;
      if (image.naturalWidth !== 1) throw new Error(`naturalWidth ${image.naturalWidth}`);
      return { cache: paths.cache };
    },
  },
];

/** Runs every check that applies to this platform, reports each, then exits the core. */
async function runSmoke(info: CoreInfo, stage: HTMLElement, report: (line: string) => void): Promise<void> {
  const results: CheckResult[] = [];
  for (const check of checks) {
    if (check.desktopOnly && !info.local) continue;
    const cleanups: (() => void)[] = [];
    const context: Context = { info, stage, defer: (fn) => cleanups.push(fn) };
    const start = performance.now();
    let result: CheckResult;
    try {
      const measured = await Promise.race([check.run(context), timeout(check.timeoutMs, check.name)]);
      result = { check: check.name, pass: true, ms: round(performance.now() - start), ...measured };
    } catch (error) {
      result = { check: check.name, pass: false, ms: round(performance.now() - start), error: String(error) };
    }
    for (const cleanup of cleanups.reverse()) cleanup();
    stage.replaceChildren();
    results.push(result);
    const line = `SMOKE ${JSON.stringify(result)}`;
    report(line);
    await call("core.log", { line });
  }
  const passed = results.filter((result) => result.pass).length;
  const done = `SMOKE-DONE ${JSON.stringify({ passed, total: results.length })}`;
  report(done);
  await call("core.log", { line: done });
  await call("core.exit", { code: passed === results.length ? 0 : 1 });
}

/** The smoke run's page: its lines as they come, and the stage its checks render into. */
export function SmokeView(props: { info: CoreInfo }) {
  let stage!: HTMLDivElement;
  const [lines, setLines] = createSignal<string[]>([]);
  const report = (line: string) => setLines((list) => [...list, line]);

  onSettled(() => {
    runSmoke(props.info, stage, report).catch((error: unknown) => {
      // Reporting itself failed: say so on screen and in the log, then exit non-zero so the harness never waits.
      const line = `SMOKE-ERROR ${String(error)}`;
      report(line);
      console.error(line);
      call("core.exit", { code: 1 }).catch((failure: unknown) => report(`core.exit failed: ${String(failure)}`));
    });
  });

  return (
    <main class="view">
      <h1>Smoke run</h1>
      <div class="muted">
        {transportName} · core {props.info.version} · {props.info.goos}/{props.info.goarch} ·{" "}
        {props.info.local ? "desktop" : "phone"}
      </div>
      <pre class="smoke-lines mono">{lines().join("\n")}</pre>
      <div class="smoke-stage" ref={stage} />
    </main>
  );
}
