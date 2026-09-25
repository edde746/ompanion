import type { AuthCredential } from "@oh-my-pi/pi-coding-agent";
import { toLogoutAccounts } from "@oh-my-pi/pi-coding-agent/slash-commands/helpers/logout";
import { getOAuthProviders } from "@oh-my-pi/pi-ai/oauth";
import { expectKeys, optionalInteger, requireString } from "../../args.ts";
import { takeSecretFile } from "../../paths.ts";
import { VerbError, type VerbTable } from "../../protocol.ts";

function requireCredentialId(args: Record<string, unknown>): number {
	const credentialId = optionalInteger(args, "credentialId", 1, Number.MAX_SAFE_INTEGER);
	if (credentialId === undefined) throw new VerbError("bad_request", "credentialId is required");
	return credentialId;
}

/** Account identity only; tokens and keys never leave the host. */
function identity(credential: AuthCredential) {
	if (credential.type !== "oauth") return null;
	return {
		email: credential.email ?? null,
		accountId: credential.accountId ?? null,
		projectId: credential.projectId ?? null,
		enterpriseUrl: credential.enterpriseUrl ?? null,
		orgId: credential.orgId ?? null,
		orgName: credential.orgName ?? null,
		expires: credential.expires,
	};
}

export const accountVerbs: VerbTable = {
	// The rows of the TUI's logout selector (selector-controller.ts:1909-1924) for every provider with
	// stored credentials plus the current model's provider, with the session-pin state of /session pin.
	"accounts.list": async (args, { session }) => {
		expectKeys(args, []);
		const auth = session.modelRegistry.authStorage;
		await auth.credentials.reload();
		const sessionId = session.sessionId;
		const currentProvider = session.model?.provider ?? null;
		const providerIds = new Set(auth.credentials.list().map(row => row.provider));
		if (currentProvider) providerIds.add(currentProvider);
		const names = new Map(getOAuthProviders().map(provider => [provider.id, provider.name]));
		const providers = [...providerIds].sort().map(provider => {
			const rows = auth.credentials.list(provider);
			const source = auth.keys.source(provider);
			const sticky = new Set(
				auth.oauth
					.accounts(provider, sessionId)
					.filter(account => account.active)
					.map(account => account.credentialId),
			);
			const labelled = toLogoutAccounts(provider, rows, {
				activeIdentity: auth.oauth.identity(provider, sessionId),
				activeApiKey: source?.kind === "api_key",
			});
			return {
				provider,
				name: names.get(provider) ?? provider,
				source: source ? { kind: source.kind, envVar: source.envVar ?? null, concrete: source.concrete } : null,
				sourceText: auth.keys.describe(provider, sessionId) ?? null,
				credentials: labelled.map(account => {
					const row = rows.find(candidate => candidate.id === account.credentialId);
					return {
						credentialId: account.credentialId,
						type: account.type,
						label: account.label,
						detail: account.detail,
						active: account.active,
						sticky: sticky.has(account.credentialId),
						pinnable: account.type === "oauth" && provider === currentProvider,
						identity: row ? identity(row.credential) : null,
					};
				}),
			};
		});
		return { sessionId, currentProvider, providers };
	},

	// The TUI's credential logout (selector-controller.ts:1870-1906).
	"accounts.logout": async (args, { session }) => {
		expectKeys(args, ["provider", "credentialId"]);
		const provider = requireString(args, "provider");
		const credentialId = requireCredentialId(args);
		const auth = session.modelRegistry.authStorage;
		await auth.credentials.reload();
		if (!(await auth.credentials.removeById(provider, credentialId))) {
			throw new VerbError("not_found", `no stored credential ${credentialId} for ${provider}`);
		}
		// Provider-scoped online refresh drops models only the removed credential unlocked (#5780).
		await session.modelRegistry.refreshProvider(provider, "online");
		return { provider, credentialId, remainingSource: auth.keys.describe(provider, session.sessionId) ?? null };
	},

	// `/session pin` (builtin-session.ts:111-174): pins an OAuth account of the current model's provider.
	"accounts.pin": async (args, { session }) => {
		expectKeys(args, ["credentialId"]);
		const credentialId = requireCredentialId(args);
		const provider = session.model?.provider;
		if (!provider) throw new VerbError("failed", "select a model before pinning a provider account");
		const streaming = "cannot pin an account while the session is streaming";
		if (session.isStreaming) throw new VerbError("busy", streaming);
		const auth = session.modelRegistry.authStorage;
		// rpc-mode does not await /ompx handlers: commands from other devices run while the credentials reload, so
		// everything is checked after it, and nothing awaits between the checks and the pin.
		await auth.credentials.reload();
		if (session.isStreaming) throw new VerbError("busy", streaming);
		// The stored rows, not `oauth.accounts`, which lists none while a key override applies.
		const stored =
			session.model?.provider === provider &&
			auth.credentials.list(provider).some(row => row.id === credentialId && row.credential.type === "oauth");
		if (!stored) throw new VerbError("not_found", `no stored OAuth account ${credentialId} for ${provider}`);
		const source = auth.keys.source(provider)?.kind;
		if (source === "runtime" || source === "config") {
			throw new VerbError("failed", `${provider} has an --api-key or models.yml key override, which OAuth pins cannot replace`);
		}
		if (!session.pinCurrentProviderOAuthAccount(credentialId)) {
			throw new VerbError("failed", `omp did not pin account ${credentialId} for ${provider}`);
		}
		return { provider, credentialId };
	},

	// RPC `login` refuses secret prompts (rpc-mode.ts:1665-1670), so the app uploads the key as a secret file and
	// the companion stores it the way a successful /login stores a pasted key (pool.ts:145-153). The key never
	// appears in a frame, an error or a log line.
	"accounts.setKey": async (args, { session }) => {
		expectKeys(args, ["provider", "keyFile"]);
		const provider = requireString(args, "provider");
		const key = (await takeSecretFile(requireString(args, "keyFile"))).trim();
		if (!key) throw new VerbError("bad_request", "the key file is empty");
		const stored = await session.modelRegistry.authStorage.credentials.upsert(provider, {
			type: "api_key",
			key,
			source: "login",
		});
		const entry = stored.find(candidate => candidate.credential.type === "api_key" && candidate.credential.key === key);
		if (!entry) throw new VerbError("failed", `the key for ${provider} was not stored`);
		await session.modelRegistry.refreshProvider(provider, "online");
		return { provider, credentialId: entry.id };
	},
};
