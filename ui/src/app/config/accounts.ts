// Port of lib/config/accounts.dart.
import {
  boolean,
  FormatException,
  integer,
  type JsonObject,
  objects,
  optNumber,
  optObject,
  optString,
  string,
} from "../../core/rpc/json_fields";
import type { RpcLoginProvider } from "../../core/rpc/results";
import { type Provenance, provenanceFromWire } from "./settings_schema";

/**
 * `accounts.list`: one row per provider with stored credentials, the current model's provider and every provider
 * models.yml adds; the kind of each of omp's login providers.
 */
export interface AccountsState {
  readonly currentProvider?: string;
  readonly providers: readonly ProviderAccounts[];
  readonly logins: ReadonlyMap<string, LoginKind>;
}

export function accountsStateFromJson(json: JsonObject): AccountsState {
  const logins = new Map<string, LoginKind>();
  for (const row of objects(json, "logins")) {
    const kind = string(row, "kind");
    const login = ({ key: "key", optional_key: "optionalKey", flow: "flow" } as const)[kind];
    if (login === undefined) throw new FormatException(`unknown login kind "${kind}"`);
    logins.set(string(row, "provider"), login);
  }
  return {
    currentProvider: optString(json, "currentProvider"),
    providers: objects(json, "providers").map(providerAccountsFromJson),
    logins,
  };
}

/**
 * What omp's `/login` asks for a provider. `key`: only an API key, which the row's key field stores the same way.
 * `optionalKey`: an API key that may stay empty, a local server without auth. `flow`: a browser, device-code or
 * multi-prompt sign-in that only omp's `login` runs.
 */
export type LoginKind = "key" | "optionalKey" | "flow";

/** Where a provider's working auth comes from (`source.kind`). */
export type AuthSourceKind = "runtime" | "config" | "oauth" | "apiKey" | "env";

export interface ProviderAccounts {
  readonly provider: string;
  readonly name: string;
  /** Undefined when nothing authenticates the provider. */
  readonly sourceKind?: AuthSourceKind;
  readonly envVar?: string;
  readonly credentials: readonly StoredCredential[];
}

export function providerAccountsFromJson(json: JsonObject): ProviderAccounts {
  const source = optObject(json, "source");
  const wire = source === undefined ? undefined : string(source, "kind");
  const sourceKind =
    wire === undefined
      ? undefined
      : ({ runtime: "runtime", config: "config", oauth: "oauth", api_key: "apiKey", env: "env" } as const)[wire];
  if (wire !== undefined && sourceKind === undefined) throw new FormatException(`unknown auth source kind "${wire}"`);
  return {
    provider: string(json, "provider"),
    name: string(json, "name"),
    sourceKind,
    envVar: source === undefined ? undefined : optString(source, "envVar"),
    credentials: objects(json, "credentials").map(storedCredentialFromJson),
  };
}

/** A models.yml key, an environment variable or a runtime override wins over the stored credentials. */
export function providerAccountsStoredOverridden(accounts: ProviderAccounts): boolean {
  return (
    accounts.credentials.length > 0 &&
    (accounts.sourceKind === "config" || accounts.sourceKind === "env" || accounts.sourceKind === "runtime")
  );
}

/**
 * How a provider authenticates, as the accounts list names it. `account`: a sign-in flow (a browser, a device code or
 * several prompts). `apiKey`: a pasted API key. `local`: a server on the machine or the network whose key is optional.
 */
export type ProviderKind = "account" | "apiKey" | "local";

/**
 * One provider of the accounts list: omp's login providers, the providers of the available models and every provider
 * `accounts.list` names (stored credentials, models.yml), merged by id.
 */
export interface ProviderRow {
  readonly id: string;
  readonly name: string;
  readonly kind: ProviderKind;
  /** omp's `login` runs a flow for this id that the key field does not replace. */
  readonly canSignIn: boolean;
  /** The provider of the current model. */
  readonly current: boolean;
  /** Stored credentials and the working source; undefined when `accounts.list` does not name the provider. */
  readonly accounts?: ProviderAccounts;
  /** `get_login_providers` reports a working credential. */
  readonly authenticated: boolean;
}

export function providerRowCredentials(row: ProviderRow): readonly StoredCredential[] {
  return row.accounts?.credentials ?? [];
}

export function providerRowSignedIn(row: ProviderRow): boolean {
  return row.authenticated || row.accounts?.sourceKind !== undefined || providerRowCredentials(row).length > 0;
}

export function providerRowInUse(row: ProviderRow): boolean {
  return row.current || providerRowCredentials(row).some((credential) => credential.active);
}

export function providerRowPinned(row: ProviderRow): boolean {
  return providerRowCredentials(row).some((credential) => credential.sticky);
}

/**
 * The rows of the accounts list: providers in use first, then signed-in ones, then the rest, each group by name.
 * [hidden] is a placeholder provider (the bootstrap model's) that stays out unless it has stored credentials.
 */
export function providerRows(options: {
  accounts: AccountsState;
  login: readonly RpcLoginProvider[];
  modelProviders: Iterable<string>;
  hidden?: string;
}): ProviderRow[] {
  const { accounts, hidden } = options;
  const stored = new Map(accounts.providers.map((row) => [row.provider, row]));
  const logins = new Map(options.login.filter((provider) => provider.available).map((provider) => [provider.id, provider]));
  const ids = new Set([...logins.keys(), ...stored.keys(), ...options.modelProviders]);
  const rows: ProviderRow[] = [];
  for (const id of ids) {
    const accountsOf = stored.get(id);
    if (id === hidden && (accountsOf?.credentials.length ?? 0) === 0) continue;
    rows.push(row(id, accounts, logins.get(id), accountsOf, hidden));
  }
  const rank = (row: ProviderRow) => (providerRowInUse(row) ? 0 : providerRowSignedIn(row) ? 1 : 2);
  return rows.sort((a, b) => {
    const byRank = rank(a) - rank(b);
    if (byRank !== 0) return byRank;
    const nameA = a.name.toLowerCase();
    const nameB = b.name.toLowerCase();
    return nameA < nameB ? -1 : nameA > nameB ? 1 : 0;
  });
}

function row(
  id: string,
  accounts: AccountsState,
  login: RpcLoginProvider | undefined,
  stored: ProviderAccounts | undefined,
  hidden: string | undefined,
): ProviderRow {
  const loginKind = accounts.logins.get(id);
  let kind: ProviderKind;
  if (login !== undefined) kind = loginKind === "key" ? "apiKey" : loginKind === "optionalKey" ? "local" : "account";
  else if (stored !== undefined && stored.credentials.length > 0 && stored.credentials.every((c) => c.oauth)) {
    kind = "account";
  } else kind = "apiKey";
  return {
    id,
    name: login?.name ?? stored?.name ?? id,
    kind,
    canSignIn: login !== undefined && kind !== "apiKey",
    current: id === accounts.currentProvider && id !== hidden,
    accounts: stored,
    authenticated: login?.authenticated ?? false,
  };
}

/** The rows whose name or id contains every word of [query], case-insensitively. */
export function filterProviderRows(rows: readonly ProviderRow[], query: string): readonly ProviderRow[] {
  const words = query
    .toLowerCase()
    .split(/\s+/)
    .filter((word) => word !== "");
  if (words.length === 0) return rows;
  return rows.filter((row) => {
    const text = `${row.name} ${row.id}`.toLowerCase();
    return words.every((word) => text.includes(word));
  });
}

export interface StoredCredential {
  readonly credentialId: number;
  /** OAuth account; otherwise an API key. */
  readonly oauth: boolean;
  readonly label: string;
  readonly detail?: string;
  /** The account the session uses. */
  readonly active: boolean;
  /** Pinned or affine to the session (`/session pin`). */
  readonly sticky: boolean;
  /** An OAuth account of the current model's provider. */
  readonly pinnable: boolean;
  readonly email?: string;
  readonly orgName?: string;
  /** Epoch ms. */
  readonly expires?: number;
}

export function storedCredentialFromJson(json: JsonObject): StoredCredential {
  const identity = optObject(json, "identity");
  const expires = identity === undefined ? undefined : optNumber(identity, "expires");
  return {
    credentialId: integer(json, "credentialId"),
    oauth: string(json, "type") === "oauth",
    label: string(json, "label"),
    detail: optString(json, "detail"),
    active: boolean(json, "active"),
    sticky: boolean(json, "sticky"),
    pinnable: boolean(json, "pinnable"),
    email: identity === undefined ? undefined : optString(identity, "email"),
    orgName: identity === undefined ? undefined : optString(identity, "orgName"),
    expires: expires !== undefined && expires > 0 ? Math.trunc(expires) : undefined,
  };
}

/** `roles.get` / `roles.set` / `roles.changed`. */
export interface RolesState {
  /** Where omp's own model picker saves assignments: `global` or `project` (`modelRoleStorage`). */
  readonly storage: string;
  readonly roles: readonly ModelRole[];
}

export function rolesStateFromJson(json: JsonObject): RolesState {
  return { storage: string(json, "storage"), roles: objects(json, "roles").map(modelRoleFromJson) };
}

export interface ModelRole {
  readonly role: string;
  readonly name: string;
  readonly tag?: string;
  /** A task-kind role (image, web, speech, …) rather than a chat role. */
  readonly kindSection: boolean;
  /** Effective selector `provider/id[:thinking]`; undefined means auto-selection. */
  readonly model?: string;
  readonly provenance: Provenance;
  readonly global?: string;
  readonly project?: string;
}

export function modelRoleFromJson(json: JsonObject): ModelRole {
  return {
    role: string(json, "role"),
    name: string(json, "name"),
    tag: optString(json, "tag"),
    kindSection: string(json, "section") === "kind",
    model: optString(json, "model"),
    provenance: provenanceFromWire(string(json, "provenance")),
    global: optString(json, "global"),
    project: optString(json, "project"),
  };
}

/** omp's thinking levels, lowest first (`off` means no suffix). */
export const thinkingLevels: readonly string[] = ["off", "minimal", "low", "medium", "high", "xhigh"];

/** A model selector split into its model and optional thinking level: `anthropic/claude:high`. */
export function splitSelector(selector: string): { model: string; thinking?: string } {
  const colon = selector.lastIndexOf(":");
  // Model ids may contain colons themselves (`ollama/llama3:8b`); only a known level is a suffix.
  if (colon > 0 && thinkingLevels.includes(selector.substring(colon + 1))) {
    return { model: selector.substring(0, colon), thinking: selector.substring(colon + 1) };
  }
  return { model: selector };
}
