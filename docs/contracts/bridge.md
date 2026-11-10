# Bridge contract

The web UI (`ui/`), the Go core (`core/`) and the shells (`shells/`: Apple for macOS and iOS, Android, Linux,
Windows) agree on this file. A change here changes every side.

## Messages

Every message is one JSON object, sent as text.

| Direction | Shape |
|---|---|
| UI → core, request | `{"id": <int>, "method": "<name>", "params": {…}}` (`params` may be absent) |
| core → UI, response | `{"id": <int>, "result": <any>}` or `{"id": <int>, "error": {"message": "<text>", "code"?, …}}` (see Error codes) |
| core → UI, event | `{"event": "<name>", "params": {…}}` |

- Every request gets exactly one response. The core answers requests concurrently, so responses can arrive out
  of order.
- A stream's events start only after the response that named the stream was emitted.
- Events of one stream arrive in order. `stream.exit` is a stream's last event.
- Output is coalesced per fd: the first output after 4 ms without a `stream.data` event goes out at once (typing
  echoes without delay); output arriving within 4 ms of the last event is gathered into the next one, which carries
  at most 64 KB plus one read. A PTY flood that the OS hands out a few bytes per read thus becomes about 250 events a
  second per fd instead of one per read.
- Text in `stream.data` is UTF-8; the core never splits a multi-byte sequence across two events. A binary stream
  (`encoding: "base64"`, and every `net.connect` stream) carries base64 bytes in `stream.data` and `stream.write`.
- Ids of machines, streams, prompts and forwards are strings (`"m1"`, `"s1"`, `"p1"`, `"f1"`).

## Methods

| Method | Params | Result | Notes |
|---|---|---|---|
| `core.info` | — | `{version, goos, goarch, local, smoke, bench, hostname}` | `version`: the semver of the root `VERSION` (`1.2.1` of `1.2.1+4`), linked in by every build script as `-X ompanion.app/core.Version=<VERSION>`; `""` in a build without it. `local`: this platform can run local processes and PTYs (desktops). `smoke`: `OMPCORE_SMOKE=1` is set. `bench`: `OMPCORE_BENCH=1` is set (`bench/BENCH.md`). `hostname`: this device's host name, for OpenSSH's `%l`/`%L` (`""` when unknown). |
| `core.echo` | any | the params unchanged | round-trip latency |
| `core.log` | `{line}` | `{}` | writes `line` to stderr, and appends it to the file `$OMPCORE_LOG` names when set |
| `core.exit` | `{code}` | `{}` | flushes, then exits the process with `code` about 100 ms later (harness runs: smoke, bench, `shells/apple/shot.sh`) |
| `core.flood` | `{bytes, chunk}` | `{stream}` | emits `bytes` bytes of printable ASCII lines as `stream.data` events of at most `chunk` bytes, then `stream.exit` with code 0 |
| `local.exec` | `{argv?, command?, cwd?, env?, encoding?, inflate?}` | `{stream}` | exactly one of `argv` (a program and its arguments) and `command` (run as SSH exec runs it: `/bin/sh -c <command>` on POSIX, the command line `cmd.exe /d /s /c "<command>"` exactly as written on Windows). `env` entries override the core's environment. `encoding: "base64"` makes the stream binary (default `"utf8"`); the same for `ssh.exec` and `pty.open`. `inflate: true`: the command writes raw deflate (RFC 1951) on stdout, flushed after every write, and `stream.data` carries what it inflates to; a command that ends after a flush without a final block ends cleanly, and one whose stdout does not inflate is killed, its `stream.exit` `error` saying so. The same for `ssh.exec`; the follow script compresses a run's log so (`ui/src/core/channel/follow.ts`). In a Flatpak (`/.flatpak-info`) the program starts on the host through `flatpak-spawn --host`, `cwd` and `env` as its `--directory=`/`--env=` options. Desktops only. |
| `ssh.connect` | `{host, port?, user, auth, proxyCommand?, jump?: [hop…], keepAliveSec?, keepAliveMax?, timeoutSec?, tag?}` | `{machine, hostKeys: ["SHA256:…" per hop, target last]}` | see below |
| `ssh.exec` | `{machine, command, encoding?, inflate?}` | `{stream}` | session channels spread over extra connections to the target when sshd's `MaxSessions` refuses one (as `SshLink`); an extra connection closes after 30 s without sessions; `inflate` as for `local.exec` |
| `ssh.close` | `{machine}` | `{}` | ends its streams with `stream.exit` and closes its forwards; sends no `ssh.closed` |
| `pty.open` | `{machine?, argv?, command?, cwd?, term?, cols, rows, env?, encoding?}` | `{stream}` | no `machine`: a local PTY running `argv` or `command` (as `local.exec`) in `cwd` (default: home), with this environment: `TERM` = `term`, `COLORTERM=truecolor`, on POSIX `LANG=en_US.UTF-8` when the core's environment has no `LC_ALL`/`LC_CTYPE`/`LANG`, and `SHELL` = the account's login shell (`dscl`, `getent passwd`) when its `SHELL` is not absolute; `env` wins over these. Default program: `$SHELL -l` (`/bin/sh` when not absolute), PowerShell `-NoLogo` on Windows. In a Flatpak through `/app/libexec/release-tty flatpak-spawn --host …`. With `machine`: an SSH PTY (`pty-req` with `term`) running `command` (default: a login shell), other `env` entries as SSH env requests (sshd takes only what `AcceptEnv` lists). `term` defaults to `xterm-256color`; an `env` `TERM` wins. |
| `pty.resize` | `{stream, cols, rows}` | `{}` | |
| `stream.write` | `{stream, data}` | `{}` | `data` is UTF-8 text written to stdin, base64 for a binary stream |
| `stream.closeStdin` | `{stream}` | `{}` | sends EOF; for `net.connect`, closes the write half |
| `stream.kill` | `{stream}` | `{}` | resumes a paused stream; locally `SIGKILL` to the process group the process leads (POSIX; a PTY's session leader leads one too) or the termination of its job object (Windows), so what it started ends with it, as when the core releases the streams of a page that went away; over SSH `SIGKILL`, then the channel closes |
| `stream.pause` | `{stream}` | `{}` | flow control: the core stops reading the stream's output (pipe, PTY, SSH channel, connection) once it holds what it can emit no more (the event it was about to emit and up to 64 KB plus one read gathered after it, under 192 KB per fd), so its producer blocks once the OS buffer or the 2 MB SSH window is full. After this response it emits no event of the stream (no `stream.data`, no `stream.exit`) until it resumes. Idempotent |
| `stream.resume` | `{stream}` | `{}` | reading continues: the held output first, the rest in order, `stream.exit` last. Idempotent. A stream's `stream.pause` and `stream.resume` run in the order sent, in an order of their own, so a `stream.write` blocked on a full stdin does not hold them up; `stream.kill` and the end of the stream's machine (`ssh.close`, `ssh.closed`) resume it too |

### Machines, files, network, keys and documents

`machine` is an id from `ssh.connect`, or `"local"` for this device: `fs.*` and `net.*` work on every platform
(within what the OS lets the app reach: its own directories on phones), processes and PTYs on desktops only. Paths
are in SFTP path space (POSIX; Windows drives as `/C:/…`), as `HostFiles` in `ui/src/core/transport/host_link.ts`,
including the ones `core.paths` returns. Binary data travels as base64 in a `data` field. An SSH machine's files go
through one SFTP client, opened on first use and again after it broke.

| Method | Params | Result | Notes |
|---|---|---|---|
| `core.paths` | — | `{data, cache, home?}` | the app's data and cache directories (from `$OMPCORE_DATA_DIR`, `$OMPCORE_CACHE_DIR`, read on every call, else the OS defaults under `com.edde746.ompanion`), created `0700`, and on desktops the user's home |
| `core.env` | `{names: [string]}` | `{env: {name: value}}` | the core's environment variables of those names; unset ones are absent |
| `ssh.answer` | `{prompt, accept?, answers?, cancel?}` | `{}` | answers an `ssh.prompt`: `accept` for `hostKey`, `answers` (one per question) for `keyboardInteractive`, one for `password` and `passphrase`; `cancel` fails the connect |
| `fs.home` | `{machine}` | `{path}` | the user's home: over SSH what SFTP's `realpath .` answers |
| `fs.stat` | `{machine, path, followLinks?}` | `{stat}` or `{stat: null}` when missing | `stat`: `{size, isDirectory, isLink, modifiedMs?, mode}`, `mode` the POSIX `st_mode` with its file type bits; `followLinks` defaults to true, false describes a link itself |
| `fs.list` | `{machine, path}` | `{entries: [{name, stat}]}` | entries do not follow links; no `.` and `..` |
| `fs.read` | `{machine, path, offset?, length?}` | `{data}` | to the end when `length` is absent |
| `fs.write` | `{machine, path, data, append?, mode?}` | `{}` | creates or truncates, or appends; `mode` applies when it creates the file, before any byte is written |
| `fs.mkdir` | `{machine, path, mode?}` | `{}` | error `already exists: <path>` (code `exists`) when it exists: an atomic lock |
| `fs.remove`, `fs.removeDir` | `{machine, path}` | `{}` | a link is removed itself |
| `fs.rename` | `{machine, from, to}` | `{}` | replaces `to` (`posix-rename@openssh.com` where the server has it) |
| `fs.touch` | `{machine, path, modifiedMs}` | `{}` | sets the access and modification times (SFTP: whole seconds) |
| `fs.download` | `{machine, path}` | `{url, size}` | copies the file into the cache directory as `<hex><.ext>`, a name stable for the machine, path, size and modification time; `url` is relative to the page (`cache/<name>`) and the shells serve it |
| `fs.upload` | `{machine, path, cache, mode?}` | `{size}` | streams the file `cache` (a plain name in the cache directory, as `net.fetch`'s `name`) onto the machine at `path`, created (with `mode`, as `fs.write`) or truncated, without holding it in memory; SFTP writes overlap. Code `missing` when the cache file or `path`'s directory is absent |
| `net.forward` | `{machine, host, port, localPort?}` | `{forward, localPort}` | listens on this device's `127.0.0.1` (`localPort` 0 or absent: any free port) and carries each connection to `host:port` as seen from the machine (`direct-tcpip`; `local` dials directly); closes with its machine |
| `net.forwardClose` | `{forward}` | `{}` | closes the listener and its connections |
| `net.connect` | `{machine, host, port}` | `{stream}` | one connection as a binary stream; `stream.exit` code 0 when the far end closed, `null` with `error` otherwise |
| `net.fetch` | `{url, maxBytes?}` | `{url, name, size, mimeType, sha256}` | downloads an http(s) URL into the cache (a web image the user chose to load, a release asset to upload), at most `maxBytes` (default 50 MB, at most 1 GiB); fails once no byte arrived for a minute. `name` is the cache file name (`url` is `cache/<name>`, as for `fs.download`), `sha256` the hex digest of the body, `mimeType` from `Content-Type` without parameters (`application/octet-stream` when absent) |
| `keys.generate` | `{type: "ed25519" \| "rsa" \| "ecdsa", bits?, comment?, passphrase?}` | `{privateKey, publicKey, fingerprint}` | OpenSSH private key text (encrypted with `passphrase`: bcrypt, aes256-ctr), an `authorized_keys` line with `comment`, `SHA256:…`. `bits`: RSA ≥ 2048 (default 3072), ECDSA 256 (default), 384 or 521 |
| `keys.inspect` | `{privateKey, passphrase?}` | `{type, publicKey, fingerprint, comment, encrypted}` | OpenSSH or PEM private keys; error codes `passphrase` (it needs one, or the given one is wrong), `unsupported`, `malformed` |
| `store.read` | `{name}` | `{text}` or `{text: null}` | a document of the app's own data in `<data>/store/<name>.json`; `name` is a letter or digit, then up to 99 letters, digits, `_`, `.`, `-` |
| `store.write` | `{name, text}` | `{}` | atomic replace (a temporary file, then rename) |
| `store.delete` | `{name}` | `{}` | deleting a missing document is fine |
| `sqlite.read` | `{path}` | `{tables: {<table>: [{<column>: value}]}}` | every table of the SQLite database at `path` (this device's file; a native path or SFTP path space), read without SQLite and without writing or locking its files: the Flutter app's database, for the one-time import. Each `type = 'table'` entry of `sqlite_schema` with a b-tree (`sqlite_sequence` included; views, indexes and virtual tables not), its rows in key order (rowid, or the primary key of a WITHOUT ROWID table), columns named from its `CREATE TABLE` (an `INTEGER PRIMARY KEY` column holds the rowid). INTEGER and REAL → number (an infinite REAL as `9e999`/`-9e999`, which `JSON.parse` reads as `Infinity`), TEXT (UTF-8 or UTF-16) → string, BLOB → base64, NULL → `null`; a value a row lacks (a column `ALTER TABLE ADD COLUMN` added after it was written) is `null`, not the column's default. A hot rollback journal (`<path>-journal`) is rolled back and a WAL's (`<path>-wal`) committed frames applied, in memory, as SQLite does on opening it; an empty file is an empty database. Code `missing` when `path` does not exist, `malformed` with what is wrong (`<path>: page 7 has type 0 where a table b-tree page belongs`) |

**`ssh.connect`.** `auth` is `{password?, privateKeys?: [{key?, publicKey?, passphrase?}], agent?: "<socket path>" \|
"default", identitiesOnly?: bool, keyboardInteractive?: bool, none?: bool}`, tried in OpenSSH's order: none,
publickey, keyboard-interactive, password.

- Keys are offered as ssh's `pubkey_prepare` does: the agent's in agent order (one that matches an entry counts as
  that entry; others only without `identitiesOnly`), then the remaining entries that have a `key`. An entry may hold
  only `publicKey` (an `authorized_keys` line), for a key the agent holds. `agent: "default"` is `$SSH_AUTH_SOCK`
  (Windows: `\\.\pipe\openssh-ssh-agent`).
- An encrypted key whose public half is known (OpenSSH format, or `publicKey`) asks for its passphrase (`ssh.prompt`
  `passphrase`) only once the server accepted it; an encrypted PEM key asks before it is offered. A `passphrase`
  given that does not decrypt the key leads to a prompt with `wrong: true`.
- `keyboardInteractive: true` puts the server's keyboard-interactive questions to the page, and, without `password`,
  its password method too (three tries). With `password`, a single non-echoing keyboard-interactive question that
  mentions "password" gets it once.
- Every hop's host key is put to the page with an `ssh.prompt` of kind `hostKey`; the connection continues only when
  it is accepted. Extra connections to a hop must present the key accepted for it. Host key types are asked for in
  this order: `ssh-ed25519`, `rsa-sha2-512`, `rsa-sha2-256`, ECDSA (521, 384, 256), `ssh-rsa`; the Flutter app's
  order, so a server holding several keys presents the type that app recorded in known_hosts.
- Each jump hop has the target's fields and is dialed through the previous one (`direct-tcpip`). `proxyCommand`
  (desktops; `%h`, `%p`, `%r`, `%%` of the first hop) runs as `local.exec`'s `command` and carries the first hop.
- `timeoutSec` (default 15) bounds each hop's connect, channel and handshake, without the time prompts wait for the
  user. The target gets a keepalive every `keepAliveSec` (default 15) and is closed as dead after `keepAliveMax`
  (default 3) unanswered in a row (`ssh.closed`). Both seconds take fractions.
- `tag` (any JSON) comes back in the connect's prompts.

### Error codes

Errors may carry a machine-readable `code` next to `message`; an `ssh.connect` error also carries `hop` (as in
`ssh.prompt`), and for `auth` and `key` `offered` (the keys that hop offered, `[{keyType, publicKey: <base64 blob>,
fingerprint, comment, agent, key?: <index into its privateKeys>}]`) and `agentProblem` (why the agent gave no keys).

| Code | When |
|---|---|
| `exists` | `fs.mkdir` of an existing path; an fs call the OS refuses with EEXIST |
| `missing` | an fs path that does not exist; `sqlite.read` of a database that does not exist |
| `closed` | a machine that is closed or unknown |
| `unreachable` | a TCP connect, a jump's channel or the proxy command failed, or the connection broke during the handshake; `net.*` could not connect |
| `timeout` | a hop did not answer within `timeoutSec`, or a prompt had no answer within 10 minutes |
| `hostKey` | the page rejected or cancelled a host key, or an extra connection's key changed |
| `auth` | the hop refused every credential, or the page cancelled a `password` or `keyboardInteractive` prompt |
| `key` | an `auth.privateKeys` entry is unusable, or there was no key to offer and no other method |
| `passphrase` | `keys.inspect` needs a passphrase or got a wrong one; the page cancelled a `passphrase` prompt |
| `unsupported`, `malformed` | `keys.inspect` of a key type or format the core cannot use, or of something that is not a key; `malformed`: `sqlite.read` of a file that is not a readable SQLite database, its journal or WAL |

## Events

| Event | Params |
|---|---|
| `stream.data` | `{stream, fd: "stdout" \| "stderr", data}` (a PTY's output is `stdout`) |
| `stream.exit` | `{stream, code: <int> \| null, signal?, error?: "<text>"}`; `signal` (`"TERM"`, `"KILL"`, …) names the signal that ended the process, from SSH's exit-signal or the local wait status |
| `ssh.prompt` | `{prompt, tag, hop, kind, …}`: `kind: "hostKey"` with `host, port, keyType, key: <base64 blob>, fingerprint`; `"keyboardInteractive"` with `name, instruction, questions: [{text, echo}], offered, agentProblem?`; `"password"` with `text, offered, agentProblem?`; `"passphrase"` with `text, key: <index into that hop's privateKeys>, wrong, publicKey?: <base64 blob, when known>`. `tag` is the `ssh.connect` call's own `tag` param (`null` when absent); `hop` counts from 0 (the first jump host, or the target without jumps). A prompt waits for its `ssh.answer` at most 10 minutes, then its connect fails with code `timeout`; the connect's `timeoutSec` stops meanwhile. Only the page that called `ssh.connect` is prompted: when the listener is replaced, its waiting prompts end their connects (Core bindings) |
| `ssh.closed` | `{machine, error}` when a machine ends without `ssh.close` (keepalive failure, any hop hanging up) |

## Core bindings

The core is one Go package (`core/`) behind two bindings. Both keep one core per process: the core outlives a
reloaded page; what the old page opened does not. `Start` again, or a devbridge connection opening or closing,
replaces the listener, and the core then releases everything the old page held, whose ids the next page never
knew: it kills every stream (PTYs, `local.exec`, `ssh.exec`, `net.connect`), stops every `core.flood`, closes every
`net.forward` and every SSH machine, and fails every waiting `ssh.prompt`, all without an event to the next page. A
request of the old page still running gets no response (it would reach the next page under an id of its own) and what
it opens is released too; its `core.exit` does not exit. A shell calls `Start` again for every page after the first,
or the old page's streams and machines stay open: before a page it loads itself (a crashed web content process, a
fresh WebView), and when a page loads over another one (the page's own reload, as from the report of
`ui/src/app/failure.ts`, or a webview's Reload menu). Detached omp runs live on their machines, not in streams, so a
reloaded page reattaches to them over new connections.

**gomobile** (`core/ompcore`, iOS, macOS, Android): `gomobile bind` of package `ompcore` (module `ompanion.app/core`).
Every build of a binding or the dev bridge passes `-ldflags "-X ompanion.app/core.Version=<VERSION>"`
(`core/scripts/*.sh`, the shells' `build.sh`), which `core.info`'s `version` reports.

```go
type Listener interface{ OnMessage(message string) }
func Start(listener Listener)   // Swift: OmpcoreStart(listener); Kotlin: Ompcore.start(listener)
func Send(message string)       // Swift: OmpcoreSend(message);   Kotlin: Ompcore.send(message)
func SetEnv(key, value string) error // Swift: try OmpcoreSetEnv(k, v); Kotlin: Ompcore.setEnv(k, v); os.Setenv, synchronous
```

**C** (`core/capi`, Windows and Linux): `go build -buildmode=c-shared -ldflags "-X ompanion.app/core.Version=<VERSION>"
-o <dir>/libompcore.{so,dll} ./capi` writes the library and `libompcore.h`.

```c
typedef void (*omp_core_emit)(const char *message, void *context);
void OmpCoreStart(omp_core_emit emit, void *context);
void OmpCoreSend(char *message);
void OmpCoreSetEnv(char *key, char *value); // os.Setenv, synchronous: Go copied the environment when the library loaded
```

`OnMessage` and `emit` run on a core goroutine's thread, one call at a time. The message is valid only during the
call: a shell copies it and hands it to its UI thread.

## Shells

Each shell serves `ui/dist` (built with relative URLs) from the app bundle, and wires the page to the core.

| Shell | Page URL | Page → core | Core → page |
|---|---|---|---|
| Apple (WKWebView) | `app://ompanion/index.html` (`WKURLSchemeHandler`) | `window.webkit.messageHandlers.core.postMessage(text)` | `evaluateJavaScript("window.ompCore.receive(" + message + ")")` |
| Linux (WebKitGTK 6) | `app://ompanion/index.html` (URI scheme registered secure and CORS-enabled) | `window.webkit.messageHandlers.core.postMessage(text)`: a top-frame user script's stand-in, which hands the text to the real handler in a script world of the shell's own (a top-frame script there, on the app's origin only) | `webkit_web_view_evaluate_javascript` of the same expression |
| Windows (WebView2) | `https://app.ompanion/index.html` (`WebResourceRequested`: a virtual host mapping raises no such event, and `cache/` needs one) | `window.chrome.webview.postMessage(text)` | `PostWebMessageAsJson(message)`; the page reads `event.data` |
| Android (WebView) | `https://appassets.androidplatform.net/assets/ui/index.html` (`WebViewAssetLoader`) | `ompCoreNative.postMessage(text)` (`WebViewCompat.addWebMessageListener`, origin-restricted) | the latest `JavaScriptReplyProxy.postMessage(message)`; the page reads `ompCoreNative.onmessage` |

The page defines `window.ompCore.receive(message)` before its first request; `message` is the parsed object.
Messages the core emits before the page loaded, or while it reloads, are dropped. The Android shell can answer only
after the page's first message, which is always a request.

The page is the app's own code; model HTML runs only in the sandboxed `PageFrame`
(`ui/src/app/screens/page_frame/`, `ui/public/frame.html`). Its policy and the agent page protocol are in
`docs/contracts/html-render.md`; the smoke run's `html` check exercises the frame.

**Cache files.** Every shell also serves `<page base>/cache/<name>` from the core's cache directory (`core.paths`),
so `fs.download` and `net.fetch` results load as ordinary URLs (images, file previews). They come with
`Content-Security-Policy: sandbox` (a document among them never runs as the app), `X-Content-Type-Options: nosniff`
and `Cache-Control: no-cache` (the core may write a name again). Each shell sets `OMPCORE_DATA_DIR` and
`OMPCORE_CACHE_DIR` for the core before `Start` (gomobile: `SetEnv`; C binding: `OmpCoreSetEnv`, since Go on Linux
copies the process environment when the library loads), to its platform's app-data and cache directories.

### Shell services

Requests whose method starts with `shell.` never reach the core: the shell answers them itself, in the same
request/response format, through the same page → core and core → page paths. They are the native services the core
has no business with.

| Method | Params | Result | Notes |
|---|---|---|---|
| `shell.info` | — | `{platform: "macos" \| "ios" \| "android" \| "windows" \| "linux", osVersion, appVersion, build, device, push: bool, paths?: bool}` | `appVersion`: the semver of `VERSION`; `build`: its build number as a string (`"4"`). `push`: the build can receive push notifications (Android and iOS builds with Firebase config; false on desktops). `paths`: true on desktop shells that implement `shell.pickFiles`, `shell.clipboardFiles` and the `shell.drag`/`shell.drop` events; absent (false) elsewhere. With it the page takes files and folders as paths of this computer from those instead of `<input type=file>`, DOM file drops and pasted files, and mentions them where they are in sessions on this computer (`ui/src/app/sessions/prompt_attachments.ts`) |
| `shell.secretGet` | `{key}` | `{value}` or `{value: null}` | Keychain (Apple: generic passwords of service `com.edde746.ompanion`, on macOS in the login keychain, on iOS in the app's first keychain group), Keystore-encrypted storage (Android), Credential Manager (Windows: generic credential `com.edde746.ompanion/<key>`; a value over its 2560-byte limit goes to a DPAPI-encrypted file instead), libsecret (Linux: schema `com.edde746.ompanion`, attribute `key`, one item per key in the default collection; in the Flatpak through the Secret portal where the desktop has one) |
| `shell.secretSet` | `{key, value}` | `{}` | |
| `shell.secretDelete` | `{key}` | `{}` | |
| `shell.openUrl` | `{url}` | `{}` | the system's handler for any scheme (browser, mail) |
| `shell.clipboardWrite` | `{text}` | `{}` | |
| `shell.notify` | `{id, title, subtitle?, body, threadId?, data?, channel?: {id, name}}` | `{}` | a system notification; a newer one with the same `id` replaces it. A tap sends the event `shell.notificationTap {id, data}` and brings the window forward. `channel`: Android posts on that notification channel (created on first use, high importance; `name` is the user-visible label, updated on every post), else on its default channel; other platforms ignore it |
| `shell.notifySchedule` | `{id, atMs, title, subtitle?, body, data?, channel?: {id, name}}` | `{}` | posted by the OS at `atMs` even while the app is not running where the platform can (Apple, Android, Windows through `ScheduledToastNotifier`, which also keeps it across the app's restarts); Linux posts it while the app runs. `channel` as for `shell.notify` |
| `shell.notifyCancel` | `{id}` | `{}` | removes a shown or scheduled notification |
| `shell.notifyPermission` | `{request?}` | `{granted}` | asks the OS when `request` is true; Linux has nothing to ask: granted when a notification server answers |
| `shell.saveFile` | `{name, url}` | `{saved}` | a native save panel (iOS: the share sheet) for a file served from the page's origin (`cache/…`) |
| `shell.insets` | — | `{top, right, bottom, left, keyboard}` | CSS px the page keeps its content out of: status bar, notch, home indicator, navigation bar; `keyboard` is the on-screen keyboard's height (0 when hidden). Desktops answer zeros |
| `shell.dragRegions` | `{drag: [rect], noDrag: [rect]}` | `{}` | macOS only: `rect` is `{x, y, width, height}` in CSS px of the viewport. A mouse-down in a `drag` rect and in no `noDrag` rect moves the window (the shell calls `performDrag`), a double click there does what System Settings says for title bars. The page sends the regions again whenever its header layout changes |
| `shell.titleBar` | — | `{height, leadingInset, fullScreen}` | macOS only: the title bar height the traffic lights are centred in (52, design.md rule 12) and where the header's content starts after them |
| `shell.pickFiles` | `{directory?: bool, multiple?: bool, startIn?: string}` | `{paths: [string]}` | shells with `paths`: the platform's open panel, for folders with `directory`, several with `multiple`, opened in the folder `startIn` (host-native; the panel decides where when it does not exist). `paths` are absolute and host-native (`C:\Users\me\a.txt`), empty when cancelled. Linux: `GtkFileDialog` (the FileChooser portal in the Flatpak, which hands back the real paths since the app reaches the whole host); a chosen file without a local path is left out |
| `shell.clipboardFiles` | — | `{paths: [string]}` | shells with `paths`: the files and folders copied in the file manager, absolute and host-native; empty when the clipboard holds none (a copied link or text is none). Linux: `x-special/gnome-copied-files` (GNOME's), else `text/uri-list`; the `file:` URIs among them |
| `shell.backEnabled` | `{enabled}` | `{}` | Android: whether the page can go back. The shell's back callback is enabled only then (disabled on every page load), so on the root screen the system's back-to-home runs |
| `shell.timing` | `{navigationStart, responseEnd?, domInteractive?, keptFrame?, scriptStart, rendered, liveFrame, firstFrame, firstContentfulPaint?, domContentLoaded?, coreInfo}` | `{}` | the page's startup stages as epoch ms, sent once its first frame painted and `core.info` answered (`ui/src/app/boot_timing.ts`); see Smoke runs for the line the shells log |
| `shell.snapshot` | `{path}` | `{}` | Apple, harness runs only: with `OMPCORE_SNAPSHOT` set (else the method is unknown), writes a PNG of the window to `path` as the snapshot at `core.exit` does (macOS: the page with the traffic lights drawn over it), then answers |
| `shell.flutterData` | — | `{database: string \| null, secrets: {[key]: string}}` | what the Flutter app left on this device: the absolute path of its `ompanion.sqlite` when that file exists, and every flutter_secure_storage entry decoded to its string value. Paths: macOS `~/Library/Application Support/com.edde746.ompanion/`, iOS `<container>/Library/Application Support/`, Android `filesDir`, Windows `%APPDATA%\com.edde746\ompanion\`, Linux `g_get_user_data_dir()/com.edde746.ompanion/` else `…/ompanion/`. The page asks once per launch, in boot, before it reads the settings (`ui/src/app/boot.ts`). Apple: the generic passwords of service `flutter_secure_storage_service`, UTF-8 (`FlutterData.swift`); on macOS in the login keychain, which lets the app read them without asking only when it is signed by the same identity as the Flutter app; on iOS in the app's first keychain group, the Flutter app's. Android: the prefs `FlutterSecureStorage` entries under the plugin's prefix, AES-GCM with the key in `FlutterSecureKeyStorage`, unwrapped by the Keystore RSA-OAEP key `com.edde746.ompanion.FlutterSecureStoragePluginKeyOAEP` (`FlutterData.kt`). Windows: the string members of the UTF-8 JSON object in `flutter_secure_storage.dat` there, DPAPI-encrypted for the current user without entropy (`shells/windows/src/flutter_data.cpp`); the MSIX app sees its package's view of `%APPDATA%`, where the Flutter MSIX wrote. Linux: the string members of the JSON object in the one libsecret item with attribute `account` = `com.edde746.ompanion.secureStorage`, found by that attribute alone (flutter_secure_storage_linux 3.0.3 stores a dangling pointer as its schema name); the Flatpak sees its own data directory and, like the Flutter Flatpak, the Secret portal's keyring where the desktop has one (`shells/linux/services.cpp`) |
| `shell.flutterDataClear` | — | `{}` | deletes every old flutter_secure_storage entry and renames `ompanion.sqlite` (and any `-journal`, `-wal`, `-shm`) to `<name>.imported`, the user's backup; the page calls it once the import read back whole. Apple: deletes those keychain items. Android: deletes the prefs files `FlutterSecureStorage`, `FlutterSecureKeyStorage`, `FlutterSecureStorageConfiguration` and `FlutterSecureStorageConfiguration:FlutterSecureStorage`, and the Keystore key. Windows: deletes `flutter_secure_storage.dat`. Linux: deletes every libsecret item with that `account` |
| `shell.pushStatus` | — | `{available: bool, reason: string \| null}` | Android, iOS |
| `shell.pushEnable` | `{deviceId}` | `{platform: "android" \| "ios", fid, key}` | asks for permission, makes the key, registers for messaging; error codes `denied`, `unavailable`, `failed`. iOS (`shells/apple/Sources/iOS/Push.swift`): Firebase starts only while push is on and gets the APNs token by hand; the key and the device id are in keychain service `app.ompanion.push` of the group `…com.edde746.ompanion.push` it shares with the extension, the FID in UserDefaults `ompanion.push.fid`, as the Flutter app kept them |
| `shell.pushRegistration` | — | `{platform, fid, key}` or `null` | the registration push runs on; `null` when there is none (a restore from a backup brings no key) |
| `shell.pushDisable` | — | `{}` | unregisters, deletes the installation and the key; error code `failed` |
| `shell.pushSetVisible` | `{machineId, runId?, sessionPath?}`, or `{}` | `{}` | the session on screen while the app is in front, whose pushes the shell drops; `{}` (no `machineId`): none |
| `shell.pushClear` | `{machineId, runId?}` | `{}` | removes the shown push notifications of that session (thread `runId`, else `machineId`) |
| `shell.pushTakeLaunchTap` | — | `{machineId, runId?, sessionPath?}` or `null` | the push tap that launched the app, once; the shell holds taps until the page first calls this, later ones come as `shell.pushTap` |

Shell events: `shell.notificationTap {id, data}` (a tap that launched the app, or came while no page was loaded, is
sent right after the page's first message, so the page subscribes before its first request); `shell.appState {active}`
(the app came to the front or left it); `shell.insets {top, right, bottom, left, keyboard}` when they change;
`shell.titleBar {height, leadingInset, fullScreen}` when the window enters or leaves full screen (macOS);
Android's back gesture, while `shell.backEnabled` is on: `shell.backStart {edge: "left" | "right"}` when a gesture
starts, `shell.backProgress {progress}` (0..1) as it moves and `shell.backCancel` when it is let go (Android 14 and
later), then `shell.back {}` when it commits (every version; the shell does nothing else: the page goes back).
`shell.pasteFiles {files: [{url: "cache/<name>", name, mimeType}]}`: images the shell wrote to its cache directory for
the page to attach like pasted files (to the composer that has the focus; the page drops them otherwise); Android: a
keyboard's image insertion (commitContent of PNG, JPEG, GIF or WebP) into any field of the page; iOS: the system's
Paste of copied images, which the app delegate offers in the edit menu (its `pasteConfiguration`) while the field
declines it (a pasteboard without text), PNG, JPEG, GIF or WebP as copied and anything else as PNG. Shells with `paths`
handle file drops themselves (text and links dropped still reach the page): `shell.drag {active}` when files dragged
from another app enter the window (`true`) and when they leave it or are dropped (`false`, before the drop), and
`shell.drop {paths}` with the dropped files and folders, absolute and host-native (macOS: the web view's subclass takes
the drags whose pasteboard holds file URLs; Linux: a `GtkDropTarget` for file lists in the capture phase, ahead of
WebKit's, reads the list while the drag hovers and keeps the drag when every item has a local path, else rejects it and
WebKit takes it; drags out of the page itself never stop there; Windows: WebView2 is the drop target,
so a script the shell adds to every document takes drags that carry files and posts the dropped `File` objects with
`chrome.webview.postMessageWithAdditionalObjects`; the shell reads their paths). Without `paths`, file choosing uses
the page's `<input type=file>`; the shells implement the platform's file chooser for it (macOS `runOpenPanel…`,
Android `onShowFileChooser`, Linux `run-file-chooser` with `GtkFileDialog`). Push (Android FCM, iOS APNs with its
notification service extension; `docs/contracts/push.md`):
`shell.pushFid {fid}` when the Firebase installation ID changes, `shell.pushTap {machineId, runId?, sessionPath?}` for a
tap on a push notification after `shell.pushTakeLaunchTap` was called.

**Dev bridge** (`core/cmd/devbridge`, desktops, development only): `go run ./cmd/devbridge -listen 127.0.0.1:<port>
[-static <dir>]` serves the real core over a WebSocket at `ws://127.0.0.1:<port>/bridge`, one bridge message per text
frame, so the page runs in a desktop browser against the real core. The latest connection takes over the core: the
bridge closes the one it replaced with status 1001 (going away) and drops what that one still sends for the core. Port
0 picks a free port; the stderr line `devbridge: serving the core at ws://127.0.0.1:<port>/bridge` names it. It serves
the core's cache directory at `/cache/<name>` and, with `-static`, `<dir>` (a built `ui/dist`) at `/`. It accepts pages
from `localhost`, `127.0.0.1` and `[::1]` on any port, and listens on loopback only. It answers `shell.*` itself:
secrets in memory; `shell.info` with `platform` from `GOOS` (`darwin` → `macos`), `osVersion` from `uname -r`, the
core's version split at `+` into `appVersion` and `build`, the host name and `push` (true with
`OMPCORE_DEVBRIDGE_PUSH=1`), without `paths`
(the page pretends it with `?paths=1`); `openUrl`, `clipboardWrite`, `notify*`, `pushSetVisible`, `pushClear`,
`backEnabled` and `saveFile` (`{saved: false}`) logged to stderr; `notifyPermission` granted; zeros for `shell.insets`
and `shell.titleBar`; `dragRegions` does nothing; `pickFiles` and `clipboardFiles` answer `{paths: []}` (cancelled,
nothing copied). Two methods of its own let scripts (`ui/scripts/shots`, e2e tests) play the shell's part through the
page: `shell.devEmit {event, params}` sends the shell event `event` (a `shell.*` name) with `params` to the page before
its response, and `shell.devAnswer {method, result}` makes the next `method` request answer `result`.
`shell.flutterData` answers from `$OMPCORE_FLUTTER_DB` (an `ompanion.sqlite`, when the file exists) and
`$OMPCORE_FLUTTER_SECRETS` (a JSON object file of secrets), read on every call; `shell.flutterDataClear` renames the
database files to `….imported` and deletes the secrets file. Push: `pushStatus` unavailable and `pushEnable` code
`unavailable` unless `OMPCORE_DEVBRIDGE_PUSH=1`, which fakes a registration (`platform: "android"`, a random key)
that `pushRegistration` returns until `pushDisable`; `pushTakeLaunchTap` answers `null`. The page uses it when its URL
has `?devbridge=ws://127.0.0.1:<port>/bridge`; with no shell and no `devbridge` it falls back to an in-page mock.

## Smoke runs

`OMPCORE_SMOKE=1` in the core's environment puts the page in smoke mode: it runs its checks, writes one
`core.log` line `SMOKE <json>` per check (`{"check": "<name>", "pass": <bool>, …measurements}`), then
`SMOKE-DONE {"passed": n, "total": n}`, then calls `core.exit` with 0 when every check passed, else 1.

**Launch timing.** On every launch the Apple and Android shells log one line, `shell timing {"processStartEpochMs": n,
"shellMs": n, …}`, when the page sends `shell.timing`: the kernel's start of the process as epoch ms, then each stage in
ms since then, in the order they happened. The shell's own stages: `shellMs` (its first code), `webviewMs` (the web
view exists); Apple also `mainMs` (`main` ran), `loadMs`, `mainQueueMs`, `shownMs` (the window is on screen),
`policyMs`, `commitMs`, `coreEnvMs`, `coreStartMs`, and on macOS `nsAppMs`, `willFinishLaunchingMs`, `windowMs`,
`menuMs`, `didFinishLaunchingMs`. The page's: `navigationStartMs`, `responseEndMs`, `domInteractiveMs`, `keptFrameMs`
(the last launch's first frame painted, `ui/src/app/first_frame.ts`; not on iOS), `scriptStartMs` (the entry began
evaluating), `renderedMs` (the app frame rendered), `liveFrameMs` (that render painted), `firstFrameMs`
(the first of the two), `firstContentfulPaintMs` (the engine's own, where it has one), `domContentLoadedMs`,
`coreInfoMs`. Apple writes it to stderr and `$OMPCORE_LOG`, Android to logcat (tag `OmpanionShell`). Linux writes the
page's epoch marks as `shell timing page {…}` to stderr and keeps its smoke-only `shell timing {"webviewMs",
"domContentLoadedMs", "coreInfoMs"}` line; Windows answers without logging.

| Check | Passes when |
|---|---|
| `info` | `core.info` answers; the line carries its result |
| `echo` | 200 sequential `core.echo` round trips return their params; the line carries `p50Ms` and `p95Ms` |
| `flood` | `core.flood` of 20,000,000 bytes in 65,536-byte chunks arrives whole; the line carries `mbPerSec` |
| `markdown` | a fixed sample with a heading, a list, a table, a fenced code block and `$…$` math renders those elements |
| `html` | a sample page in an agent page's frame (`PageFrame`, `ui/public/frame.html`), with no network needed: its inline script reads a theme variable (`--background`, not empty) while the page loads; the frame reports a height above 0; a `fetch` and an image (`srcset`, which no engine upgrades to https: as Chromium does an `http:` `<img src>` on an https: page) of an `http:` URL fail with `securitypolicyviolation` events for `connect-src` and `img-src`; a `fetch` and an image of `https://ompanion-smoke.invalid/` (never resolves) raise none; a script's `click()` on an https link sends the app no link message; and a `store.write` and a `shell.secretSet` the page posts to every native handler it finds (`window.webkit.messageHandlers.core`, `window.chrome.webview`, `window.ompCoreNative`; the line's `handlers`) get no answer, in the frame or through the app's `window.ompCore.receive`, and leave no document and no secret. The line carries what the page saw |
| `terminal` | xterm.js shows a marker line written to it, from `pty.open` on desktops and from `core.flood` data on phones |
| `exec` | desktops: `local.exec` of `sh -c "echo smoke-ok"` (`cmd /c echo smoke-ok` on Windows) prints `smoke-ok` and exits 0 |
| `pty` | desktops: a local `pty.open` shell echoes a marker written with `stream.write` |
| `shell` | `shell.info` answers, and its `platform` matches `core.info`'s `goos` |
| `secret` | `shell.secretSet`, `shell.secretGet` and `shell.secretDelete` round-trip a non-ASCII value |
| `notify` | only with `OMPCORE_SMOKE_NOTIFY=<seconds>` (else it passes with `skipped: true`): `shell.notify` of "shown now", `shell.notifySchedule` of "replaced" and then "scheduled" under one id at now + seconds, and of a third id that `shell.notifyCancel` cancels, all answer; a harness then reads the system's notifications (Windows: `shells/windows/ci.ps1` reads the toast history after the app exited and the time passed) |
| `paths` | desktops, only with `OMPCORE_SMOKE_PATHS=<folder>` (else `skipped: true`), driven by a harness that copied `<folder>/a.txt` and `<folder>/sub` and acts on the `SMOKE-STEP <step>` lines the check logs: `shell.clipboardFiles` gives those two, `shell.pickFiles` gives `a.txt` and `b.txt` chosen in the open panel (`pick-files`) and `sub` in the folder panel (`pick-folder`), and a drag of `a.txt` and `sub` onto the window (`drop`) gives `shell.drag {active: true}` and `shell.drop` with them (Windows: `shells/windows/ci.ps1`; Linux: `shells/linux/ci.sh`, with xclip, xdotool and a GTK 3 drag source under Xvfb; macOS: `shells/apple/smoke.sh` runs `shells/apple/Harness/PathsHarness.swift`, a UI test that drags from a Finder window) |
| `store` | `store.write`, `store.read` and `store.delete` round-trip a document |
| `flutter-import` | only with `OMPCORE_EXPECT_IMPORT=<path of harness/flutter-seed/expected.json, readable through fs.read on machine local>` (else it passes with `skipped: true`): `shell.flutterData` finds Flutter data, the import (as boot runs it) succeeds, every document and secret the file lists reads back equal, and `shell.flutterData` then finds nothing |
| `cache` | a PNG written with `fs.write` (machine `local`) into `core.paths`' `cache` loads in an `<img>` from `cache/<name>` |

| Platform | How a harness sets it and reads the lines |
|---|---|
| macOS, Linux, Windows | the environment of the app process; `OMPCORE_LOG=<file>` for the lines (Windows GUI apps have no stderr). Windows MSIX: the user's environment (`HKCU\Environment`), which a packaged app started by the system gets |
| iOS simulator | `SIMCTL_CHILD_OMPCORE_SMOKE=1 xcrun simctl launch --console-pty …`, which also shows stderr |
| Android | intent extra `--ez smoke true`: the shell calls `Ompcore.setEnv("OMPCORE_SMOKE", "1")` before `Ompcore.start` (`--es expectImport <path>`: `OMPCORE_EXPECT_IMPORT`); lines in `adb logcat`, tag `GoLog` (`shell timing`: tag `OmpanionShell`) |
