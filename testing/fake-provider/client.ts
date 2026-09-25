/**
 * Runs the fake provider as a child process and drives its control API from Bun tests.
 *
 *   const fake = await FakeProvider.start();
 *   await createOmpHome(home, fake.port);             // testing/omp-home.ts
 *   await fake.enqueue({ steps: [{ text: "hi" }] });
 *   ... run omp --model fake/fake-1 ...
 *   const sent = await fake.requests();
 *   await fake.stop();
 */
import * as path from "node:path";
import type { Subprocess } from "bun";
import type { RecordedRequest, Turn } from "./server.ts";

export type {
	ErrorTurn,
	FinishReason,
	RecordedRequest,
	Step,
	StreamTurn,
	ToolCallScript,
	Turn,
	Usage,
	WaitTurn,
} from "./server.ts";

const SERVER = path.join(import.meta.dir, "server.ts");

export class FakeProvider {
	readonly port: number;
	/** The `baseUrl` for models.yml: `http://127.0.0.1:<port>/v1`. */
	readonly baseUrl: string;
	readonly #proc: Subprocess<"ignore", "pipe", "inherit">;

	private constructor(proc: Subprocess<"ignore", "pipe", "inherit">, port: number) {
		this.#proc = proc;
		this.port = port;
		this.baseUrl = `http://127.0.0.1:${port}/v1`;
	}

	/** Spawns `server.ts` with the current Bun; port 0 picks a free port. */
	static async start(port = 0): Promise<FakeProvider> {
		const proc = Bun.spawn([process.execPath, SERVER, "--port", String(port)], {
			stdin: "ignore",
			stdout: "pipe",
			stderr: "inherit",
		});
		const reader = proc.stdout.getReader();
		const decoder = new TextDecoder();
		let head = "";
		while (!head.includes("\n")) {
			const { value, done } = await reader.read();
			if (done) throw new Error(`fake provider exited before listening (exit ${await proc.exited})`);
			head += decoder.decode(value, { stream: true });
		}
		reader.releaseLock();
		const match = /^listening (\d+)\n/.exec(head);
		if (!match) {
			proc.kill();
			await proc.exited;
			throw new Error(`fake provider printed ${JSON.stringify(head)} instead of "listening <port>"`);
		}
		return new FakeProvider(proc, Number(match[1]));
	}

	/** Appends turns to the queue; each answers one chat-completions request, in order. */
	async enqueue(turns: Turn | Turn[]): Promise<void> {
		await this.#control("POST", "/control/enqueue", turns);
	}

	/** Every chat-completions request received since start or the last reset. */
	async requests(): Promise<RecordedRequest[]> {
		return (await this.#control("GET", "/control/requests")) as RecordedRequest[];
	}

	/** Clears the queue and the request log. */
	async reset(): Promise<void> {
		await this.#control("POST", "/control/reset");
	}

	/** Turns still queued and requests received so far. */
	async health(): Promise<{ queued: number; requests: number }> {
		return (await this.#control("GET", "/control/health")) as { queued: number; requests: number };
	}

	async stop(): Promise<void> {
		this.#proc.kill();
		await this.#proc.exited;
	}

	async #control(method: "GET" | "POST", route: string, body?: unknown): Promise<unknown> {
		const response = await fetch(`http://127.0.0.1:${this.port}${route}`, {
			method,
			...(body === undefined ? {} : { headers: { "content-type": "application/json" }, body: JSON.stringify(body) }),
		});
		const data: unknown = await response.json();
		if (!response.ok) throw new Error(`fake provider ${method} ${route} failed (${response.status}): ${JSON.stringify(data)}`);
		return data;
	}
}
