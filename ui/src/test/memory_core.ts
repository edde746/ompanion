// An in-memory core for app tests of the store documents, the shell's secrets and its push side: src/bridge.ts talks
// to it as to a dev bridge (src/test/core.ts), so StoreDocument, SecretStore and PushService run as in the app, without
// building or starting the Go core. It answers every request at once, in the order sent, and sends the page events as
// a shell does.
import { afterAll, beforeAll, beforeEach } from "bun:test";
import { call, disconnect } from "../bridge";
import { asJsonObject, isJsonObject, type JsonObject, string } from "../core/rpc/json_fields";

/** The shell's push side (`shell.push*`): what it answers, and the requests the page sent it. */
export class MemoryPush {
  /** `shell.pushStatus`. */
  status: JsonObject = { available: true, reason: null };
  /** What `shell.pushEnable` answers and `shell.pushRegistration` reads; null: no key on this phone. */
  registration: JsonObject | null = null;
  /** The code `shell.pushEnable` fails with (`denied`, `unavailable`, `failed`); undefined: it succeeds. */
  enableError: string | undefined;
  /** What `shell.pushTakeLaunchTap` answers, once. */
  launchTap: JsonObject | null = null;
  /** Every `shell.push*` request, in order. */
  readonly requests: { method: string; params: JsonObject }[] = [];
}

/** A failed request whose error carries a `code`, as the shell's push methods answer. */
class CodedError extends Error {
  constructor(
    message: string,
    readonly code: string,
  ) {
    super(message);
    this.name = "CodedError";
  }
}

export class MemoryCore {
  /** The store documents by name, as the JSON text `store.write` got. */
  readonly documents = new Map<string, string>();
  /** The shell's secrets by key. */
  readonly secrets = new Map<string, string>();
  /** The shell's push side; each test starts with a new one. */
  push = new MemoryPush();
  /** The pages connected to this core, which {@link event} reaches. */
  readonly pages = new Set<{ send(text: string): unknown }>();
  private received = 0;

  /** Sends the pages event `name`, as a shell does. */
  event(name: string, params: unknown): void {
    for (const page of this.pages) page.send(JSON.stringify({ event: name, params }));
  }

  /** The response to one request message. */
  answer(message: string): string {
    this.received++;
    const request = asJsonObject(JSON.parse(message), "request");
    const params = isJsonObject(request.params) ? request.params : {};
    try {
      return JSON.stringify({ id: request.id, result: this.dispatch(string(request, "method"), params) });
    } catch (error) {
      const reason = error instanceof Error ? error.message : String(error);
      const code = error instanceof CodedError ? { code: error.code } : {};
      return JSON.stringify({ id: request.id, error: { message: reason, ...code } });
    }
  }

  /**
   * Resolves once every request sent so far is answered and no request followed from the answers: the app does not
   * await every document write (read markers, pins), and a document writes what queued up meanwhile only after the
   * write in flight landed. A request that follows an answer goes out before the answer to the first echo below is
   * read, so this core has it before the second echo.
   */
  async settled(): Promise<void> {
    for (;;) {
      const before = this.received;
      await call("core.echo");
      await call("core.echo");
      if (this.received === before + 2) return;
    }
  }

  private dispatch(method: string, params: JsonObject): unknown {
    if (method.startsWith("shell.push")) this.push.requests.push({ method, params });
    switch (method) {
      case "core.echo":
        return params;
      case "store.read":
        return { text: this.documents.get(string(params, "name")) ?? null };
      case "store.write":
        this.documents.set(string(params, "name"), string(params, "text"));
        return {};
      case "store.delete":
        this.documents.delete(string(params, "name"));
        return {};
      case "shell.secretGet":
        return { value: this.secrets.get(string(params, "key")) ?? null };
      case "shell.secretSet":
        this.secrets.set(string(params, "key"), string(params, "value"));
        return {};
      case "shell.secretDelete":
        this.secrets.delete(string(params, "key"));
        return {};
      case "shell.pushStatus":
        return this.push.status;
      case "shell.pushEnable":
        if (this.push.enableError !== undefined) throw new CodedError("push was not enabled", this.push.enableError);
        return this.push.registration;
      case "shell.pushRegistration":
        return this.push.registration;
      case "shell.pushDisable":
        this.push.registration = null;
        return {};
      case "shell.pushSetVisible":
      case "shell.pushClear":
        return {};
      case "shell.pushTakeLaunchTap": {
        const tap = this.push.launchTap;
        this.push.launchTap = null;
        return tap;
      }
      default:
        throw new Error(`the memory core has no method "${method}"`);
    }
  }
}

/** Serves the file's tests from a memory core; each test starts with no documents, no secrets and push as it starts. */
export function useMemoryCore(): MemoryCore {
  const core = new MemoryCore();
  const server = Bun.serve({
    hostname: "127.0.0.1",
    port: 0,
    fetch: (request, bridge) => (bridge.upgrade(request) ? undefined : new Response("websocket only", { status: 400 })),
    websocket: {
      open: (socket) => void core.pages.add(socket),
      close: (socket) => void core.pages.delete(socket),
      message: (socket, message) => void socket.send(core.answer(String(message))),
    },
  });
  beforeAll(async () => {
    // A core an earlier file used may still be the bridge's.
    await disconnect();
    process.env.OMPCORE_DEVBRIDGE = `ws://127.0.0.1:${server.port}/bridge`;
  });
  beforeEach(async () => {
    // Writes the previous test did not await land before the documents are emptied, not after.
    await core.settled();
    core.documents.clear();
    core.secrets.clear();
    core.push = new MemoryPush();
  });
  afterAll(async () => {
    // The last test's writes land before the bridge lets go of this core, not rejected by the disconnect.
    await core.settled();
    delete process.env.OMPCORE_DEVBRIDGE;
    await disconnect();
    await server.stop(true);
  });
  return core;
}
