// The device side of the store captures: runs on studio.local inside the devpool lease capture.sh takes, from the
// studio copy of the repository (scripts/studio.sh). It starts the fake provider, the SSH demo host (demo/host.sh,
// seeded by demo/seed-host.sh) and the scripted turns (demo/turns.ts), runs the app with the scenario
// (scenario/main.ts) injected, photographs the screen whenever the scenario asks, and removes everything it made.
//
//   bun store/screenshots/capture.ts <class> --app <path> --out <dir>
//
// Classes: ios-phone (an iPhone 17 Pro Max simulator, made for the run), ios-ipad (an iPad Pro 13-inch (M5)
// simulator, made for the run), macos (the macOS app's window; inside shells/apple/studio-app.sh's claim_macos),
// play-phone (the phone devpool leased, $ANDROID_SERIAL on air.local). --app is the simulator or macOS .app, or the
// debug APK. Raw captures land in <out>/<class>/: <shot>.png, <shot>.json (the scenario's regions and viewport, for
// compose.py), capture.log (this run's log) and app.log (the app's lines).
import * as fs from "node:fs/promises";
import * as os from "node:os";
import * as path from "node:path";
import type { Subprocess } from "bun";
import { FakeProvider } from "../../harness/fake-provider/client.ts";
import type { Settings } from "./scenario/main.ts";

const id = "com.edde746.ompanion";
const repo = path.resolve(import.meta.dir, "../..");
/** The demo host's home: short and fixed, because the chat's header shows the session's full path. */
const demoHome = "/Users/Shared/omp";
const air = "air.local";
const adbPath = "~/Library/Android/sdk/platform-tools/adb";

type ShotClass = "ios-phone" | "ios-ipad" | "macos" | "play-phone";
const simulators: Partial<Record<ShotClass, string>> = {
  "ios-phone": "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro-Max",
  "ios-ipad": "com.apple.CoreSimulator.SimDeviceType.iPad-Pro-13-inch-M5-12GB",
};
const runtime = "com.apple.CoreSimulator.SimRuntime.iOS-27-0";

const [shotClass, ...rest] = process.argv.slice(2) as [ShotClass, ...string[]];
const option = (name: string) => {
  const at = rest.indexOf(name);
  if (at === -1 || rest[at + 1] === undefined) throw new Error(`${name} is required`);
  return rest[at + 1]!;
};
if (!["ios-phone", "ios-ipad", "macos", "play-phone"].includes(shotClass)) {
  throw new Error(`usage: capture.ts ios-phone|ios-ipad|macos|play-phone --app <path> --out <dir> (got ${shotClass})`);
}
const app = path.resolve(option("--app"));
const shots = path.resolve(option("--out"), shotClass);
await fs.rm(shots, { recursive: true, force: true });
await fs.mkdir(shots, { recursive: true });
const runLog = Bun.file(path.join(shots, "capture.log")).writer();
const appLog = Bun.file(path.join(shots, "app.log")).writer();

function say(message: string): void {
  const line = `${new Date().toISOString().slice(11, 19)} ${message}`;
  console.log(line);
  runLog.write(`${line}\n`);
}

/** Runs a command to its end; throws with its output when it fails. */
async function run(command: string[], options: { env?: Record<string, string>; quiet?: boolean } = {}): Promise<string> {
  const child = Bun.spawn(command, { env: { ...process.env, ...options.env }, stdout: "pipe", stderr: "pipe" });
  const [stdout, stderr, code] = await Promise.all([
    new Response(child.stdout).text(),
    new Response(child.stderr).text(),
    child.exited,
  ]);
  if (code !== 0) throw new Error(`${command.slice(0, 4).join(" ")} exited ${code}: ${stderr.trim() || stdout.trim()}`);
  if (!options.quiet && stderr.trim()) runLog.write(stderr);
  return stdout;
}

const cleanups: Array<() => Promise<unknown>> = [];
const children: Subprocess[] = [];

function start(command: string[], log: string): Subprocess {
  const child = Bun.spawn(command, { stdout: Bun.file(path.join(shots, log)), stderr: Bun.file(path.join(shots, `${log}.err`)) });
  children.push(child);
  return child;
}

// --- the device ----------------------------------------------------------------------------------------------------

/** What the harness does with one device: start the app with the scenario, photograph, answer, stop. */
interface Device {
  /** How the device reaches this Mac's SSH servers. */
  readonly sshHost: string;
  readonly listen: string;
  /** Starts the app with the scenario; calls [line] with each line the app logs. */
  launch(script: string, line: (text: string) => void): Promise<void>;
  /** Photographs the screen into [file]; absent when the scenario takes its own pictures (shell.snapshot). */
  readonly photograph?: (file: string) => Promise<void>;
  /** Tells the scenario a picture is taken. */
  readonly answer?: (file: string) => Promise<void>;
  /** Where the scenario writes its own pictures. */
  readonly snapshots?: string;
}

/** Follows a growing file and calls [line] with each new line until [stop] says so. */
async function follow(file: string, line: (text: string) => void, stop: () => boolean): Promise<void> {
  let offset = 0;
  let partial = "";
  while (!stop()) {
    const blob = Bun.file(file);
    if ((await blob.exists()) && blob.size > offset) {
      const text = await blob.slice(offset).text();
      offset = blob.size;
      const lines = (partial + text).split("\n");
      partial = lines.pop() ?? "";
      for (const each of lines) line(each);
    }
    await Bun.sleep(200);
  }
}

let finished = false;

async function iosDevice(): Promise<Device> {
  const udid = (
    await run(["xcrun", "simctl", "create", `ompanion-store-${shotClass}`, simulators[shotClass]!, runtime])
  ).trim();
  cleanups.push(() => run(["xcrun", "simctl", "delete", udid]).catch((error) => say(String(error))));
  cleanups.push(() => run(["xcrun", "simctl", "shutdown", udid]).catch(() => undefined));
  say(`simulator ${udid} (${simulators[shotClass]})`);
  await run(["xcrun", "simctl", "boot", udid]);
  await run(["xcrun", "simctl", "bootstatus", udid, "-b"], { quiet: true });
  await run(["xcrun", "simctl", "ui", udid, "appearance", "dark"]);
  // The store's status bar: 9:41, full battery and signal.
  await run([
    "xcrun", "simctl", "status_bar", udid, "override", "--time", "9:41", "--batteryState", "charged",
    "--batteryLevel", "100", "--wifiBars", "3", "--cellularBars", "4",
  ]);
  await run(["xcrun", "simctl", "install", udid, app]);
  const log = path.join(shots, "app-core.log");
  return {
    sshHost: "127.0.0.1",
    listen: "127.0.0.1",
    async launch(script, line) {
      await run(["xcrun", "simctl", "launch", udid, id], {
        env: { SIMCTL_CHILD_OMPCORE_PAGE_SCRIPT: script, SIMCTL_CHILD_OMPCORE_LOG: log },
      });
      void follow(log, line, () => finished);
    },
    photograph: (file) => run(["xcrun", "simctl", "io", udid, "screenshot", file], { quiet: true }).then(() => undefined),
    answer: (file) => Bun.write(file, "").then(() => undefined),
  };
}

async function macosDevice(): Promise<Device> {
  const log = path.join(shots, "app-core.log");
  return {
    sshHost: "127.0.0.1",
    listen: "127.0.0.1",
    snapshots: shots,
    async launch(script, line) {
      // Through LaunchServices, as a user's launch (shells/apple/smoke.sh); the snapshot setting turns shell.snapshot on.
      const opened = Bun.spawn([
        "open", "-n", "-W", "-F", "--env", `OMPCORE_PAGE_SCRIPT=${script}`, "--env", `OMPCORE_LOG=${log}`,
        "--env", `OMPCORE_SNAPSHOT=${path.join(shots, "exit.png")}`, app,
      ]);
      children.push(opened);
      cleanups.push(() => run(["pkill", "-f", `${app}/Contents/MacOS/`]).catch(() => undefined));
      void follow(log, line, () => finished);
    },
  };
}

async function androidDevice(): Promise<Device> {
  const serial = process.env.ANDROID_SERIAL;
  if (!serial) throw new Error("no $ANDROID_SERIAL: run play-phone under a devpool lease of a phone");
  const adb = (...args: string[]) => run(["ssh", air, `${adbPath} -s ${serial} ${args.join(" ")}`], { quiet: true });
  if ((await adb("shell", "pm", "list", "packages", id)).includes(`package:${id}`)) {
    throw new Error(`${id} is already installed on ${serial}; nothing was run`);
  }
  // The phone is shared: every setting changed here goes back as it was.
  const before = {
    night: (await adb("shell", "cmd", "uimode", "night")).includes("yes") ? "yes" : "no",
    timeout: (await adb("shell", "settings", "get", "system", "screen_off_timeout")).trim(),
    stayOn: (await adb("shell", "settings", "get", "global", "stay_on_while_plugged_in")).trim(),
    demo: (await adb("shell", "settings", "get", "global", "sysui_demo_allowed")).trim(),
  };
  cleanups.push(async () => {
    await adb("shell", "am", "broadcast", "-a", "com.android.systemui.demo", "-e", "command", "exit").catch(() => undefined);
    await adb("shell", "cmd", "uimode", "night", before.night).catch(() => undefined);
    await adb("shell", "settings", "put", "system", "screen_off_timeout", before.timeout).catch(() => undefined);
    await adb("shell", "settings", "put", "global", "stay_on_while_plugged_in", before.stayOn).catch(() => undefined);
    if (before.demo === "null") await adb("shell", "settings", "delete", "global", "sysui_demo_allowed").catch(() => undefined);
    else await adb("shell", "settings", "put", "global", "sysui_demo_allowed", before.demo).catch(() => undefined);
    await adb("uninstall", id).catch((error) => say(String(error)));
    say(`restored ${serial}: night mode ${before.night}, screen timeout ${before.timeout}, demo mode off, ${id} removed`);
  });
  const remote = `/tmp/ompanion-store-${serial}.apk`;
  await run(["scp", "-q", app, `${air}:${remote}`]);
  cleanups.push(() => run(["ssh", air, `rm -f ${remote}`]).catch(() => undefined));
  await adb("install", "-r", remote);
  await adb("shell", "input", "keyevent", "KEYCODE_WAKEUP");
  await adb("shell", "wm", "dismiss-keyguard");
  await adb("shell", "settings", "put", "system", "screen_off_timeout", "1800000");
  await adb("shell", "settings", "put", "global", "stay_on_while_plugged_in", "7");
  await adb("shell", "cmd", "uimode", "night", "yes");
  // System UI demo mode: 9:41, a full battery and signal, no notifications.
  await adb("shell", "settings", "put", "global", "sysui_demo_allowed", "1");
  for (const demo of [
    "command enter", "command clock -e hhmm 0941", "command battery -e level 100 -e plugged false",
    "command network -e wifi show -e level 4", "command network -e mobile show -e datatype none -e level 4",
    "command notifications -e visible false",
  ]) {
    await adb("shell", "am", "broadcast", "-a", "com.android.systemui.demo", "-e", demo);
  }
  // The LAN address of the interface the default route uses, which the phone reaches over Wi-Fi.
  const route = await run(["route", "-n", "get", "default"]);
  const studioInterface = /interface: (\S+)/.exec(route)?.[1];
  if (studioInterface === undefined) throw new Error(`no default route interface in: ${route}`);
  const studioAddress = (await run(["ipconfig", "getifaddr", studioInterface])).trim();
  return {
    sshHost: studioAddress,
    listen: "0.0.0.0",
    async launch(script, line) {
      await adb("logcat", "-c");
      const logcat = Bun.spawn(["ssh", air, `${adbPath} -s ${serial} logcat -v raw -s GoLog`], { stdout: "pipe", stderr: "ignore" });
      children.push(logcat);
      void (async () => {
        let partial = "";
        for await (const chunk of logcat.stdout) {
          const lines = (partial + new TextDecoder().decode(chunk)).split("\n");
          partial = lines.pop() ?? "";
          for (const each of lines) line(each.replace(/\r$/, ""));
        }
      })();
      await adb("shell", "am", "start", "-W", "-n", `${id}/.MainActivity`);
      const pid = (await adb("shell", "pidof", id)).trim();
      // The app's WebView (a debug build's) over the DevTools protocol, through a forward on air.local and a tunnel.
      const port = 9300 + (Number(pid) % 500);
      await adb("forward", `tcp:${port}`, `localabstract:webview_devtools_remote_${pid}`);
      cleanups.push(() => adb("forward", "--remove", `tcp:${port}`).catch(() => undefined));
      const tunnel = Bun.spawn(["ssh", "-N", "-o", "ExitOnForwardFailure=yes", "-L", `${port}:127.0.0.1:${port}`, air]);
      children.push(tunnel);
      await injectOverDevTools(`http://127.0.0.1:${port}`, script);
    },
    async photograph(file) {
      const picture = Bun.spawn(["ssh", air, `${adbPath} -s ${serial} exec-out screencap -p`], { stdout: "pipe" });
      await Bun.write(file, new Response(picture.stdout));
      if ((await picture.exited) !== 0) throw new Error("screencap failed");
    },
    answer: (file) => adb("shell", "run-as", id, "touch", file).then(() => undefined),
  };
}

/** Puts [script] at the start of every document of the page DevTools serves at [base], and reloads the page. */
async function injectOverDevTools(base: string, script: string): Promise<void> {
  const deadline = Date.now() + 60_000;
  let target: { webSocketDebuggerUrl: string; url: string } | undefined;
  while (!target) {
    try {
      const pages = (await (await fetch(`${base}/json`)).json()) as Array<{ type: string; url: string; webSocketDebuggerUrl: string }>;
      target = pages.find((page) => page.type === "page");
    } catch {
      if (Date.now() > deadline) throw new Error(`no DevTools page at ${base}`);
      await Bun.sleep(500);
    }
  }
  say(`DevTools page ${target.url}`);
  const socket = new WebSocket(target.webSocketDebuggerUrl.replace(/^ws:\/\/[^/]+/, base.replace(/^http/, "ws")));
  const opened = Promise.withResolvers<void>();
  socket.onopen = () => opened.resolve();
  socket.onerror = () => opened.reject(new Error("the DevTools socket failed"));
  await opened.promise;
  // Replies by id; the protocol's events (no id) are not asked for.
  const replies = new Map<number, () => void>();
  socket.onmessage = (event: MessageEvent<string>) => {
    const message: unknown = JSON.parse(event.data);
    if (typeof message === "object" && message !== null && "id" in message && typeof message.id === "number") {
      replies.get(message.id)?.();
    }
  };
  for (const [index, [method, params]] of [
    ["Page.enable", {}],
    ["Page.addScriptToEvaluateOnNewDocument", { source: script }],
    ["Page.reload", {}],
  ].entries()) {
    const replied = Promise.withResolvers<void>();
    replies.set(index, replied.resolve);
    socket.send(JSON.stringify({ id: index, method, params }));
    await replied.promise;
  }
  cleanups.push(async () => socket.close());
}

// --- the run -------------------------------------------------------------------------------------------------------

async function main(): Promise<void> {
  const device = shotClass === "play-phone" ? await androidDevice() : shotClass === "macos" ? await macosDevice() : await iosDevice();

  const provider = await FakeProvider.start(0);
  cleanups.push(() => provider.stop());
  say(`fake provider on ${provider.port}`);

  if (await fs.exists(demoHome)) {
    // Left behind when an omp run of the last capture wrote into it after its cleanup; a live capture has processes there.
    const users = await run(["pgrep", "-f", `${demoHome}/`]).catch(() => "");
    if (users.trim() !== "") throw new Error(`${demoHome} is in use by another capture (pids ${users.trim().split("\n").join(", ")})`);
    say(`removing ${demoHome}, left behind by an earlier capture`);
    await fs.rm(demoHome, { recursive: true, force: true });
  }
  const hostDir = await fs.mkdtemp(path.join(os.tmpdir(), "ompanion-store-host-"));
  const version = (await Bun.file(path.join(repo, "harness/omp-version")).text()).trim();
  const ports = device.listen === "0.0.0.0" ? await freePorts(8800, 8999) : undefined;
  const host = JSON.parse(
    await run([
      "sh", path.join(import.meta.dir, "demo/host.sh"), "start", hostDir, "--home", demoHome, "--listen", device.listen,
      "--omp", path.join(repo, `.tools/omp/${version}/omp-darwin-arm64`), ...(ports ? ["--ports", ports.join(",")] : []),
    ]),
  ) as { bastion: { port: number; key: string }; target: { port: number; key: string }; clientKey: string };
  cleanups.push(async () => {
    await run(["sh", path.join(import.meta.dir, "demo/host.sh"), "stop", hostDir]).catch(() => undefined);
    for (const name of ["bastion", "target"]) {
      await fs.copyFile(path.join(hostDir, name, "sshd.log"), path.join(shots, `sshd-${name}.log`)).catch(() => undefined);
    }
    await run(["pkill", "-f", `${demoHome}/`]).catch(() => undefined);
    // omp writes its session file as it exits: removing the home before the runs are gone leaves it behind.
    for (let waited = 0; waited < 50; waited++) {
      if ((await run(["pgrep", "-f", `${demoHome}/`]).catch(() => "")).trim() === "") break;
      await Bun.sleep(200);
    }
    await fs.rm(hostDir, { recursive: true, force: true });
    await fs.rm(demoHome, { recursive: true, force: true });
  });
  say(`demo host: bastion ${device.listen}:${host.bastion.port}, target ${device.listen}:${host.target.port}, home ${demoHome}`);
  const user = os.userInfo().username;
  runLog.write(
    await run([
      "sh", path.join(import.meta.dir, "demo/seed-host.sh"), "--host", "127.0.0.1", "--port", String(host.target.port),
      "--user", user, "--key", host.clientKey, "--provider-url", provider.baseUrl,
    ]),
  );
  say("seeded the demo host");

  for (const session of ["hero", "deploy"]) {
    start(["bun", path.join(import.meta.dir, "demo/turns.ts"), "--provider", `http://127.0.0.1:${provider.port}`, "--session", session], `turns-${session}.log`);
  }

  const settings: Settings = {
    shot: shotClass,
    home: demoHome,
    documents: await documents(device.sshHost, user, host),
    secrets: { "ssh-key.store-capture.private": await Bun.file(host.clientKey).text() },
    snapshots: device.snapshots,
  };
  const built = await Bun.build({ entrypoints: [path.join(import.meta.dir, "scenario/main.ts")], target: "browser", format: "iife" });
  if (!built.success) throw new Error(`the scenario did not build: ${built.logs.join("\n")}`);
  const script = `window.ompStoreShots = ${JSON.stringify(settings)};\n${await built.outputs[0]!.text()}`;

  let ackDir = "";
  let pictures = 0;
  const outcome = Promise.withResolvers<string>();
  const queue: string[] = [];
  const handle = async (text: string) => {
    if (text.startsWith("STORE-SHOTS-ACK ")) ackDir = text.slice("STORE-SHOTS-ACK ".length);
    else if (text.startsWith("STORE-LOG ")) say(`app: ${text.slice("STORE-LOG ".length)}`);
    else if (text.startsWith("STORE-SHOTS-DONE")) outcome.resolve("done");
    else if (text.startsWith("STORE-SHOTS-FAILED ")) outcome.resolve(text);
    else if (text.startsWith("STORE-SHOT ")) {
      const shot = JSON.parse(text.slice("STORE-SHOT ".length)) as { name: string };
      const file = path.join(shots, `${shot.name}.png`);
      if (device.photograph) await device.photograph(file);
      await Bun.write(path.join(shots, `${shot.name}.json`), `${JSON.stringify(shot, null, 2)}\n`);
      await device.answer?.(`${ackDir}/${shot.name}.done`);
      pictures++;
      say(`shot ${shot.name}`);
    }
  };
  // Lines arrive in order and each picture is taken before the next line is read.
  let draining = Promise.resolve();
  await device.launch(script, (text) => {
    appLog.write(`${text}\n`);
    if (!text.startsWith("STORE-")) return;
    queue.push(text);
    draining = draining.then(async () => {
      const next = queue.shift();
      if (next !== undefined) await handle(next).catch((error) => outcome.resolve(`STORE-SHOTS-FAILED ${String(error)}`));
    });
  });
  say(`launched the app (${shotClass})`);
  const timeout = setTimeout(() => outcome.resolve("STORE-SHOTS-FAILED no end within 25 minutes"), 25 * 60_000);
  const result = await outcome.promise;
  clearTimeout(timeout);
  await draining;
  finished = true;
  say(`${result === "done" ? "done" : result}: ${pictures} pictures in ${shots}`);
  if (result !== "done") process.exitCode = 1;
}

/** The documents the scenario seeds: the demo key, the two machines, and the host keys they trust. */
async function documents(
  sshHost: string,
  user: string,
  host: { bastion: { port: number; key: string }; target: { port: number; key: string }; clientKey: string },
): Promise<Record<string, unknown[]>> {
  const now = Date.now();
  const publicKey = (await Bun.file(`${host.clientKey}.pub`).text()).trim();
  const keyId = "store-capture";
  const fingerprint = (blob: string) =>
    `SHA256:${new Bun.CryptoHasher("sha256").update(Buffer.from(blob, "base64")).digest("base64").replace(/=+$/, "")}`;
  const endpoint = { user, auth: "key", keyId };
  const trusted = (hostName: string, port: number, blob: string) => ({
    host: hostName, port, keyType: "ssh-ed25519", keyBlob: blob, fingerprint: fingerprint(blob), addedAt: now,
  });
  return {
    keys: [
      { id: keyId, name: "store-capture", type: "ssh-ed25519", publicKey, fingerprint: fingerprint(publicKey.split(" ")[1]!), createdAt: now },
    ],
    machines: [
      { id: "dev-box", name: "dev-box", kind: "ssh", host: sshHost, port: host.target.port, ...endpoint, tailscale: false, createdAt: now, updatedAt: now, jumps: [] },
      // The same host again through the bastion, so the jump chain is in its path; the bastion dials the target locally.
      {
        id: "build-server", name: "build-server", kind: "ssh", host: "127.0.0.1", port: host.target.port, ...endpoint,
        tailscale: false, createdAt: now, updatedAt: now,
        jumps: [{ id: "build-server-jump-0", host: sshHost, port: host.bastion.port, ...endpoint }],
      },
    ],
    known_hosts: [
      trusted(sshHost, host.target.port, host.target.key),
      trusted(sshHost, host.bastion.port, host.bastion.key),
      trusted("127.0.0.1", host.target.port, host.target.key),
    ],
  };
}

/** Two free ports in [from, to] (devpool's range for servers devices reach). */
async function freePorts(from: number, to: number): Promise<[number, number]> {
  const found: number[] = [];
  for (let port = from; port <= to && found.length < 2; port++) {
    try {
      Bun.listen({ hostname: "0.0.0.0", port, socket: { data() {} } }).stop(true);
      found.push(port);
    } catch {
      // In use.
    }
  }
  if (found.length < 2) throw new Error(`no two free ports in ${from}-${to}`);
  return [found[0]!, found[1]!];
}

try {
  await main();
} catch (error) {
  say(`failed: ${error instanceof Error ? error.message : String(error)}`);
  process.exitCode = 1;
} finally {
  finished = true;
  for (const child of children) child.kill();
  for (const cleanup of cleanups.reverse()) await cleanup();
  say("cleaned up");
  await runLog.end();
  await appLog.end();
}
