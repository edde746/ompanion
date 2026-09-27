# push: phone notifications from a machine

How a session on a machine reaches a phone that is not connected: the phone leaves a registration file on the
machine, the companion in every detached run encrypts a notification for it, and the relay hands the ciphertext to
Firebase Cloud Messaging (FCM), which delivers it through Google Play services on Android and APNs on iOS. Code:
`companion/src/notify.ts` (the sender), `relay/` (the relay), `packages/omp_core/lib/src/host/push_registration.dart`
(the registration file), `lib/notifications/push_service.dart` (the app side), and the receivers:
`android/app/src/main/kotlin/com/edde746/ompanion/push/`, `ios/Runner/Push.swift` and `ios/NotificationService/`.

Desktops do not use this path: a running desktop app shows local notifications for the sessions it has open
(`lib/notifications/desktop_notifications.dart`), with the same kinds and triggers as far as the app's view of a
session shows them.

## Why this contract exists

Sending through FCM needs the Firebase project's service-account key, which cannot ship inside the companion: anyone
holding it could push to every ompanion install. The relay holds it and nothing else. Everything the relay, Google
and Apple see of a notification is a Firebase installation ID (FID) and AES-GCM ciphertext; the key is made on the
phone and reaches the machine only over SSH.

## Registration file

`<home>/.ompanion/push/<deviceId>.json` (`%USERPROFILE%\.ompanion\push\` on Windows), one per phone, mode 0600 in a
0700 directory. The app writes it over SFTP (a temporary name, then a rename) every time it connects to the machine
while push is on, and only when the bytes differ; it deletes it when push is turned off. `removeDeadRuns` never
touches this directory.

```json
{
  "v": 1,
  "deviceId": "<32 lowercase hex>",
  "machineId": "<the app's id for this machine>",
  "machineName": "<the app's name for this machine>",
  "platform": "android" | "ios",
  "fid": "<Firebase installation ID, registered for messaging>",
  "key": "<base64 of 32 random bytes>",
  "kinds": ["input", "done", "failed"],
  "relay": "https://push.ompanion.app/v1/send"
}
```

- `deviceId` is the app's device id (`Prefs.deviceId`), the prefix of its RPC ids and callIds. The file name is
  `<deviceId>.json`; a file whose name and `deviceId` differ counts as invalid. The app writes under a temporary
  name that does not end in `.json`, then renames.
- `kinds` lists the notifications the phone wants, in any order, a subset of `input`, `done`, `failed`. The
  companion never sends a kind that is not listed, so the phone never has to discard one (FCM lowers the priority
  of an Android app that receives high-priority messages and shows nothing).
- A file that does not parse or does not match this shape is skipped; the companion warns attached devices once per
  run and file.

## Payload

The plaintext is one JSON object, UTF-8, at most 1,536 bytes:

```json
{
  "v": 1,
  "kind": "input" | "done" | "failed" | "test",
  "machineId": "<from the registration>",
  "runId": "<run directory id>" | null,
  "sessionPath": "<host path of the session file>" | null,
  "title": "<session title>",
  "subtitle": "<machineName> · <Needs input | Done | Failed | Test>",
  "body": "<text>",
  "ts": <milliseconds since the epoch, the machine's clock>
}
```

- `title` is the session's name, else the first line of its first user message, else the last component of its
  working directory; at most 120 characters. `test`: `ompanion`.
- `body` is at most 240 characters, cut at a character boundary with `…`:
  - `input`: the question of an `ask` (the first question when there are several), `Allow <tool>?` for a tool
    approval, the title of any other dialog (`select`, `confirm`, `input`, `editor`).
  - `done`: `Goal complete: <objective>` after a goal completes, the loop's notice when a loop ends, else the first
    non-empty line of the last assistant message's text, else `Finished`.
  - `failed`: the error message of the assistant message that ended the run with `stopReason: "error"`, or of the
    last retry.
  - `test`: `Notifications from <machineName> work.`
- `runId` and `sessionPath` are `null` only for `test`.

Encryption: AES-256-GCM with the registration's `key`, a fresh random 12-byte nonce per message, and the UTF-8 bytes
of `deviceId` as additional authenticated data. `ciphertext` is the encrypted bytes followed by the 16-byte tag.
Both travel as standard base64 with padding.

Test vector (every implementation decrypts it):

| Field | Value |
|---|---|
| key | `AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8=` |
| nonce | `oKGio6Slpqeoqaqr` |
| deviceId | `00112233445566778899aabbccddeeff` |
| ciphertext | `nToKD3/6Lp0JDOm3JUDiuh/CPDK+lS8N/2ZP6BriESPoVCrOjQ5xTyryTawrQKGLdjlqahG1aQ0oMWUOxQTtko6eqgdfyIHPgc3Rd+K+49uqbsXQ6rL8CZ0cUfTCtTW7vttKhWnd4PXy+Spy8eGZREFyW4yYXOMcW6e7hMQ0gD6gY5JT8TH1dUMwiud3aKv07LzbCdGo2k5K7fmawaIWB+R6cNXPSHo0w2ZHAhu3xZUEBo35cRWAHK6gAkp+uC5gDQZ8+VDhi93DbXCyNzdjdu8yZsnjEAE6Fz78cw==` |
| plaintext | `{"v":1,"kind":"done","machineId":"m1","runId":"r1","sessionPath":"/home/u/.omp/agent/sessions/x/1_a.jsonl","title":"Fix the parser","subtitle":"devbox · Done","body":"All tests pass.","ts":1790000000000}` |

## What the companion sends

Only in detached runs (`OMPANION_RUN` set, `contracts/host-launch.md`); the control process sends nothing but
`notify.test`. Every device listed in `<home>/.ompanion/push/`, read afresh for each notification, gets its own
message; whether a device is attached does not matter.

| kind | When |
|---|---|
| `input` | an `ask` request, a tool approval, or an omp or extension `select`, `confirm`, `input` or `editor` dialog opens |
| `done` | a run settles after a terminal `agent_end` (`isTerminal !== false`) with no goal continuation or loop iteration scheduled; a goal completes; a loop ends with a notice (its limit, its time, its condition, or `/loop` turned off) |
| `failed` | a run ends with an assistant message whose `stopReason` is `"error"`, or automatic retries give up |

- A goal's continuation turns and a loop's iterations send nothing until the goal completes or the loop ends.
- A run whose last assistant message stopped with `stopReason: "aborted"` sends nothing: the user stopped it.
- A loop that ends while no run is going sends its `done` at once; one that ends during a run puts its notice in
  that run's `done`.
- The request to the relay times out after 10 s. A `410` deletes that registration file, unless the file changed
  since it was read (the phone rewrote it with a new FID). Any other failure warns attached devices through
  `notify` once per run and device, until a later message to that device succeeds.

Verb `notify.test`, args `{}`: sends a `test` message to the calling device, found by the `deviceId` prefix of the
`callId`. Result `{}`. Errors: `not_found` when that device has no valid registration on the machine; `failed` with
the relay's status and error, or the network error, as the message.

## Relay

`POST https://push.ompanion.app/v1/send`, `Content-Type: application/json`, at most 8 KiB:

```json
{"fid": "<Firebase installation ID>", "platform": "android" | "ios", "nonce": "<base64>", "ciphertext": "<base64>"}
```

| Status | Meaning |
|---|---|
| `204` | FCM accepted the message |
| `400` `{"error": "…"}` | the request is malformed: unknown or missing fields, a nonce that is not 12 bytes, ciphertext over 3,072 base64 characters, an FID over 256 characters |
| `410` `{"error": "…"}` | FCM says the FID is unregistered or invalid; delete the registration |
| `429` `{"error": "…"}` | rate limited, by the relay or by FCM; `Retry-After` when known |
| `502` `{"error": "…"}` | FCM failed otherwise |

The relay keeps no state and logs no request body or FID.

What it sends to FCM (HTTP v1, `projects/<project>/messages:send`):

- `android`: `{"fid", "data": {"v": "1", "n": nonce, "c": ciphertext}, "android": {"priority": "HIGH", "ttl":
  "86400s"}}`. A data-only message: the app decrypts it and posts the notification itself.
- `ios`: `{"fid", "apns": {"headers": {"apns-push-type": "alert", "apns-priority": "10", "apns-expiration": <now +
  86400 s>}, "payload": {"aps": {"alert": {"title": "ompanion", "body": "Session update"}, "mutable-content": 1,
  "sound": "default"}, "v": 1, "n": nonce, "c": ciphertext}}}`. The Notification Service Extension replaces the
  placeholder with the decrypted `title`, `subtitle` and `body`; when it cannot decrypt, the placeholder shows.

Messages target the FID (`message.fid`), not an FCM registration token: FCM HTTP v1 deprecates `message.token` in
favour of `fid`, and the Firebase Messaging SDKs register an installation for messaging with `register()` /
`onRegistered(fid)` in place of `getToken()` / `onNewToken()`.

No message carries an FCM collapse key: FCM throttles collapsible messages to a burst of 20 per device, refilled at
one every 3 minutes.

## Receiving

- A message that does not decrypt, whose `v` is not 1, or whose `ts` is more than 24 hours old is dropped on
  Android and shows the placeholder on iOS.
- One notification per session: Android replaces the previous one with the same tag (`runId`, else `machineId`);
  iOS groups by `threadIdentifier` (the same value).
- A message for the session the app shows in the foreground is not displayed.
- A tap opens the session: the run `runId` on the machine `machineId` when it is still running, else the session
  file `sessionPath`.
