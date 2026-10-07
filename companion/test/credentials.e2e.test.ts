import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import * as path from "node:path";
import { SqliteAuthCredentialStore } from "@oh-my-pi/pi-ai/auth/sqlite-credential-store";
import { OmpDriver } from "./driver.ts";

setDefaultTimeout(60_000);

let omp: OmpDriver;

beforeAll(async () => {
	omp = await OmpDriver.start();
});

afterAll(async () => {
	await omp?.close();
});

async function models(): Promise<{ provider: string; id: string }[]> {
	const response = await omp.command({ type: "get_available_models" });
	const data = response.data;
	if (!data || typeof data !== "object" || !("models" in data) || !Array.isArray(data.models)) {
		throw new Error(`get_available_models failed: ${JSON.stringify(response).slice(0, 300)}`);
	}
	return data.models;
}

// The fake provider's key is in models.yml, so no request of this session ever makes omp read agent.db again: only
// the companion's poll can bring a credential another process stored (can1357/oh-my-pi#14596).
test("a key another omp process stores reaches the running session's models", async () => {
	expect((await models()).some(model => model.provider === "openai")).toBe(false);

	// What `/login` and the companion's accounts.setKey do from the machine's control process.
	const store = await SqliteAuthCredentialStore.open(path.join(omp.home, ".omp", "agent", "agent.db"));
	try {
		await store.upsertAuthCredential("openai", { type: "api_key", key: "sk-test-not-a-real-key", source: "login" });
	} finally {
		store.close();
	}

	// The poll runs on omp's own clock in another process, which fake timers cannot drive; it emits nothing to await.
	const deadline = Date.now() + 15_000;
	let openai = (await models()).find(model => model.provider === "openai");
	while (!openai && Date.now() < deadline) {
		await Bun.sleep(250);
		openai = (await models()).find(model => model.provider === "openai");
	}
	if (!openai) throw new Error("the running session never listed the provider another process signed in to");
	const switched = await omp.command({ type: "set_model", provider: openai.provider, modelId: openai.id });
	expect(switched.success).toBe(true);
});
