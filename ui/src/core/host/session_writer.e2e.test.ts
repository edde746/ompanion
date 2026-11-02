import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import type { Subprocess } from "bun";
import { chmodSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { localLink, useCore } from "../../test/core";
import type { BridgeLink } from "../transport/bridge_link";
import { hostProbe, type HostProbe } from "./probe";
import { probeSessionWriter } from "./session_writer";

// The probe the app's guard rests on, against this computer (POSIX shell; `/proc` on Linux, `lsof` on macOS).
useCore();

const mac = process.platform === "darwin";

describe("probeSessionWriter", () => {
  let dir: string;
  let link: BridgeLink;
  let probe: HostProbe;
  // Every character the probe script's quoting has to survive.
  let path: string;
  let started: Subprocess[];

  beforeEach(() => {
    dir = mkdtempSync(join(tmpdir(), "ompanion-writer-"));
    link = localLink();
    probe = hostProbe({
      commandShell: "posix",
      os: mac ? "macos" : "linux",
      kernel: mac ? "Darwin" : "Linux",
      arch: "arm64",
      home: dir,
      agentDir: `${dir}/.omp/agent`,
    });
    const sessions = `${dir}/it's $HOME \`id\` \\n dir`;
    mkdirSync(sessions);
    path = `${sessions}/session.jsonl`;
    writeFileSync(path, '{"type":"session"}\n');
    started = [];
  });

  afterEach(async () => {
    for (const child of started) {
      child.kill();
      await child.exited;
    }
    await link.close();
    rmSync(dir, { recursive: true, force: true });
  });

  /** A shell that holds [path] open through descriptor 9 by [redirect] until it is killed. */
  async function holdOpen(redirect: string): Promise<Subprocess> {
    const child = Bun.spawn(["/bin/sh", "-c", `exec 9${redirect}"$0"; echo ready; exec sleep 60`, path], {
      stdout: "pipe",
    });
    started.push(child);
    await firstLine(child.stdout);
    return child;
  }

  test("a process holding the file open for writing is found", async () => {
    const holder = await holdOpen(">>");
    const writer = await probeSessionWriter(link, probe, path);
    expect(writer?.pids).toContain(holder.pid);
    expect(writer?.terminal).toBeUndefined();
  });

  test("a reader is not a writer", async () => {
    await holdOpen("<");
    expect(await probeSessionWriter(link, probe, path)).toBeUndefined();
  });

  test("a terminal breadcrumb of the file with a live omp on that tty is found", async () => {
    const breadcrumbId = await fakeOmpOnPty();
    const breadcrumbs = `${probe.agentDir}/terminal-sessions`;
    mkdirSync(breadcrumbs, { recursive: true });
    writeFileSync(`${breadcrumbs}/${breadcrumbId}`, `${dir}\n${path}\n`);

    const writer = await probeSessionWriter(link, probe, path);
    expect(writer?.terminal).toBe(breadcrumbId);
    // This fake omp never wrote to the file.
    expect(writer?.pids).toEqual([]);
  });

  test("a breadcrumb whose terminal runs nothing is stale, not a writer", async () => {
    const breadcrumbs = `${probe.agentDir}/terminal-sessions`;
    mkdirSync(breadcrumbs, { recursive: true });
    // omp never removes a breadcrumb, so one of a closed terminal must not lock the app out of its own session.
    writeFileSync(`${breadcrumbs}/ttys999`, `${dir}\n${path}\n`);
    writeFileSync(`${breadcrumbs}/tmux-%7`, `${dir}\n${path}\n`);

    expect(await probeSessionWriter(link, probe, path)).toBeUndefined();
  });

  /**
   * Starts a process whose command is an `omp` on a pty, so the probe's tty mapping has something to find: `script`
   * gives the child a terminal, and the child is a shell script named `omp` that prints its terminal. Returns the
   * terminal's breadcrumb id.
   */
  async function fakeOmpOnPty(): Promise<string> {
    const bin = `${dir}/bin`;
    mkdirSync(bin, { recursive: true });
    const omp = `${bin}/omp`;
    writeFileSync(omp, '#!/bin/sh\necho "tty=$(tty)="\nsleep 120\n');
    chmodSync(omp, 0o755);
    // stdin is /dev/null: macOS `script` refuses a socket there (Bun's pipes are sockets), and takes a non-tty file.
    const child = Bun.spawn(["script", ...(mac ? ["-q", "/dev/null", omp] : ["-q", "-c", omp, "/dev/null"])], {
      stdin: "ignore",
      stdout: "pipe",
    });
    started.push(child);
    return (await ttyOf(child.stdout)).replace("pts/", "pts-");
  }
});

/**
 * The terminal the fake omp names on [stdout], between `tty=/dev/` and `=`: macOS's pty echoes the EOF `script` passes
 * on from stdin (`^D`) ahead of it, and util-linux `script` passes it on without its line end.
 */
async function ttyOf(stdout: ReadableStream<Uint8Array>): Promise<string> {
  const decoder = new TextDecoder();
  let text = "";
  for await (const chunk of stdout) {
    text += decoder.decode(chunk, { stream: true });
    const tty = /tty=\/dev\/(\S+?)=/.exec(text)?.[1];
    if (tty !== undefined) return tty;
  }
  throw new Error(`\`script\` gave the fake omp no pty here: ${text}`);
}

/** The first line on [stdout], without its line ending. */
async function firstLine(stdout: ReadableStream<Uint8Array>): Promise<string> {
  const decoder = new TextDecoder();
  let text = "";
  for await (const chunk of stdout) {
    text += decoder.decode(chunk, { stream: true });
    const end = text.indexOf("\n");
    if (end >= 0) return text.slice(0, end).trim();
  }
  throw new Error(`the output ended before a line: ${text}`);
}
