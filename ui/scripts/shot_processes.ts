// What a shots run leaves running. The core launches omp as detached runs, which outlive it as they would on a real
// machine: each run's wrapper (`<HOME>/.ompanion/run/<id>/run.sh`) leads a process group with the feeder, omp and
// omp's MCP servers. A run's temporary HOME goes at its end, so they must go first.
import * as fs from "node:fs/promises";

interface Listed {
  readonly pid: number;
  readonly pgid: number;
  readonly command: string;
}

function processes(): Listed[] {
  const listed = Bun.spawnSync(["ps", "-A", "-o", "pid=,pgid=,command="]);
  if (listed.exitCode !== 0) throw new Error(`ps exited ${listed.exitCode}: ${listed.stderr.toString()}`);
  return listed.stdout
    .toString()
    .split("\n")
    .flatMap((line) => {
      const match = /^\s*(\d+)\s+(\d+)\s(.*)$/.exec(line);
      return match ? [{ pid: Number(match[1]), pgid: Number(match[2]), command: match[3]! }] : [];
    });
}

function naming(dir: string): Listed[] {
  return processes().filter((listed) => listed.pid !== process.pid && listed.command.includes(`${dir}/`));
}

function signal(pid: number, name: NodeJS.Signals): void {
  try {
    process.kill(pid, name);
  } catch (error) {
    // It ended since it was listed.
    if ((error as NodeJS.ErrnoException).code !== "ESRCH") throw error;
  }
}

/** Waits until [done], at most 10 s. */
async function until(done: () => boolean): Promise<void> {
  for (let waited = 0; waited < 10_000 && !done(); waited += 100) await Bun.sleep(100);
}

/**
 * Ends every process whose command line names [dir], with its process group (an MCP server omp started does not name
 * it), never this process's own group, then removes [dir]. Returns the processes still naming [dir] 10 s later as
 * `<pid> <command>`, which then get SIGKILL: the caller fails the run on any.
 */
export async function endAndRemove(dir: string): Promise<string[]> {
  const own = processes().find((listed) => listed.pid === process.pid)?.pgid;
  const groups = new Set(naming(dir).map((listed) => listed.pgid));
  if (own !== undefined) groups.delete(own);
  for (const group of groups) signal(-group, "SIGTERM");
  // Removed once they are gone: an omp still ending writes its session locks into the HOME again.
  await until(() => !processes().some((listed) => groups.has(listed.pgid)));
  await fs.rm(dir, { recursive: true, force: true });
  await until(() => naming(dir).length === 0);
  const left = naming(dir);
  for (const listed of left) signal(listed.pid, "SIGKILL");
  return left.map((listed) => `${listed.pid} ${listed.command}`);
}
