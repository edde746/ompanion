// Port of test/config/login_test.dart (credentialStatus's case is in screens/config/credential_status.test.ts).
import { describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { asJsonObject, type JsonObject } from "../../core/rpc/json_fields";
import type { RpcLoginProvider } from "../../core/rpc/results";
import {
  accountsStateFromJson,
  filterProviderRows,
  providerAccountsStoredOverridden,
  providerRowInUse,
  providerRowPinned,
  providerRows,
  providerRowSignedIn,
  rolesStateFromJson,
  splitSelector,
} from "./accounts";
import { loopbackPorts } from "./login";

function fixture(name: string): JsonObject {
  return asJsonObject(JSON.parse(readFileSync(join(import.meta.dir, "fixtures", name), "utf8")), name);
}

describe("loopbackPorts", () => {
  test("the redirect_uri and omp's launch shortcut name the callback ports", () => {
    const url =
      "https://auth.openai.com/oauth/authorize?response_type=code&client_id=app&redirect_uri=http%3A%2F%2Flocalhost%3A1455%2Fauth%2Fcallback&state=s";
    expect([...loopbackPorts(url, "http://127.0.0.1:1455/launch")]).toEqual([1455]);
    expect([...loopbackPorts(url, "http://localhost:54545/")].sort()).toEqual([1455, 54545]);
  });

  test("remote redirects and portless loopback URLs need no forward", () => {
    expect(
      loopbackPorts("https://claude.ai/oauth?redirect_uri=https%3A%2F%2Fconsole.anthropic.com%2Fcallback", undefined).size,
    ).toBe(0);
    expect(loopbackPorts("https://x.dev/?redirect_uri=http%3A%2F%2Flocalhost%2Fcb", undefined).size).toBe(0);
  });
});

describe("roles", () => {
  test("roles.get of a control process with --model", () => {
    const roles = rolesStateFromJson(fixture("roles-get.json"));
    expect(roles.storage).toBe("global");
    const main = roles.roles[0];
    expect([main?.role, main?.model, main?.provenance]).toEqual(["default", "fake/fake-1", "runtime"]);
    expect(roles.roles.filter((role) => role.kindSection).map((role) => role.role)).toEqual(
      expect.arrayContaining(["image", "web"]),
    );
  });

  test("a thinking suffix is split only when it is a level", () => {
    expect(splitSelector("anthropic/claude-opus:high")).toEqual({ model: "anthropic/claude-opus", thinking: "high" });
    expect(splitSelector("ollama/llama3:8b")).toEqual({ model: "ollama/llama3:8b" });
    expect(splitSelector("fake/fake-1")).toEqual({ model: "fake/fake-1" });
  });
});

test("accounts.list with a models.yml provider", () => {
  const accounts = accountsStateFromJson(fixture("accounts-list.json"));
  expect(accounts.currentProvider).toBe("fake");
  expect(accounts.providers).toHaveLength(1);
  const fake = accounts.providers[0];
  expect(fake?.sourceKind).toBe("config");
  expect(fake?.credentials).toEqual([]);
  expect(fake === undefined ? undefined : providerAccountsStoredOverridden(fake)).toBe(false);
  expect(Object.fromEntries(accounts.logins)).toEqual({ anthropic: "flow", deepseek: "key", ollama: "optionalKey" });
});

describe("provider rows", () => {
  const provider = (id: string, options: { source?: string; credentials?: JsonObject[] } = {}): JsonObject => ({
    provider: id,
    name: id,
    source: options.source === undefined ? null : { kind: options.source, envVar: null, concrete: true },
    credentials: options.credentials ?? [],
  });
  const credential = (type: string, options: { active?: boolean; sticky?: boolean } = {}): JsonObject => ({
    credentialId: 1,
    type,
    label: `${type} #1`,
    active: options.active ?? false,
    sticky: options.sticky ?? false,
    pinnable: false,
  });
  const accounts = accountsStateFromJson({
    currentProvider: "fake",
    providers: [
      provider("fake", { source: "config", credentials: [credential("api_key")] }),
      provider("openrouter", { source: "api_key", credentials: [credential("api_key", { active: true, sticky: true })] }),
      provider("minimax"),
    ],
    logins: [
      { provider: "anthropic", kind: "flow" },
      { provider: "openrouter", kind: "flow" },
      { provider: "ollama", kind: "optional_key" },
      { provider: "deepseek", kind: "key" },
      { provider: "stencil", kind: "flow" },
    ],
  });
  const login: RpcLoginProvider[] = [
    { id: "anthropic", name: "Anthropic (Claude Pro/Max)", available: true, authenticated: false },
    { id: "openrouter", name: "OpenRouter", available: true, authenticated: true },
    { id: "ollama", name: "Ollama (Local OpenAI-compatible)", available: true, authenticated: false },
    { id: "deepseek", name: "DeepSeek", available: true, authenticated: false },
    { id: "stencil", name: "Stencil (invite only)", available: false, authenticated: false },
  ];
  const rows = providerRows({ accounts, login, modelProviders: ["fake", "groq"], hidden: "minimax" });
  const byId = new Map(rows.map((row) => [row.id, row]));
  const row = (id: string) => {
    const found = byId.get(id);
    if (found === undefined) throw new Error(`no row ${id}`);
    return found;
  };

  test("merge login, model and stored providers by id; in use first, then signed in, then by name", () => {
    expect(rows.map((row) => row.id)).toEqual(["fake", "openrouter", "anthropic", "deepseek", "groq", "ollama"]);
    expect(row("openrouter").name).toBe("OpenRouter");
    expect([providerRowInUse(row("openrouter")), providerRowPinned(row("openrouter")), row("openrouter").canSignIn]).toEqual([
      true,
      true,
      true,
    ]);
    expect(row("fake").current).toBe(true);
    const fake = row("fake").accounts;
    expect(fake === undefined ? undefined : providerAccountsStoredOverridden(fake)).toBe(true);
    expect([providerRowSignedIn(row("groq")), row("groq").canSignIn]).toEqual([false, false]);
  });

  test("omp's login kind decides: a pasted-key login is an API key row without a sign-in", () => {
    expect(["anthropic", "deepseek", "ollama", "groq", "fake"].map((id) => [row(id).kind, row(id).canSignIn])).toEqual([
      ["account", true],
      ["apiKey", false],
      ["local", true],
      ["apiKey", false],
      ["apiKey", false],
    ]);
  });

  test("bootstrap: a models.yml provider without a credential gets a row, the placeholder model does not", () => {
    const bootstrap = accountsStateFromJson({
      currentProvider: "minimax",
      providers: [provider("minimax", { source: "runtime" }), provider("fake")],
      logins: [],
    });
    const rows = providerRows({ accounts: bootstrap, login: [], modelProviders: ["minimax"], hidden: "minimax" });
    expect(rows.map((row) => [row.id, row.kind, providerRowSignedIn(row)])).toEqual([["fake", "apiKey", false]]);
  });

  test("search matches every word against name and id, ignoring case", () => {
    expect(filterProviderRows(rows, "")).toHaveLength(rows.length);
    expect(filterProviderRows(rows, "CLAUDE").map((row) => row.id)).toEqual(["anthropic"]);
    expect(filterProviderRows(rows, "local oll").map((row) => row.id)).toEqual(["ollama"]);
    expect(filterProviderRows(rows, "open router").map((row) => row.id)).toEqual(["openrouter"]);
    expect(filterProviderRows(rows, "openai claude")).toEqual([]);
  });
});
