import { createHash } from "node:crypto";
import type { IncomingMessage, ServerResponse } from "node:http";

import { config } from "../config.js";
import { logger } from "../lib/logger.js";
import { putObject } from "../lib/store.js";

/** Reads the whole request body; uploads are small enough to buffer. */
export async function readBody(request: IncomingMessage): Promise<Buffer> {
  const chunks: Buffer[] = [];
  for await (const chunk of request) chunks.push(chunk as Buffer);
  return Buffer.concat(chunks);
}

/** Stores one upload and answers with the key it can be fetched by. */
export async function upload(request: IncomingMessage, response: ServerResponse): Promise<void> {
  const body = await readBody(request);
  if (body.byteLength > config.maxUploadBytes) {
    response.writeHead(413, { "content-type": "application/json" });
    response.end(JSON.stringify({ error: "payload too large" }));
    return;
  }
  const digest = createHash("sha256").update(body).digest("hex");
  const key = await putObject(digest, body);
  logger.info("upload stored", { key, bytes: body.byteLength });
  response.writeHead(201, { "content-type": "application/json" });
  response.end(JSON.stringify({ key, bytes: body.byteLength }));
}

export async function health(response: ServerResponse): Promise<void> {
  response.writeHead(200, { "content-type": "application/json" });
  response.end(JSON.stringify({ ok: true, maxUploadBytes: config.maxUploadBytes }));
}
