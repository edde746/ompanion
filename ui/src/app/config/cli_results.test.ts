// Port of test/config/cli_results_test.dart.
import { describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { asJsonObject, FormatException, type JsonObject } from "../../core/rpc/json_fields";
import {
  hourlyRequests,
  parseAccountPolicies,
  parseDiscover,
  parseInstalledSkills,
  parseMarketplaceList,
  pluginListFromJson,
  pluginListIsEmpty,
  skillSearchFromJson,
  type StatsPoint,
  statsFolderOf,
  statsFolderPath,
  statsSnapshotFromJson,
  usageSnapshotFromJson,
  usageSnapshotIsEmpty,
} from "./cli_results";
import { mcpAddRemote, mcpAddStdio, mcpNameProblem, parseMcpServers } from "./mcp_config";
import { cliJson } from "./omp_cli";

// Outputs of `.tools/omp/18.3.1/omp-darwin-arm64` in an isolated HOME against the fake provider: a linked npm plugin,
// a local marketplace with one installed plugin, two print-mode sessions for the stats, and the mcp.json files omp
// wrote for `/mcp add` / `/mcp disable`.
function fixture(name: string): string {
  return readFileSync(join(import.meta.dir, "fixtures", name), "utf8");
}

function json(name: string): JsonObject {
  return asJsonObject(cliJson(fixture(name)), name);
}

describe("omp plugin", () => {
  test("list --json: npm and marketplace plugins", () => {
    const list = pluginListFromJson(json("plugin-list-market.json"));
    expect(list.npm).toHaveLength(1);
    const npm = list.npm[0];
    expect(npm?.name).toBe("omp-plugin-demo");
    expect(npm?.version).toBe("1.2.0");
    expect(npm?.enabled).toBe(true);
    expect(npm?.description).toBe("Demo plugin for omp-app fixtures");
    expect(npm?.enabledFeatures).toBeUndefined();
    expect([...(npm?.features ?? [])]).toEqual([["extra", "An optional extra feature"]]);
    expect(list.marketplace).toHaveLength(1);
    expect(list.marketplace[0]).toMatchObject({
      id: "hello-plugin@demo-market",
      scope: "user",
      version: "0.1.0",
      enabled: true,
    });
  });

  test("a disabled marketplace plugin carries enabled: false in its entry", () => {
    expect(pluginListFromJson(json("plugin-list-market-disabled.json")).marketplace[0]?.enabled).toBe(false);
    expect(pluginListIsEmpty(pluginListFromJson(json("plugin-list-empty.json")))).toBe(true);
  });

  test("marketplace list and discover have text output only", () => {
    expect(parseMarketplaceList(fixture("marketplace-list-one.txt"))).toEqual([
      { name: "demo-market", source: "/tmp/ompcfg-cli.V96t/src/demo-market" },
    ]);
    expect(parseMarketplaceList(fixture("marketplace-list.txt"))).toEqual([]);
    expect(parseDiscover(fixture("plugin-discover-one.txt"))).toEqual([
      { name: "hello-plugin", version: "0.1.0", description: "Says hello" },
    ]);
    expect(parseDiscover(fixture("plugin-discover.txt"))).toEqual([]);
    expect(parseDiscover("Available Plugins:\n\n  @scope/tool@2.0.0\n  bare\n    Bare one\n")).toEqual([
      { name: "@scope/tool", version: "2.0.0" },
      { name: "bare", description: "Bare one" },
    ]);
  });
});

describe("omp stats --json", () => {
  test("skips the sync line omp prints before the document", () => {
    expect(fixture("stats.json")).toStartWith("Synced 4 new entries");
    const stats = statsSnapshotFromJson(json("stats.json"));
    expect(stats.overall.requests).toBe(2);
    expect(stats.overall.inputTokens).toBe(6468);
    expect(stats.overall.avgTokensPerSecond).toBeCloseTo(45.41, 2);
    expect(stats.overall.first).toBe(1790358385569);
    expect(stats.byModel.map((row) => `${row.provider}/${row.model}`)).toEqual(["fake/fake-1", "fake/fake-think"]);
    expect(stats.byFolder.map((row) => row.folder)).toEqual(["-work-demo-project"]);
    expect(stats.byAgentType.map((row) => row.agentType)).toEqual(["main"]);
    expect(stats.timeSeries.map((point) => point.requests)).toEqual([2]);
  });

  test("requests per hour fill the hours without a bucket up to the current hour", () => {
    const hour = (h: number, minute = 0) => Date.UTC(2026, 8, 26, h, minute);
    const point = (time: number, requests: number): StatsPoint => ({ time, requests, errors: 0, tokens: 0, cost: 0 });
    const bars = hourlyRequests([point(hour(9), 3), point(hour(12), 1)], { now: hour(14, 20), hours: 6 });
    expect(bars.map((bar) => bar.hour)).toEqual([8, 9, 10, 11, 12, 13, 14].map((h) => hour(h)));
    expect(bars.map((bar) => bar.requests)).toEqual([0, 3, 0, 0, 1, 0, 0]);
    // A machine clock ahead of this device: its latest bucket ends the axis.
    expect(hourlyRequests([point(hour(16), 2)], { now: hour(14), hours: 2 }).map((bar) => bar.requests)).toEqual([
      0, 0, 2,
    ]);
  });

  test("project folders read as paths; listed sessions resolve the dashes", () => {
    const home = "/Users/me";
    expect(statsFolderPath("-demo-project", { home })).toBe("~/demo-project");
    expect(statsFolderPath("-", { home })).toBe("~");
    expect(statsFolderPath("-tmp-scratch", { home })).toBe("$TMPDIR/scratch");
    expect(statsFolderPath("/opt-work/", { home })).toBe("/opt-work");
    const folder = statsFolderOf("/Users/me/.omp/agent/sessions/-work-demo-project/2026-09-26_abc.jsonl");
    expect(folder).toBe("-work-demo-project");
    expect(statsFolderPath(folder, { home, known: new Map([[folder, "/Users/me/work/demo-project"]]) })).toBe(
      "~/work/demo-project",
    );
    expect(statsFolderOf("/home/u/.omp/agent/sessions/--srv-app--/s.jsonl")).toBe("/srv-app/");
    expect(statsFolderPath("/srv-app/", { home, known: new Map([["/srv-app/", "/srv/app"]]) })).toBe("/srv/app");
  });
});

describe("omp usage --json", () => {
  // usage-mac.json and usage-target.json: omp 18.3.1 without network, in isolated homes whose agent.db holds fake OAuth
  // accounts and cached usage reports. "This Mac": Anthropic and Codex dev@example.com; "target": the same Anthropic
  // account, team@example.com near its 5-hour limit, ops@example.com disabled, Codex ci@example.com without a report,
  // and a policy for team@example.com.
  test("a machine without usage-reporting accounts", () => {
    expect(usageSnapshotIsEmpty(usageSnapshotFromJson(json("usage.json")))).toBe(true);
  });

  test("reports: account, windows, status, amounts, plan and saved resets", () => {
    const mac = usageSnapshotFromJson(json("usage-mac.json"));
    const claude = mac.reports[0];
    expect(claude?.provider).toBe("anthropic");
    expect(claude?.accountLabel).toBe("dev@example.com");
    expect(claude?.identity.accountId).toBe("acc_dev_7f3a");
    expect(claude?.fetchedAt).toBe(1790387219751);
    const weekly = claude?.limits[1];
    expect(weekly?.windowLabel).toBe("7 Day");
    expect(weekly?.durationMs).toBe(7 * 24 * 60 * 60 * 1000);
    expect(weekly?.resetsAt).toBe(1790581659751);
    expect(weekly?.status).toBe("warning");
    expect(weekly?.usedFraction).toBe(0.84);
    expect(claude?.limits[2]?.tier).toBe("fable");
    const extra = claude?.limits.at(-1);
    expect([extra?.unit, extra?.used, extra?.limit, extra?.durationMs]).toEqual(["usd", 18.4, 50, undefined]);
    const codex = mac.reports.at(-1);
    expect(codex?.planType).toBe("plus");
    expect(codex?.resetCredits?.availableCount).toBe(1);
    expect(codex?.resetCredits?.redeemableCount).toBe(0);
    expect(codex?.resetCredits?.credits.map((credit) => credit.expiresAt)).toEqual(["2026-10-05T01:47:39Z"]);
  });

  test("accounts without usage and disabled credentials", () => {
    const target = usageSnapshotFromJson(json("usage-target.json"));
    expect(target.accountsWithoutUsage).toHaveLength(1);
    const ci = target.accountsWithoutUsage[0];
    expect([ci?.provider, ci?.apiKey, ci?.identity.email]).toEqual(["openai-codex", false, "ci@example.com"]);
    expect(target.disabledCredentials).toHaveLength(1);
    const disabled = target.disabledCredentials[0];
    expect(disabled?.identity.email).toBe("ops@example.com");
    expect(disabled?.disabledAt).toBe(1790196442000);
    expect(disabled?.cause).toStartWith('oauth refresh failed: 400 {"error":"invalid_grant"');
  });

  test("account policies from omp config get", () => {
    const policies = parseAccountPolicies(json("config-get-account-policies.json"));
    expect(policies).toHaveLength(1);
    const policy = policies[0];
    expect([policy?.provider, policy?.priority, policy?.reservePct]).toEqual(["anthropic", 5, 15]);
    expect(policy?.selector).toEqual({ email: "team@example.com" });
  });

  test("a limit without a reported fraction: used over limit, a percent reading, else one minus what remains", () => {
    const usage = usageSnapshotFromJson({
      generatedAt: 1790358389081,
      reports: [
        {
          provider: "zai",
          limits: [
            {
              id: "zai:tokens",
              label: "Tokens",
              scope: { accountId: "acct-7" },
              amount: { unit: "tokens", used: 250, limit: 1000 },
            },
            { id: "zai:percent", label: "Session", scope: {}, amount: { unit: "percent", used: 40 } },
            { id: "zai:left", label: "Weekly", scope: {}, amount: { unit: "percent", remainingFraction: 0.25 } },
          ],
        },
      ],
      accountsWithoutUsage: [{ provider: "openrouter", type: "api_key" }],
      disabledCredentials: [],
      capacity: {},
    });
    const report = usage.reports[0];
    // No metadata: the first limit scoped to an account names it.
    expect(report?.accountLabel).toBe("acct-7");
    expect(report?.limits.map((limit) => limit.usedFraction)).toEqual([0.25, 0.4, 0.75]);
    expect(usage.accountsWithoutUsage[0]?.apiKey).toBe(true);
  });
});

describe("omp skill", () => {
  test("search --json", () => {
    const search = skillSearchFromJson(json("skill-search.json"));
    expect(search.total).toBe(0);
    expect(search.perPage).toBe(20);
    expect(search.hits).toEqual([]);
  });

  test("installed skills merge skills.json ranges with skills.lock.json versions", () => {
    // The files omp's skillshare manifest code writes (`{skills: {id: range}}`, lock `{version: 1, skills}`).
    const installed = parseInstalledSkills({
      manifest: '{"skills": {"@alice/pdf-tools": "^1.2.0", "@bob/pending": "latest"}}',
      lock: '{"version": 1, "skills": {"@alice/pdf-tools": {"version": "1.2.3", "integrity": "sha256-x", "resolved": "u"}}}',
      scope: "user",
    });
    expect(installed).toEqual([
      { id: "@alice/pdf-tools", range: "^1.2.0", version: "1.2.3", scope: "user" },
      { id: "@bob/pending", range: "latest", version: undefined, scope: "user" },
    ]);
    expect(parseInstalledSkills({ manifest: undefined, lock: undefined, scope: "project" })).toEqual([]);
  });
});

describe("mcp.json", () => {
  test("user servers first, disabled ones marked, secrets kept off the target", () => {
    const servers = parseMcpServers({ user: fixture("mcp-user.json"), project: fixture("mcp-project.json") });
    expect(servers.map((server) => [server.name, server.scope, server.transport, server.enabled])).toEqual([
      ["everything", "user", "stdio", true],
      ["remote-docs", "user", "http", true],
      ["events", "user", "sse", false],
      ["proj-tool", "project", "stdio", true],
    ]);
    expect(servers[0]?.target).toBe("npx -y @modelcontextprotocol/server-everything");
    // The URL's query carries a key; `/mcp list` prints origin and path only, and so does the app.
    expect(servers[1]?.target).toBe("https://mcp.example.com/v1/mcp");
  });

  test("disabledServers in the user file disable a server of either file; a user name shadows the project one", () => {
    const servers = parseMcpServers({
      user: '{"mcpServers": {"a": {"type": "stdio", "command": "a"}}, "disabledServers": ["b"]}',
      project: '{"mcpServers": {"a": {"command": "other"}, "b": {"command": "b"}}}',
    });
    expect(servers.map((server) => [server.name, server.scope, server.enabled, server.target])).toEqual([
      ["a", "user", true, "a"],
      ["b", "project", false, "b"],
    ]);
    expect(parseMcpServers({ user: undefined, project: undefined })).toEqual([]);
  });

  test("commands follow omp's /mcp add grammar", () => {
    expect(mcpAddStdio("fs", "project", " npx -y server ")).toBe("/mcp add fs --scope project -- npx -y server");
    expect(mcpAddRemote("docs", "user", { url: "https://x.dev/mcp", transport: "http", token: "t0k" })).toBe(
      "/mcp add docs --scope user --url https://x.dev/mcp --transport http --token t0k",
    );
    expect(mcpNameProblem("ok name_1")).toBeUndefined();
    expect(mcpNameProblem("two  spaces")).toBe("invalidCharacters");
    expect(mcpNameProblem("")).toBe("empty");
    expect(mcpNameProblem("x".repeat(101))).toBe("tooLong");
  });
});

test("cliJson fails on output without a JSON document", () => {
  expect(() => cliJson("No plugins available\n")).toThrow(FormatException);
});
