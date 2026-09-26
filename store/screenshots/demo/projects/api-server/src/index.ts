import { createServer } from "node:http";

import { config } from "./config.js";
import { logger } from "./lib/logger.js";
import { health, upload } from "./routes/upload.js";

const server = createServer((request, response) => {
  const route = `${request.method ?? "GET"} ${request.url ?? "/"}`;
  const handler =
    request.url === "/health" ? health(response) : request.url === "/upload" ? upload(request, response) : undefined;
  if (handler === undefined) {
    response.writeHead(404, { "content-type": "application/json" });
    response.end(JSON.stringify({ error: "not found", route }));
    return;
  }
  handler.catch((error: unknown) => {
    logger.error("request failed", { route, error: error instanceof Error ? error.message : String(error) });
    response.writeHead(500, { "content-type": "application/json" });
    response.end(JSON.stringify({ error: "internal error" }));
  });
});

server.listen(config.port, () => logger.info("listening", { port: config.port, maxUploadBytes: config.maxUploadBytes }));
