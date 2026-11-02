// Port of lib/config/cli_results.dart: what omp's one-shot commands print.
import {
  asJsonObject,
  type JsonObject,
  list,
  number,
  object,
  objects,
  optBool,
  optMilliseconds,
  optNumber,
  optObject,
  optObjects,
  optString,
  optStrings,
  string,
} from "../../core/rpc/json_fields";

// `omp plugin …`

/** `omp plugin list --json`. */
export interface PluginList {
  readonly npm: readonly NpmPlugin[];
  readonly marketplace: readonly MarketplacePlugin[];
}

export function pluginListFromJson(json: JsonObject): PluginList {
  return {
    npm: objects(json, "npm").map(npmPluginFromJson),
    marketplace: objects(json, "marketplace").map(marketplacePluginFromJson),
  };
}

export function pluginListIsEmpty(list: PluginList): boolean {
  return list.npm.length === 0 && list.marketplace.length === 0;
}

/** A plugin installed from npm, a git URL or linked from a local path. */
export interface NpmPlugin {
  readonly name: string;
  readonly version: string;
  readonly path?: string;
  readonly enabled: boolean;
  readonly description?: string;
  /** Undefined: omp's defaults apply. */
  readonly enabledFeatures?: readonly string[];
  /** Optional features the manifest declares, with their descriptions, in manifest order. */
  readonly features: ReadonlyMap<string, string | undefined>;
}

export function npmPluginFromJson(json: JsonObject): NpmPlugin {
  const manifest = optObject(json, "manifest");
  const features = new Map<string, string | undefined>();
  for (const [key, value] of Object.entries(manifest === undefined ? {} : (optObject(manifest, "features") ?? {}))) {
    features.set(key, optString(asJsonObject(value, `feature ${key}`), "description"));
  }
  return {
    name: string(json, "name"),
    version: string(json, "version"),
    path: optString(json, "path"),
    enabled: optBool(json, "enabled") ?? true,
    description: manifest === undefined ? undefined : optString(manifest, "description"),
    enabledFeatures: optStrings(json, "enabledFeatures"),
    features,
  };
}

/** A plugin installed from a marketplace, `name@marketplace`. */
export interface MarketplacePlugin {
  readonly id: string;
  /** `user` or `project`. */
  readonly scope: string;
  readonly version?: string;
  readonly enabled: boolean;
  readonly shadowedBy?: string;
}

export function marketplacePluginFromJson(json: JsonObject): MarketplacePlugin {
  const entry = objects(json, "entries")[0];
  return {
    id: string(json, "id"),
    scope: string(json, "scope"),
    version: entry === undefined ? undefined : optString(entry, "version"),
    // omp writes `enabled: false` into the entry when disabled and leaves it out otherwise.
    enabled: (entry === undefined ? undefined : optBool(entry, "enabled")) ?? true,
    shadowedBy: optString(json, "shadowedBy"),
  };
}

const ansi = /\x1B\[[0-9;?]*[A-Za-z]/g;

/** A marketplace source from `omp plugin marketplace list` (the command has no JSON output). */
export interface MarketplaceSource {
  readonly name: string;
  readonly source: string;
}

/**
 * Parses `omp plugin marketplace list`: `  <name>  <source>` rows under "Configured Marketplaces:"; empty when omp says
 * none are configured.
 */
export function parseMarketplaceList(stdout: string): MarketplaceSource[] {
  const rows: MarketplaceSource[] = [];
  for (const line of stdout.replace(ansi, "").split("\n")) {
    const match = /^ {2}(\S+) {2}(.+)$/.exec(line);
    if (match?.[1] !== undefined && match[2] !== undefined) rows.push({ name: match[1], source: match[2].trim() });
  }
  return rows;
}

/** A plugin a marketplace offers, from `omp plugin discover <marketplace>` (no JSON output either). */
export interface AvailablePlugin {
  readonly name: string;
  readonly version?: string;
  readonly description?: string;
}

/**
 * Parses `omp plugin discover`: `  <name>[@<version>]` rows, each optionally followed by a `    <description>` line.
 */
export function parseDiscover(stdout: string): AvailablePlugin[] {
  const rows: AvailablePlugin[] = [];
  for (const line of stdout.replace(ansi, "").split("\n")) {
    const description = /^ {4}(\S.*)$/.exec(line)?.[1];
    const last = rows.at(-1);
    if (description !== undefined && last !== undefined && last.description === undefined) {
      rows[rows.length - 1] = { ...last, description: description.trim() };
      continue;
    }
    const spec = /^ {2}(@?[^\s@]+(?:@[^\s@]+)?)$/.exec(line)?.[1];
    if (spec === undefined) continue;
    // A scoped npm-style name starts with `@`; the version is after the last `@`.
    const at = spec.lastIndexOf("@");
    rows.push(at > 0 ? { name: spec.substring(0, at), version: spec.substring(at + 1) } : { name: spec });
  }
  return rows;
}

// `omp skill …`

/** `omp skill search <query> --json`. */
export interface SkillSearch {
  readonly total: number;
  readonly page: number;
  readonly perPage: number;
  readonly hits: readonly SkillHit[];
}

export function skillSearchFromJson(json: JsonObject): SkillSearch {
  return {
    total: Math.trunc(number(json, "total")),
    page: Math.trunc(number(json, "page")),
    perPage: Math.trunc(number(json, "perPage")),
    hits: objects(json, "hits").map(skillHitFromJson),
  };
}

export interface SkillHit {
  readonly scope: string;
  readonly name: string;
  readonly version: string;
  readonly description?: string;
  readonly weeklyDownloads: number;
  readonly updatedAt?: number;
  readonly publisher?: string;
  readonly keywords: readonly string[];
  readonly deprecated?: string;
}

export function skillHitFromJson(json: JsonObject): SkillHit {
  const publisher = optObject(json, "publisher");
  return {
    scope: string(json, "scope"),
    name: string(json, "name"),
    version: string(json, "version"),
    description: optString(json, "description"),
    weeklyDownloads: Math.trunc(optNumber(json, "weeklyDownloads") ?? 0),
    updatedAt: time(optNumber(json, "updatedAt")),
    publisher: publisher === undefined ? undefined : optString(publisher, "username"),
    keywords: optStrings(json, "keywords") ?? [],
    deprecated: optString(json, "deprecated"),
  };
}

/** `@scope/name`, what `omp skill install` takes. */
export function skillHitId(hit: SkillHit): string {
  return `@${hit.scope}/${hit.name}`;
}

/** `omp skill info <@scope/name> --json`: the registry package. */
export interface SkillPackage {
  readonly scope: string;
  readonly name: string;
  readonly description?: string;
  readonly license?: string;
  readonly repository?: string;
  readonly homepage?: string;
  readonly keywords: readonly string[];
  readonly latest?: string;
  readonly versions: readonly string[];
  readonly owners: readonly string[];
  readonly weeklyDownloads?: number;
  readonly totalDownloads?: number;
  /** Installing it runs scripts, which `omp skill install` only does with `--yes`. */
  readonly latestHasScripts: boolean;
}

export function skillPackageFromJson(json: JsonObject): SkillPackage {
  const distTags = optObject(json, "distTags");
  const latest = distTags === undefined ? undefined : optString(distTags, "latest");
  const versions = optObject(json, "versions") ?? {};
  const downloads = optObject(json, "downloads");
  const latestEntry = latest === undefined ? undefined : optObject(versions, latest);
  const weekly = downloads === undefined ? undefined : optNumber(downloads, "weekly");
  const total = downloads === undefined ? undefined : optNumber(downloads, "total");
  return {
    scope: string(json, "scope"),
    name: string(json, "name"),
    description: optString(json, "description"),
    license: optString(json, "license"),
    repository: optString(json, "repository"),
    homepage: optString(json, "homepage"),
    keywords: optStrings(json, "keywords") ?? [],
    latest,
    versions: Object.keys(versions),
    owners: (optObjects(json, "owners") ?? []).map((owner) => string(owner, "username")),
    weeklyDownloads: weekly === undefined ? undefined : Math.trunc(weekly),
    totalDownloads: total === undefined ? undefined : Math.trunc(total),
    latestHasScripts: (latestEntry === undefined ? undefined : optBool(latestEntry, "hasScripts")) ?? false,
  };
}

export function skillPackageId(skill: SkillPackage): string {
  return `@${skill.scope}/${skill.name}`;
}

/** A registry skill in `skills.json` (the requested range) and `skills.lock.json` (the installed version). */
export interface InstalledSkill {
  readonly id: string;
  readonly range?: string;
  readonly version?: string;
  readonly scope: string;
}

/**
 * Installed registry skills of one scope, from the text of its `skills.json` and `skills.lock.json` (either undefined
 * when the file does not exist), sorted by id as omp lists them.
 */
export function parseInstalledSkills(options: {
  manifest: string | undefined;
  lock: string | undefined;
  scope: string;
}): InstalledSkill[] {
  const { manifest, lock, scope } = options;
  const ranges = manifest === undefined ? {} : (optObject(asJsonObject(JSON.parse(manifest), "skills.json"), "skills") ?? {});
  const locked = lock === undefined ? {} : (optObject(asJsonObject(JSON.parse(lock), "skills.lock.json"), "skills") ?? {});
  // Plain sort() orders by UTF-16 code units, as Dart's String.compareTo.
  const ids = [...new Set([...Object.keys(ranges), ...Object.keys(locked)])].sort();
  return ids.map((id) => {
    const range = ranges[id];
    const entry = locked[id];
    return {
      id,
      range: typeof range === "string" ? range : undefined,
      version: entry === undefined || entry === null ? undefined : optString(asJsonObject(entry, `lock entry ${id}`), "version"),
      scope,
    };
  });
}

// `omp usage --json`

/**
 * `omp usage --json` (`usage-cli.ts` `runUsageCommand`): the usage report of every stored account whose provider has a
 * usage endpoint, the stored accounts no report covers, and the credentials omp disabled that need a new login. omp
 * drops the providers' raw payloads and never collapses shared limits in this output.
 */
export interface UsageSnapshot {
  readonly generatedAt: number;
  readonly reports: readonly UsageReport[];
  /** Stored credentials no report could be attributed to (`collectUnreportedAccounts`). */
  readonly accountsWithoutUsage: readonly UsageAccount[];
  /** OAuth credentials omp tore down itself, already reduced to the actionable ones (`isActionableDisable`). */
  readonly disabledCredentials: readonly DisabledCredential[];
}

export function usageSnapshotFromJson(json: JsonObject): UsageSnapshot {
  const generatedAt = time(number(json, "generatedAt"));
  if (generatedAt === undefined) throw new RangeError("omp usage: generatedAt is not a time");
  return {
    generatedAt,
    reports: objects(json, "reports").map(usageReportFromJson),
    accountsWithoutUsage: objects(json, "accountsWithoutUsage").map(usageAccountFromJson),
    disabledCredentials: objects(json, "disabledCredentials").map(disabledCredentialFromJson),
  };
}

export function usageSnapshotIsEmpty(snapshot: UsageSnapshot): boolean {
  return (
    snapshot.reports.length === 0 &&
    snapshot.accountsWithoutUsage.length === 0 &&
    snapshot.disabledCredentials.length === 0
  );
}

/** The identity fields omp matches accounts by (`OAuthAccountIdentity`). */
export interface UsageIdentity {
  readonly email?: string;
  readonly accountId?: string;
  readonly projectId?: string;
  readonly orgId?: string;
  readonly orgName?: string;
}

/** One account's usage as its provider reports it. A copy with other limits is `{ ...report, limits }`. */
export interface UsageReport {
  readonly provider: string;
  readonly fetchedAt?: number;
  readonly limits: readonly UsageLimit[];
  /** Provider-wide disclaimers, shown once per provider. */
  readonly notes: readonly string[];
  readonly planType?: string;
  /** Codex: the account has daybreak access. */
  readonly daybreak: boolean;
  readonly resetCredits?: UsageResetCredits;
  /**
   * `reportAccountLabel`: email, account id or project id; undefined when the report names no account, which omp then
   * numbers ("account 2").
   */
  readonly accountLabel?: string;
  readonly identity: UsageIdentity;
}

export function usageReportFromJson(json: JsonObject): UsageReport {
  const metadata = optObject(json, "metadata") ?? {};
  const limits = objects(json, "limits").map(usageLimitFromJson);
  const first = (pick: (limit: UsageLimit) => string | undefined) => limits.map(pick).find((id) => id !== undefined);
  const credits = optObject(json, "resetCredits");
  return {
    provider: string(json, "provider"),
    fetchedAt: time(optNumber(json, "fetchedAt")),
    limits,
    notes: optStrings(json, "notes") ?? [],
    planType: metadataString(metadata, "planType")?.trim(),
    daybreak: metadata.daybreak === true,
    resetCredits: credits === undefined ? undefined : usageResetCreditsFromJson(credits),
    accountLabel:
      metadataString(metadata, "email") ??
      metadataString(metadata, "accountId") ??
      metadataString(metadata, "projectId") ??
      first((limit) => limit.scopeAccountId ?? limit.scopeProjectId),
    // `metadataIdentity`: the metadata's fields, else the first limit scoped to one.
    identity: {
      email: metadataString(metadata, "email"),
      accountId: metadataString(metadata, "accountId") ?? first((limit) => limit.scopeAccountId),
      projectId: metadataString(metadata, "projectId") ?? first((limit) => limit.scopeProjectId),
      orgId: metadataString(metadata, "orgId") ?? first((limit) => limit.scopeOrgId),
      orgName: metadataString(metadata, "orgName"),
    },
  };
}

function metadataString(metadata: JsonObject, key: string): string | undefined {
  const value = metadata[key];
  return typeof value === "string" && value !== "" ? value : undefined;
}

/** `UsageStatus`; a status omp does not name reads as unknown. */
export type UsageStatus = "ok" | "warning" | "exhausted" | "unknown";

const usageStatuses: readonly UsageStatus[] = ["ok", "warning", "exhausted", "unknown"];

export interface UsageLimit {
  readonly id: string;
  readonly label: string;
  readonly tier?: string;
  readonly windowId?: string;
  /** Routing-specific copies of one upstream quota share this; omp shows the first. */
  readonly sharedGroup?: string;
  readonly scopeAccountId?: string;
  readonly scopeProjectId?: string;
  readonly scopeOrgId?: string;
  readonly windowLabel?: string;
  readonly durationMs?: number;
  readonly resetsAt?: number;
  /** The verb before the reset countdown ("tick", "regen"); omp's default is "resets". */
  readonly resetLabel?: string;
  /** What the provider said; `usageLimitStatus` resolves a missing or unknown one from [usedFraction]. */
  readonly status?: UsageStatus;
  /** `tokens`, `requests`, `credits`, `minutes`, `bytes`, `percent`, `usd` or `unknown`. */
  readonly unit: string;
  readonly used?: number;
  readonly limit?: number;
  readonly remaining?: number;
  readonly remainingFraction?: number;
  /** 0 to 1 (more when over the limit); undefined when the provider gives no way to tell. */
  readonly usedFraction?: number;
  readonly notes: readonly string[];
}

export function usageLimitFromJson(json: JsonObject): UsageLimit {
  const scope = object(json, "scope");
  const window = optObject(json, "window");
  const amount = object(json, "amount");
  const status = optString(json, "status");
  return {
    id: string(json, "id"),
    label: string(json, "label"),
    tier: optString(scope, "tier"),
    windowId: optString(scope, "windowId"),
    sharedGroup: optString(scope, "sharedGroup"),
    scopeAccountId: nonEmpty(optString(scope, "accountId")),
    scopeProjectId: nonEmpty(optString(scope, "projectId")),
    scopeOrgId: nonEmpty(optString(scope, "orgId")),
    windowLabel: window === undefined ? undefined : optString(window, "label"),
    durationMs: window === undefined ? undefined : optMilliseconds(window, "durationMs"),
    resetsAt: window === undefined ? undefined : time(optNumber(window, "resetsAt")),
    resetLabel: window === undefined ? undefined : optString(window, "resetLabel"),
    status: usageStatuses.find((name) => name === status),
    unit: optString(amount, "unit") ?? "unknown",
    used: optNumber(amount, "used"),
    limit: optNumber(amount, "limit"),
    remaining: optNumber(amount, "remaining"),
    remainingFraction: optNumber(amount, "remainingFraction"),
    usedFraction: usedFraction(amount),
    notes: optStrings(json, "notes") ?? [],
  };
}

function nonEmpty(value: string | undefined): string | undefined {
  return value === undefined || value === "" ? undefined : value;
}

/**
 * omp's `resolveUsedFraction`: the reported fraction, else used over limit, else a percent reading, else one minus
 * what remains.
 */
function usedFraction(amount: JsonObject): number | undefined {
  const fraction = optNumber(amount, "usedFraction");
  if (fraction !== undefined) return fraction;
  const used = optNumber(amount, "used");
  const limit = optNumber(amount, "limit");
  if (used !== undefined && limit !== undefined && limit > 0) return used / limit;
  if (optString(amount, "unit") === "percent" && used !== undefined) return used / 100;
  const remaining = optNumber(amount, "remainingFraction");
  return remaining === undefined ? undefined : Math.max(0, 1 - remaining);
}

/** Saved rate-limit resets an account can redeem (`UsageResetCredits`). */
export interface UsageResetCredits {
  readonly availableCount: number;
  readonly redeemableCount?: number;
  readonly nextCreditId?: string;
  readonly eligible?: boolean;
  readonly reason?: string;
  /** ISO 8601, as the provider sent it. */
  readonly cooldownUntil?: string;
  readonly credits: readonly UsageResetCredit[];
}

export function usageResetCreditsFromJson(json: JsonObject): UsageResetCredits {
  const redeemable = optNumber(json, "redeemableCount");
  return {
    availableCount: Math.trunc(number(json, "availableCount")),
    redeemableCount: redeemable === undefined ? undefined : Math.trunc(redeemable),
    nextCreditId: optString(json, "nextCreditId"),
    eligible: optBool(json, "eligible"),
    reason: optString(json, "reason"),
    cooldownUntil: optString(json, "cooldownUntil"),
    credits: (optObjects(json, "credits") ?? []).map(usageResetCreditFromJson),
  };
}

export interface UsageResetCredit {
  readonly id?: string;
  readonly remainingCount?: number;
  readonly usable?: boolean;
  /** Limit ids that keep the credit from being redeemed now. */
  readonly blocking: readonly string[];
  /** ISO 8601, as the provider sent it. */
  readonly expiresAt?: string;
  readonly status?: string;
}

export function usageResetCreditFromJson(json: JsonObject): UsageResetCredit {
  return {
    id: optString(json, "id"),
    remainingCount: optNumber(json, "remainingCount"),
    usable: optBool(json, "usable"),
    blocking: optStrings(json, "blocking") ?? [],
    expiresAt: optString(json, "expiresAt"),
    status: optString(json, "status"),
  };
}

/** An account in `accountsWithoutUsage` (`UsageAccountIdentity`). */
export interface UsageAccount {
  readonly provider: string;
  /** An API key rather than an OAuth login. */
  readonly apiKey: boolean;
  readonly enterpriseUrl?: string;
  /** The interactive login that minted the OAuth grant; Anthropic grants expire ~30 days after it. */
  readonly authorizedAt?: number;
  readonly identity: UsageIdentity;
}

export function usageAccountFromJson(json: JsonObject): UsageAccount {
  return {
    provider: string(json, "provider"),
    apiKey: string(json, "type") === "api_key",
    enterpriseUrl: optString(json, "enterpriseUrl"),
    authorizedAt: time(optNumber(json, "authorizedAt")),
    identity: {
      email: optString(json, "email"),
      accountId: optString(json, "accountId"),
      projectId: optString(json, "projectId"),
      orgId: optString(json, "orgId"),
      orgName: optString(json, "orgName"),
    },
  };
}

/** An entry of `disabledCredentials` (`DisabledCredentialSummary`). */
export interface DisabledCredential {
  readonly provider: string;
  /** Verbatim, as omp recorded it when it tore the credential down. */
  readonly cause: string;
  readonly disabledAt?: number;
  readonly identity: UsageIdentity;
}

export function disabledCredentialFromJson(json: JsonObject): DisabledCredential {
  return {
    provider: string(json, "provider"),
    cause: string(json, "cause"),
    disabledAt: time(optNumber(json, "disabledAtMs")),
    identity: {
      email: optString(json, "email"),
      accountId: optString(json, "accountId"),
      orgId: optString(json, "orgId"),
      orgName: optString(json, "orgName"),
    },
  };
}

/** One `auth.accountPolicies` entry: routing priority and protected reserve of the account its selector matches. */
export interface AccountPolicy {
  readonly provider: string;
  readonly priority?: number;
  readonly reservePct?: number;
  /** Every field it sets must equal the account's (`matchesAuthAccountSelector`). */
  readonly selector: UsageIdentity;
}

export function accountPolicyFromJson(json: JsonObject): AccountPolicy {
  const account = object(json, "account");
  return {
    provider: string(json, "provider"),
    priority: optNumber(json, "priority"),
    reservePct: optNumber(json, "reservePct"),
    selector: {
      email: optString(account, "email"),
      accountId: optString(account, "accountId"),
      projectId: optString(account, "projectId"),
      orgId: optString(account, "orgId"),
    },
  };
}

/** `omp config get auth.accountPolicies --json`. */
export function parseAccountPolicies(json: JsonObject): AccountPolicy[] {
  return list(json, "value").map((policy, index) =>
    accountPolicyFromJson(asJsonObject(policy, `auth.accountPolicies[${index}]`)),
  );
}

// `omp stats --json`

export interface StatsModelRow {
  readonly provider: string;
  readonly model: string;
  readonly totals: StatsTotals;
}

/** [folder] is omp's name for the project directory (`-demo-project`); [statsFolderPath] turns it into a path. */
export interface StatsFolderRow {
  readonly folder: string;
  readonly totals: StatsTotals;
}

export interface StatsAgentRow {
  readonly agentType: string;
  readonly requests: number;
  readonly inputTokens: number;
  readonly outputTokens: number;
  readonly cost: number;
}

export interface StatsPoint {
  readonly time: number;
  readonly requests: number;
  readonly errors: number;
  readonly tokens: number;
  readonly cost: number;
}

/** `omp stats --json`: request statistics from every session file of the machine. */
export interface StatsSnapshot {
  readonly overall: StatsTotals;
  readonly byModel: readonly StatsModelRow[];
  readonly byFolder: readonly StatsFolderRow[];
  readonly byAgentType: readonly StatsAgentRow[];
  /** Hours with requests, oldest first; hours without any are absent. */
  readonly timeSeries: readonly StatsPoint[];
}

export function statsSnapshotFromJson(json: JsonObject): StatsSnapshot {
  return {
    overall: statsTotalsFromJson(object(json, "overall")),
    byModel: objects(json, "byModel").map((row) => ({
      provider: string(row, "provider"),
      model: string(row, "model"),
      totals: statsTotalsFromJson(row),
    })),
    byFolder: objects(json, "byFolder").map((row) => ({ folder: string(row, "folder"), totals: statsTotalsFromJson(row) })),
    byAgentType: objects(json, "byAgentType").map((row) => ({
      agentType: string(row, "agentType"),
      requests: Math.trunc(number(row, "totalRequests")),
      inputTokens: Math.trunc(number(row, "totalInputTokens")),
      outputTokens: Math.trunc(number(row, "totalOutputTokens")),
      cost: number(row, "totalCost"),
    })),
    timeSeries: objects(json, "timeSeries").map((point) => {
      const at = time(number(point, "timestamp"));
      if (at === undefined) throw new RangeError("omp stats: a time series point has no timestamp");
      return {
        time: at,
        requests: Math.trunc(number(point, "requests")),
        errors: Math.trunc(number(point, "errors")),
        tokens: Math.trunc(number(point, "tokens")),
        cost: number(point, "cost"),
      };
    }),
  };
}

const hourMs = 60 * 60 * 1000;

/**
 * Requests per hour on a continuous hour axis: the [hours] hours before the latest hour (the hour of [now], or a later
 * bucket from a machine whose clock runs ahead) and that hour itself, zero where omp reports no bucket. omp buckets by
 * whole hours of epoch time (`timestamp / 3600000`), the default `stats` range covers the last 24 hours.
 */
export function hourlyRequests(
  series: readonly StatsPoint[],
  options: { now: number; hours?: number },
): { hour: number; requests: number }[] {
  const hours = options.hours ?? 24;
  const counts = new Map<number, number>();
  for (const point of series) {
    const bucket = Math.floor(point.time / hourMs);
    counts.set(bucket, (counts.get(bucket) ?? 0) + point.requests);
  }
  let last = Math.floor(options.now / hourMs);
  for (const bucket of counts.keys()) last = Math.max(last, bucket);
  const bars: { hour: number; requests: number }[] = [];
  for (let bucket = last - hours; bucket <= last; bucket++) {
    bars.push({ hour: bucket * hourMs, requests: counts.get(bucket) ?? 0 });
  }
  return bars;
}

/**
 * The folder `omp stats` groups a session under, from the session file's path: the session directory's name with
 * omp's `--` turned into `/` (its `byFolder` rows use the same rule).
 */
export function statsFolderOf(sessionFile: string): string {
  const parts = sessionFile.split(/[\\/]/).filter((part) => part !== "");
  const directory = parts.length < 2 ? "" : (parts[parts.length - 2] ?? "");
  return directory.replace(/^--/, "/").replaceAll("--", "/");
}

/**
 * A `byFolder` name of `omp stats` as a path, the home directory shown as `~`. omp names a session directory `-<path>`
 * under the home directory, `-tmp-<path>` under the temp directory and `--<path>--` elsewhere, with every separator
 * turned into `-`, so the name alone cannot tell a separator from a dash. [known] maps the folders of listed sessions
 * ([statsFolderOf]) to their working directories, which are exact; other names keep their dashes.
 */
export function statsFolderPath(
  folder: string,
  options: { home: string; known?: ReadonlyMap<string, string> },
): string {
  const { home } = options;
  const cwd = options.known?.get(folder);
  if (cwd !== undefined) {
    if (cwd === home) return "~";
    for (const separator of ["/", "\\"]) {
      if (cwd.startsWith(`${home}${separator}`)) return `~${separator}${cwd.substring(home.length + 1)}`;
    }
    return cwd;
  }
  if (folder === "-") return "~";
  if (folder === "-tmp") return "$TMPDIR";
  if (folder.startsWith("-tmp-")) return `$TMPDIR/${folder.substring(5)}`;
  if (folder.startsWith("-")) return `~/${folder.substring(1)}`;
  if (folder.length > 1 && folder.startsWith("/") && folder.endsWith("/")) return folder.substring(0, folder.length - 1);
  return folder;
}

export interface StatsTotals {
  readonly requests: number;
  readonly failed: number;
  /** 0 to 1. */
  readonly errorRate: number;
  readonly inputTokens: number;
  readonly outputTokens: number;
  readonly cacheReadTokens: number;
  readonly cacheWriteTokens: number;
  /** 0 to 1. */
  readonly cacheRate: number;
  /** USD. */
  readonly cost: number;
  readonly unpricedRequests: number;
  readonly avgDurationMs?: number;
  readonly avgTtftMs?: number;
  readonly avgTokensPerSecond?: number;
  /** Undefined when there were no requests (omp reports 0). */
  readonly first?: number;
  readonly last?: number;
}

export function statsTotalsFromJson(json: JsonObject): StatsTotals {
  return {
    requests: Math.trunc(number(json, "totalRequests")),
    failed: Math.trunc(number(json, "failedRequests")),
    errorRate: number(json, "errorRate"),
    inputTokens: Math.trunc(number(json, "totalInputTokens")),
    outputTokens: Math.trunc(number(json, "totalOutputTokens")),
    cacheReadTokens: Math.trunc(number(json, "totalCacheReadTokens")),
    cacheWriteTokens: Math.trunc(number(json, "totalCacheWriteTokens")),
    cacheRate: number(json, "cacheRate"),
    cost: number(json, "totalCost"),
    unpricedRequests: Math.trunc(optNumber(json, "unpricedRequests") ?? 0),
    avgDurationMs: optNumber(json, "avgDuration"),
    avgTtftMs: optNumber(json, "avgTtft"),
    avgTokensPerSecond: optNumber(json, "avgTokensPerSecond"),
    first: time(optNumber(json, "firstTimestamp")),
    last: time(optNumber(json, "lastTimestamp")),
  };
}

function time(epochMs: number | undefined): number | undefined {
  return epochMs === undefined || epochMs <= 0 ? undefined : Math.trunc(epochMs);
}
