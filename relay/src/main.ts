// The relay's HTTP server. Settings come from the environment (README.md); a missing or broken service account
// stops it at startup.

import { parseServiceAccount } from "./oauth.ts";
import { createRelay } from "./relay.ts";

const env = process.env;

const accountFile = env.FCM_SERVICE_ACCOUNT_FILE;
if (!accountFile) throw new Error("FCM_SERVICE_ACCOUNT_FILE is not set");
const account = await parseServiceAccount(await Bun.file(accountFile).text());

const port = Number(env.PORT ?? "8787");
if (!Number.isInteger(port) || port < 0 || port > 65535) throw new Error(`PORT is not a port number: ${env.PORT}`);

if (!["", "0", "1"].includes(env.TRUST_PROXY ?? "")) throw new Error(`TRUST_PROXY must be 0 or 1: ${env.TRUST_PROXY}`);
const trustProxy = env.TRUST_PROXY === "1";

// Only for tests: the smoke test points this at a fake FCM.
const relay = createRelay(account, env.FCM_ORIGIN ?? "https://fcm.googleapis.com");

const server = Bun.serve({
  hostname: env.HOST ?? "127.0.0.1",
  port,
  development: false,
  async fetch(request, server) {
    const started = performance.now();
    const { pathname } = new URL(request.url);
    let status = 500;
    try {
      // Behind a proxy the socket's address is the proxy's. The proxy appends the address it saw to
      // X-Forwarded-For; the entries before it are whatever the client sent.
      const forwarded = trustProxy ? request.headers.get("x-forwarded-for")?.split(",").at(-1)?.trim() : undefined;
      const clientIp = forwarded || server.requestIP(request)?.address;
      if (!clientIp) throw new Error("the request has no client address");
      const response = await relay(request, clientIp);
      status = response.status;
      return response;
    } finally {
      if (pathname !== "/healthz") {
        const route = pathname === "/v1/send" ? pathname : "-";
        console.log(`${request.method} ${route} ${status} ${Math.round(performance.now() - started)}ms`);
      }
    }
  },
  error(error) {
    console.error(error);
    return Response.json({ error: "internal error" }, { status: 500 });
  },
});

console.log(`ompanion push relay for ${account.projectId} on http://${server.hostname}:${server.port}`);
