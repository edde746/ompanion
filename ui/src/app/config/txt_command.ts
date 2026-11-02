// Port of lib/config/txt_command.dart.
import type { RpcClient } from "../../core/rpc/rpc_client";
import type { LiveSession } from "../../core/session/live_session";

/** omp does not handle [command] as a builtin in this process, so sending it would start a model turn. */
export class TxtCommandUnavailable extends Error {
  constructor(readonly command: string) {
    super(`omp does not offer /${command} over RPC here`);
    this.name = "TxtCommandUnavailable";
  }
}

const builtins = new WeakMap<RpcClient, Promise<Set<string>>>();
const queues = new WeakMap<LiveSession, Promise<void>>();

/**
 * Sends builtin slash command [line] (`/mcp list`) to [session] and returns the text of its `command_output` frames
 * (ANSI-styled). Commands to one session run one at a time, because the frames name no request: everything between
 * the prompt and its response belongs to it.
 *
 * Only names `get_available_commands` lists as builtins are sent (docs/PLAN.md D14): anything else would reach the
 * model as a turn.
 */
export function runTxtCommand(session: LiveSession, line: string): Promise<string> {
  const run = (queues.get(session) ?? Promise.resolve()).then(() => runLine(session, line));
  // The queue only orders the commands; each failure reaches its own caller through `run`.
  queues.set(
    session,
    run.then(
      () => undefined,
      () => undefined,
    ),
  );
  return run;
}

async function runLine(session: LiveSession, line: string): Promise<string> {
  const name = line.substring(1).split(" ")[0] ?? "";
  const rpc = session.rpc;
  if (!(await builtinsOf(rpc)).has(name)) throw new TxtCommandUnavailable(name);
  const output: string[] = [];
  // Frames are delivered synchronously as their lines arrive, so the output is complete when the response settles.
  const subscription = rpc.frames.listen((frame) => {
    if (frame.kind === "CommandOutputFrame") output.push(frame.text);
  });
  try {
    await rpc.request("prompt", { message: line });
  } finally {
    subscription.cancel();
  }
  return output.join("\n");
}

/**
 * Builtin command names and aliases of [rpc]'s process, fetched once per connection; a failed fetch is retried on the
 * next command.
 */
function builtinsOf(rpc: RpcClient): Promise<Set<string>> {
  const cached = builtins.get(rpc);
  if (cached !== undefined) return cached;
  const listing = rpc.getAvailableCommands().then((commands) => {
    const names = new Set<string>();
    for (const command of commands) {
      if (command.source !== "builtin") continue;
      names.add(command.name);
      for (const alias of command.aliases) names.add(alias);
    }
    return names;
  });
  builtins.set(rpc, listing);
  listing.catch(() => {
    if (builtins.get(rpc) === listing) builtins.delete(rpc);
  });
  return listing;
}
