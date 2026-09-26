import { createServer, type IncomingMessage, type Server } from "node:http";
import { NoteStore } from "./notes.ts";

const MAX_BODY = 16 * 1024;

interface Reply {
  status: number;
  body?: unknown;
}

async function readBody(request: IncomingMessage): Promise<string> {
  const chunks: Buffer[] = [];
  let size = 0;
  for await (const chunk of request) {
    const buffer = chunk as Buffer;
    size += buffer.length;
    if (size > MAX_BODY) throw new Error("body too large");
    chunks.push(buffer);
  }
  return Buffer.concat(chunks).toString("utf8");
}

/** One request against the store: 404 for an unknown note, 422 for a note without text. */
async function route(store: NoteStore, request: IncomingMessage): Promise<Reply> {
  const path = new URL(request.url ?? "/", "http://localhost").pathname.split("/");
  const [, section, rawId] = path;
  if (section === "health") return { status: 200, body: { ok: true } };
  if (section !== "notes") return { status: 404, body: { error: "no such route" } };

  const id = rawId === undefined ? null : Number(rawId);
  if (id !== null && !Number.isInteger(id)) return { status: 404, body: { error: "no such note" } };

  switch (request.method) {
    case "GET": {
      if (id === null) return { status: 200, body: store.list() };
      const note = store.find(id);
      return note ? { status: 200, body: note } : { status: 404, body: { error: "no such note" } };
    }
    case "POST": {
      if (id !== null) return { status: 404, body: { error: "no such route" } };
      const parsed: unknown = JSON.parse((await readBody(request)) || "{}");
      const text = typeof parsed === "object" && parsed !== null ? (parsed as { text?: unknown }).text : undefined;
      if (typeof text !== "string" || text.trim() === "") return { status: 422, body: { error: "text is required" } };
      return { status: 201, body: store.add(text.trim()) };
    }
    case "DELETE": {
      if (id === null) return { status: 404, body: { error: "no such route" } };
      return store.remove(id) ? { status: 204 } : { status: 404, body: { error: "no such note" } };
    }
    default:
      return { status: 405, body: { error: "method not allowed" } };
  }
}

export function createApp(store: NoteStore): Server {
  return createServer((request, response) => {
    route(store, request).then(
      ({ status, body }) => {
        response.writeHead(status, { "content-type": "application/json" });
        response.end(body === undefined ? "" : JSON.stringify(body));
      },
      (error: unknown) => {
        const message = error instanceof Error ? error.message : "unknown error";
        response.writeHead(400, { "content-type": "application/json" });
        response.end(JSON.stringify({ error: message }));
      },
    );
  });
}

const port = Number(process.env.PORT ?? 8080);
createApp(new NoteStore()).listen(port, "127.0.0.1", () => {
  console.log(`notes-api listening on http://127.0.0.1:${port}`);
});
