import { authProviders } from "@oh-my-pi/pi-catalog/compat/auth";

/** How omp's `/login` for a provider authenticates: a pasted key, a key that may stay empty, or a sign-in flow. */
export type LoginKind = "key" | "optional_key" | "flow";

/**
 * The `/login` providers whose login is only a pasted API key (`login "api-key"` in omp's auth policies), keyed
 * by id. Runs while the companion is bundled (imported `with { type: "macro" }`): omp serves extensions no login
 * kind at runtime, and `@oh-my-pi/pi-catalog`, which holds the policies, is not among the packages it serves them.
 * An empty-fallback key is optional: an empty answer sets up a local server without auth.
 */
export function keyLogins(): Record<string, Exclude<LoginKind, "flow">> {
	const kinds: Record<string, Exclude<LoginKind, "flow">> = {};
	for (const provider of authProviders()) {
		if (provider.login?.kind !== "api-key") continue;
		kinds[provider.id] = provider.login.emptyFallback === undefined ? "key" : "optional_key";
	}
	return kinds;
}
