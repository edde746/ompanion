# api-server

Content-addressed upload service for the dashboard. One process, one directory of objects:
`POST /upload` buffers the body, digests it with SHA-256 and writes it under `STORAGE_DIR`.

```sh
npm install
npm test
PORT=8080 STORAGE_DIR=./data npm start
```

## Endpoints

| Route | Method | Answers |
| --- | --- | --- |
| `/health` | GET | `{ ok, maxUploadBytes }` |
| `/upload` | POST | `201 { key, bytes }`, `413` over the limit, `429` when the client is over its rate limit |

## Configuration

| Variable | Default | Meaning |
| --- | --- | --- |
| `PORT` | `8080` | Listen port |
| `UPLOAD_MAX_BYTES` | `33554432` | Largest accepted body |
| `STORAGE_DIR` | `./data` | Where objects are written |
