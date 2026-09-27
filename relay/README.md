# ompanion push relay

The server behind `https://push.ompanion.app/v1/send`. The companion on a machine sends it one encrypted
notification for a phone, and the relay hands it to Firebase Cloud Messaging (FCM), which delivers it through
Google Play services on Android and APNs on iOS. The wire format is `docs/contracts/push.md` (Relay).

The relay exists because sending through FCM takes the Firebase project's service-account key, which cannot
ship inside the companion. It holds that key and nothing else: it sees a Firebase installation ID (FID) and
AES-GCM ciphertext, keeps no state beyond an access token and rate-limit counters in memory, and logs one line
per request (`POST /v1/send 204 12ms`), with no address, FID or body.

A Bun + TypeScript HTTP server, no dependencies. It speaks plain HTTP and expects a reverse proxy in front
of it that terminates TLS for `push.ompanion.app`.

| Request | Answer |
|---|---|
| `POST /v1/send` | `204`, or `400`/`410`/`429`/`502` with `{"error": "…"}` (the contract) |
| `GET /healthz` | `200 ok`, not logged |

Rate limits, in memory and per one-minute window: 60 requests per client address and 30 per FID. An IPv6
client counts as its /64, which it can send from whole. Over either limit, `429` with `Retry-After`. Each limit
tracks at most 10,000 keys; when all of them are in an open window, a new address or FID gets `429` until the
oldest window ends, rather than an open window being dropped. A restart resets them.

## Settings

Environment variables; `docker-compose.yml` sets them for the container.

|Variable|Meaning|
|---|---|
|`FCM_SERVICE_ACCOUNT_FILE`|Path to the service-account JSON. Required; the relay does not start without a valid one.|
|`HOST`|Address to listen on. Default `127.0.0.1`; the image sets `0.0.0.0`.|
|`PORT`|Port to listen on. Default `8787`.|
|`TRUST_PROXY`|`1`: the client's address is the last `X-Forwarded-For` entry, the one the proxy appends. Only behind a proxy that sets it: anyone reaching the relay directly could claim any address. Default off: the socket's address.|
|`FCM_ORIGIN`|For tests only: where FCM is. Default `https://fcm.googleapis.com`.|

The Google token endpoint is the service account's own `token_uri`.

## The service account

One secret: a JSON key for a service account of the Firebase project the app is built with. Least privilege
is a dedicated account that can send messages and nothing else:

1. Google Cloud console → the Firebase project → IAM & Admin → Service accounts → **Create service account**,
   e.g. `ompanion-push`.
2. Grant it the role **Firebase Cloud Messaging API Admin** (`roles/firebasecloudmessaging.admin`).
3. The account → Keys → **Add key** → **Create new key** → JSON. The download is the file.

The Firebase console's own key (Project settings → Service accounts → Generate new private key) works too,
but that account administers the whole project.

The file never goes into the repository or the image: `.dockerignore` lets only `package.json`, `bun.lock` and
`src/` in, and Compose mounts the file at run time.

## Deploy on the VPS

Requirements: Docker Engine with the `docker compose` plugin, the repository checked out, and a reverse proxy
on the same VPS that terminates TLS for `push.ompanion.app`, forwards to `http://127.0.0.1:8787` and sets
`X-Forwarded-For`. DNS: an `A` record (and an `AAAA` record if the VPS has IPv6) for `push.ompanion.app`
pointing at the VPS.

```sh
# The key, readable by uid 1000 (the image's `bun` user) and nobody else. Then delete the download.
sudo install -D -m 0400 -o 1000 -g 1000 ompanion-push-key.json /etc/ompanion-push/service-account.json

cd relay
printf 'FCM_SERVICE_ACCOUNT_FILE=/etc/ompanion-push/service-account.json\n' > .env
docker compose up -d --build
```

`.env` (gitignored) is read by Compose, not by the relay. `RELAY_PORT=…` in it moves the published port.
The container publishes on `127.0.0.1` only, so nothing but the proxy reaches it, and it runs with
`TRUST_PROXY=1`, read-only, without capabilities, restarting unless stopped.

**Check it.**

```sh
docker compose ps                                  # relay: Up (healthy)
curl -i http://127.0.0.1:8787/healthz              # 200 ok
curl -i https://push.ompanion.app/healthz          # 200 ok, through the proxy
curl -i -X POST https://push.ompanion.app/v1/send \
  -H 'content-type: application/json' -d '{}'      # 400 {"error":"missing field \"fid\""}
docker compose logs -f relay                       # one line per request
```

End to end: turn on notifications in the app, connect to a machine, and send its test notification (the
companion's `notify.test`).

**Update.** `git pull && docker compose up -d --build`.

**Rotate the service account.** Create a new key for the same account, replace the file (same path, owner and
mode), run `docker compose up -d --force-recreate` (the relay reads the file only at startup), check a test
notification, then delete the old key in the Google Cloud console.

**Stop.** `docker compose down`.

## Development

```sh
bun install
bun run typecheck
bun test
FCM_SERVICE_ACCOUNT_FILE=/path/to/key.json bun run start
```

The tests drive the real request handler (`createRelay` in `src/relay.ts`) with `fetch` replaced by a fake
Google token endpoint and FCM, and a throwaway RSA key as the service account.
