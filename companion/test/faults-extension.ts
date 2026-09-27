/**
 * An omp extension that `goal-loop-faults.e2e.test.ts` loads next to the companion (`-e`). Its `session_switch`
 * handler holds every `switch_session` for 1.5 s, as a slow extension or a slow load would, and `/faults` makes
 * submissions fail on demand:
 *
 *   /faults no-key      omp finds no API key, so every prompt's setup throws "No API key found for fake. …"
 *   /faults bail-once   the next goal continuation resolves `false`, as when an abort races omp's prompt setup
 *   /faults off
 */
import type { ExtensionAPI } from "@oh-my-pi/pi-coding-agent";

const FAULTS = ["off", "no-key", "bail-once"] as const;
type Fault = (typeof FAULTS)[number];

function isFault(value: string): value is Fault {
	return (FAULTS as readonly string[]).includes(value);
}

export default function faults(pi: ExtensionAPI): void {
	let fault: Fault = "off";
	let patched = false;
	pi.on("session_switch", async event => {
		if (event.reason === "resume") await Bun.sleep(1500);
	});
	pi.registerCommand("faults", {
		description: "Test only: make submissions fail",
		handler: async args => {
			const next = args.trim();
			if (!isFault(next)) throw new Error(`unknown fault: ${next}`);
			fault = next;
			if (patched) return;
			const session = pi.pi.AgentRegistry.global().get(pi.pi.MAIN_AGENT_ID)?.session;
			if (!session) throw new Error("the main session is not registered");
			patched = true;
			const registry = session.modelRegistry;
			const getApiKey = registry.getApiKey.bind(registry);
			registry.getApiKey = (model, sessionId, options) =>
				fault === "no-key" ? Promise.resolve(undefined) : getApiKey(model, sessionId, options);
			const promptCustomMessage = session.promptCustomMessage.bind(session);
			session.promptCustomMessage = (message, options) => {
				if (fault !== "bail-once" || message.customType !== "goal-continuation") {
					return promptCustomMessage(message, options);
				}
				fault = "off";
				return Promise.resolve(false);
			};
		},
	});
}
