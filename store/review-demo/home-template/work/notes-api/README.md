# notes-api

A tiny HTTP service that keeps notes in memory. Nothing in it talks to the network, and it is the sample
project of the ompanion review demo.

## Endpoints

| Method | Path | Body | Answers |
|:---|:---|:---|:---|
| `GET` | `/notes` | — | every note, oldest first |
| `POST` | `/notes` | `{"text":"…"}` | the stored note, `201` |
| `GET` | `/notes/:id` | — | one note, or `404` |
| `DELETE` | `/notes/:id` | — | `204`, or `404` |
| `GET` | `/health` | — | `{"ok":true}` |

## Running it

```sh
bun run src/server.ts     # listens on 127.0.0.1:8080, PORT overrides
```

The service keeps no database: a restart starts from an empty list. Request and response shapes are in
[docs/api.md](docs/api.md), what changed when is in [CHANGELOG.md](CHANGELOG.md).
