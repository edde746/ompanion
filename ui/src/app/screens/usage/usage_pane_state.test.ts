// The contract parts of test/screens/usage/usage_pane_test.dart: every machine answers on its own, asking the providers
// again drops omp's cache first, and hide mode masks every identity.
import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { createRoot, flush } from "solid-js";
import type { ScriptResult } from "../../../core/host/scripts";
import { asJsonObject } from "../../../core/rpc/json_fields";
import { deferred } from "../../../deferred";
import { usageSnapshotFromJson } from "../../config/cli_results";
import { OmpCliException } from "../../config/omp_cli";
import { mergeUsage, type MachineUsage } from "./usage_overview";
import { fetchMachineUsage, type Fetch, MachineFetches, maskIdentity } from "./usage_pane_state";

// omp 18.3.1's own output, kept by the Config port.
const fixtures = join(import.meta.dir, "../../config/fixtures");

function fixture(name: string): string {
  return readFileSync(join(fixtures, name), "utf8");
}

/** usage-target.json with an organization on team@example.com's report. */
function targetWithOrgs(): string {
  const json = JSON.parse(fixture("usage-target.json")) as { reports: { metadata: Record<string, unknown> }[] };
  json.reports[1]!.metadata.orgName = "Acme Team";
  return JSON.stringify(json);
}

/** A machine whose `omp` one-shots print what `usage` gives, recording each as `usage --json`, `config get`, …. */
function fakeOmp(usage: () => Promise<string>) {
  const commands: string[] = [];
  const ok = (stdout: string): ScriptResult => ({ stdout, stderr: "", exit: { code: 0 } });
  return {
    commands,
    async omp(args: readonly string[]): Promise<ScriptResult> {
      commands.push(args.slice(0, 2).join(" "));
      if (args[0] === "config") return ok('{"key":"auth.accountPolicies","value":[]}');
      if (args[1] === "invalidate") return ok("Invalidated cached usage reports for all providers.\n");
      return ok(await usage());
    },
  };
}

test("a failing or silent machine leaves the others' answers; retrying one brings its accounts in", async () => {
  const fetches = createRoot(() => new MachineFetches<MachineUsage>());
  const fetch = (id: string, usage: () => Promise<string>) =>
    fetches.fetch(id, () => fetchMachineUsage(fakeOmp(usage), id, { fresh: false }));
  const broken = () =>
    Promise.reject(new OmpCliException("omp usage --json", "Error: database disk image is malformed"));
  void fetch("silent", () => deferred<string>().promise);
  await Promise.all([fetch("mac", async () => fixture("usage-mac.json")), fetch("broken", broken)]);
  flush();
  const kinds = (map: ReadonlyMap<string, Fetch<MachineUsage>>) =>
    Object.fromEntries([...map].map(([id, entry]) => [id, entry.kind]));
  expect(kinds(fetches.fetches())).toEqual({ mac: "Loaded", broken: "Failed", silent: "Loading" });
  const failed = fetches.fetches().get("broken");
  expect(failed?.kind === "Failed" && String(failed.error)).toContain("database disk image is malformed");

  await fetch("broken", async () => targetWithOrgs());
  flush();
  expect(kinds(fetches.fetches())).toEqual({ mac: "Loaded", broken: "Loaded", silent: "Loading" });
  const loaded = [...fetches.fetches().values()].flatMap((f) => (f.kind === "Loaded" ? [f.value] : []));
  const accounts = mergeUsage(loaded).providers.flatMap((provider) => provider.accounts);
  expect(accounts.some((account) => account.report.identity.email === "team@example.com")).toBe(true);
  expect(accounts.some((account) => account.qualifier === "Acme Team")).toBe(true);
});

test("a late answer of an earlier ask is dropped; forgetting a machine drops the one on its way", async () => {
  const fetches = createRoot(() => new MachineFetches<string>());
  const first = deferred<string>();
  const asked = fetches.fetch("m", () => first.promise);
  await fetches.fetch("m", async () => "second");
  first.resolve("first");
  await asked;
  flush();
  expect(fetches.fetches().get("m")).toEqual({ kind: "Loaded", value: "second" });

  const pending = deferred<string>();
  const again = fetches.fetch("m", () => pending.promise);
  fetches.forget("m");
  pending.resolve("late");
  await again;
  flush();
  expect(fetches.has("m")).toBe(false);
});

test("asking the providers again drops omp's cache first; the usage reaches the reminders as soon as it is read", async () => {
  const machine = fakeOmp(async () => fixture("usage-mac.json"));
  const observed: number[] = [];
  const usage = await fetchMachineUsage(machine, "This Mac", {
    fresh: true,
    observe: (snapshot) => observed.push(snapshot.generatedAt),
  });
  expect(machine.commands).toEqual(["usage invalidate", "usage --json", "config get"]);
  const snapshot = usageSnapshotFromJson(asJsonObject(JSON.parse(fixture("usage-mac.json")), "usage-mac.json"));
  expect(observed).toEqual([snapshot.generatedAt]);
  expect(usage.machine).toBe("This Mac");

  const cached = fakeOmp(async () => fixture("usage-mac.json"));
  await fetchMachineUsage(cached, "This Mac", { fresh: false });
  expect(cached.commands).toEqual(["usage --json", "config get"]);
});

test("hide mode masks every identity with one fixed mask", () => {
  expect(maskIdentity("dev@example.com", true)).toBe("••••••••");
  expect(maskIdentity("Acme", true)).toBe(maskIdentity("a-much-longer-organization", true));
  expect(maskIdentity("dev@example.com", false)).toBe("dev@example.com");
  expect(maskIdentity(undefined, true)).toBeUndefined();
});
