// Port of the machine cases of packages/omp_core/test/host/scripts_test.dart, run on this computer through the core.
import { afterEach, beforeEach, expect, test } from "bun:test";
import { mkdirSync, readdirSync, statSync, utimesSync, writeFileSync } from "node:fs";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { localLink, useCore } from "../../test/core";
import { HostLinkException, type HostFileStat, type HostFiles, type HostLink } from "../transport/host_link";
import { withTimeout } from "../util/async";
import { concatBytes } from "../util/bytes";
import { acquireDirLock, posixLockFunctions, runPosixScript, shQuote, startPosixScript } from "./scripts";

useCore();

let temp: string;
let link: HostLink;

/** The stamp of a lock whose holder died long ago. */
const longAgo = new Date(2020, 0, 1);

beforeEach(async () => {
  temp = await mkdtemp(join(tmpdir(), "scripts-"));
  link = localLink({ HOME: temp });
});

afterEach(async () => {
  await link.close();
  await rm(temp, { recursive: true });
});

test("shQuote makes any value one sh word", async () => {
  const values = ["plain", "it's", "a  b", "$HOME `id` \\n \\\\", "two\nlines", "é ✓ 🎉", "''", "-n", ""];
  for (const value of values) {
    const result = await runPosixScript(link, `printf %s ${shQuote(value)}`);
    expect(result.stdout).toBe(value);
  }
});

test("a started script reads the stdin that follows it, even when it arrives in the same write", async () => {
  const process = await startPosixScript(link, 'while IFS= read -r l; do echo "got:$l"; done\necho end');
  process.write(new TextEncoder().encode("one\ntwo\n"));
  await process.closeStdin();
  expect(new TextDecoder().decode(concatBytes(await process.stdout.toArray()))).toBe("got:one\ngot:two\nend\n");
});

test("a mkdir lock waits for its holder and breaks a lock left by a dead one", async () => {
  const files = await link.files();
  const lock = `${temp}/x.lock`;
  await acquireDirLock(files, lock, { timeoutMs: 1000, staleMs: 60_000 });
  await expect(acquireDirLock(files, lock, { timeoutMs: 300, staleMs: 60_000 })).rejects.toBeInstanceOf(
    HostLinkException,
  );
  utimesSync(lock, longAgo, longAgo);
  await acquireDirLock(files, lock, { timeoutMs: 1000, staleMs: 60_000 });
  // The stale lock was replaced.
  expect(new Date(statSync(lock).mtimeMs).getFullYear()).toBe(new Date().getFullYear());
  await files.close();
});

test("a mkdir lock's age is taken on the host's clock, whichever way this device's is off", async () => {
  const lock = `${temp}/in.lock`;
  // The host runs ten minutes behind: its fresh lock looks ten minutes old from here, and is still held.
  const behind = skewedFiles(await link.files(), -10 * 60_000);
  await acquireDirLock(behind, lock, { timeoutMs: 1000, staleMs: 60_000 });
  await expect(acquireDirLock(behind, lock, { timeoutMs: 300, staleMs: 60_000 })).rejects.toBeInstanceOf(
    HostLinkException,
  );
  // The host runs ten minutes ahead: a lock its dead holder took two minutes ago looks eight minutes young.
  const ahead = skewedFiles(await link.files(), 10 * 60_000);
  const twoMinutesAgo = Date.now() - 2 * 60_000;
  utimesSync(lock, new Date(twoMinutesAgo), new Date(twoMinutesAgo));
  await acquireDirLock(ahead, lock, { timeoutMs: 1000, staleMs: 60_000 });
  // The stale lock was replaced.
  expect(statSync(lock).mtimeMs).toBeGreaterThan(twoMinutesAgo + 60_000);
  // The clock file is gone.
  expect(readdirSync(temp)).toEqual(["in.lock"]);
  await behind.close();
  await ahead.close();
});

test("the shell lock function breaks a stale lock and fails once its directory is gone", async () => {
  mkdirSync(`${temp}/run/in.lock`, { recursive: true });
  utimesSync(`${temp}/run/in.lock`, longAgo, longAgo);
  const taken = await runPosixScript(
    link,
    `${posixLockFunctions}\nlock ${shQuote(`${temp}/run/in.lock`)} 30 && echo taken`,
  );
  expect(taken.stdout).toBe("taken\n");
  const gone = await runPosixScript(
    link,
    `${posixLockFunctions}\nlock ${shQuote(`${temp}/nope/in.lock`)} 30 || echo failed`,
  );
  expect(gone.stdout).toBe("failed\n");
  expect(gone.stderr).toContain(`no directory ${temp}/nope`);
});

test("the shell lock function fails when mkdir fails for a reason other than a held lock", async () => {
  // A name longer than any file system takes stands in for a full disk or a read-only directory, whatever the user.
  const lock = `${temp}/${"x".repeat(300)}`;
  const result = await withTimeout(
    runPosixScript(link, `${posixLockFunctions}\nlock ${shQuote(lock)} 1 || echo failed`),
    10_000,
  );
  expect(result.stdout).toBe("failed\n");
  // mkdir's own reason.
  expect(result.stderr).toContain("too long");
});

test("the shell lock function gives up on a lock it cannot break after four times the stale age", async () => {
  const lock = `${temp}/in.lock`;
  mkdirSync(lock);
  writeFileSync(`${lock}/stray`, "");
  utimesSync(lock, longAgo, longAgo);
  const started = performance.now();
  const result = await withTimeout(
    runPosixScript(link, `${posixLockFunctions}\nlock ${shQuote(lock)} 1 || echo failed`),
    20_000,
  );
  expect(result.stdout).toBe("failed\n");
  expect(result.stderr).toContain("is still held");
  expect(performance.now() - started).toBeGreaterThanOrEqual(4000);
});

test("the shell lock function stays exclusive when mkdir exits 0 for a directory that already exists", async () => {
  // uutils coreutils before 0.11 does so when another process made the directory at the same moment.
  const bin = `${temp}/bin`;
  mkdirSync(bin);
  writeFileSync(`${bin}/mkdir`, '#!/bin/sh\ncommand -p mkdir "$@" 2>/dev/null\nexit 0\n', { mode: 0o755 });
  const result = await withTimeout(
    runPosixScript(
      link,
      `${posixLockFunctions}\nl=${shQuote(`${temp}/in.lock`)}
lock "$l" 30 && echo first
(PATH=${shQuote(bin)}:$PATH; lock "$l" 30 && echo second && unlock "$l") &
sleep 0.5
echo released
unlock "$l"
wait`,
    ),
    10_000,
  );
  expect(result.stdout).toBe("first\nreleased\nsecond\n");
  expect(readdirSync(temp)).toEqual(["bin"]);
});

/** A machine whose clock is [skewMs] off this device's: every modification time it reports is shifted. */
function skewedFiles(inner: HostFiles, skewMs: number): HostFiles {
  const shift = (stat: HostFileStat): HostFileStat =>
    stat.modifiedMs === undefined ? stat : { ...stat, modifiedMs: stat.modifiedMs + skewMs };
  return {
    stat: async (path, options) => {
      const stat = await inner.stat(path, options);
      return stat === null ? null : shift(stat);
    },
    list: async (path) => (await inner.list(path)).map((entry) => ({ name: entry.name, stat: shift(entry.stat) })),
    read: (path, options) => inner.read(path, options),
    write: (path, bytes, options) => inner.write(path, bytes, options),
    mkdir: (path, options) => inner.mkdir(path, options),
    remove: (path) => inner.remove(path),
    removeDir: (path) => inner.removeDir(path),
    rename: (from, to) => inner.rename(from, to),
    home: () => inner.home(),
    close: () => inner.close(),
  };
}
