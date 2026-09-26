# notes-api HTTP API

All bodies are JSON; `content-type` is always `application/json`.

## Add a note

```http
POST /notes
Content-Type: application/json

{"text":"buy milk"}
```

```http
HTTP/1.1 201 Created

{"id":1,"text":"buy milk","createdAt":"2026-09-20T11:00:00.000Z"}
```

Text is trimmed, an empty or missing `text` answers `422 {"error":"text is required"}`, and a body over
16 KB answers `400 {"error":"body too large"}`.

## List notes

```http
GET /notes
```

```json
[{ "id": 1, "text": "buy milk", "createdAt": "2026-09-20T11:00:00.000Z" }]
```

## One note

`GET /notes/1` answers the note or `404 {"error":"no such note"}`; `DELETE /notes/1` answers `204` or
the same `404`. The ids never repeat, even after a delete.

## Errors

| Status | When |
|:---|:---|
| `400` | an unreadable body |
| `404` | an unknown route or note |
| `405` | a method the route does not answer |
| `422` | a note without text |
