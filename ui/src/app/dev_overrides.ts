// lib/app/dev_overrides.dart's `OMPANION_LOCAL_HOME`, read from the core's environment at boot instead of a
// compile-time define: development runs and the screenshot runner set it for the core they start.
import { call } from "../bridge";
import { asJsonObject } from "../core/rpc/json_fields";

let localHome: string | undefined;

/** Reads the overrides from the core's environment; boot calls it before anything connects. */
export async function loadDevOverrides(): Promise<void> {
  const { env } = asJsonObject(await call<unknown>("core.env", { names: ["OMPANION_LOCAL_HOME"] }), "core.env");
  const value = asJsonObject(env, "core.env env").OMPANION_LOCAL_HOME;
  localHome = typeof value === "string" && value !== "" ? value : undefined;
}

/**
 * `OMPANION_LOCAL_HOME=<dir>`: "this computer" runs every command with `HOME=<dir>`, so development builds and UI
 * tests drive an isolated omp home (`harness/dev-machine.sh`) and never the user's real `~/.omp`.
 */
export function devLocalHome(): string | undefined {
  return localHome;
}

/**
 * The environment of every process "this computer" starts while {@link devLocalHome} is set, else undefined. `PATH`
 * holds only the system directories, and `MachineConnector.searchSystemPaths` keeps the probe to the home directory,
 * so it finds `<home>/.local/bin/omp` and never the user's own omp (e.g. in `/opt/homebrew/bin`); omp's location
 * variables are emptied, which omp reads as unset. Bun reads an empty `XDG_CACHE_HOME` as the relative `./bun`, which
 * left a `bun/` directory in every session's project, so the cache gets its default place in the home instead.
 */
export function devLocalEnvironment(): Record<string, string> | undefined {
  if (localHome === undefined) return undefined;
  return {
    HOME: localHome,
    PATH: "/usr/bin:/bin:/usr/sbin:/sbin",
    PI_CODING_AGENT_DIR: "",
    PI_CONFIG_DIR: "",
    OMP_PROFILE: "",
    PI_PROFILE: "",
    XDG_DATA_HOME: "",
    XDG_STATE_HOME: "",
    XDG_CACHE_HOME: `${localHome}/.cache`,
  };
}
