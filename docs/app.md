# How the app is organised

The app is one web page (`ui/`: SolidJS 2, TypeScript, plain CSS) that runs in each platform's system webview inside a
thin native shell (`shells/`), on a Go core (`core/`) that does SSH, SFTP, PTYs, local processes and the app's
storage. `docs/contracts/bridge.md` is the contract between page, core and shells. How to build and release:
README.md, "Building from Source". How to run the tests: AGENTS.md, "Tests".

## The page (`ui/src/`)

|Path|What it holds|
|---|---|
|`main.tsx`, `App.tsx`|The entry. It renders the app frame at once from the last run's snapshot (theme, language, layout, platform), asks the core for `core.info`, then runs the app's startup (`app/boot.ts`: the shell's answers, the Flutter data import when there is one, the stored settings and documents, "this computer", notifications) and preloads what the first frame left out. In a smoke or bench run it swaps in that run's page instead.|
|`bridge.ts`|The page's only transport (`docs/contracts/bridge.md`): the shell's message handler, the dev bridge's WebSocket (`?devbridge=`), or, in dev builds only, the in-page mock core (`mock.ts`). `call` for requests, `openStream` for streams.|
|`deferred.ts`|`deferred()`, the one place that makes a promise from its resolvers.|
|`core/`|The client core, one folder per area: `rpc/` (omp's RPC frames, the client, JSON guards), `store/` (the session reducer and the transcript items), `session/` (live sessions on a machine), `channel/` (attached and detached runs of omp, the run log), `companion/` (the companion extension's calls), `host/` (probing a machine, installing omp, session listings, uploads), `ssh/` (`SshLink` over `ssh.connect`), `transport/` (`HostLink`, line channels over core streams), `util/`.|
|`app/`|The app: `screens/` (one folder per area: `chat/`, `config/`, `dock/`, `keys/`, `machines/`, `sessions/`, `settings/`, `shell/`, `usage/`, …), `widgets/` (shared controls), `providers/`, `sessions/`, `config/`, `files/`, `terminal/`, `notifications/`, `models/`, `services/`, `database/` (the tables as `store.*` documents), `i18n/`, `utils/`, plus the app's frame: `app_state.ts`, `boot.ts`, `theme.css`, `base.css`, `platform.ts`, `preload.ts`, `first_frame.ts`.|
|`markdown/`|The transcript's markdown: markdown-it blocks and KaTeX math. Code highlighting (Shiki) is in `app/screens/chat/transcript/highlighter.ts`.|
|`test/`|Test helpers: fakes of the core and of hosts, recorded fixtures, the tested omp and the harness's SSH servers.|
|`smoke.tsx`, `bridge_measure.ts`, `term.ts`, `Markdown.tsx`, `styles.css`|Smoke mode (`docs/contracts/bridge.md`, Smoke runs): its page and checks. The `html` check uses the agent page's `app/screens/page_frame/` and `public/frame.html`.|
|`transcript_bench.tsx`|Bench mode (`bench/BENCH.md`): the app's `TranscriptView` running the scripted workload.|
|`app/screens/page_frame/`, `app/screens/chat/transcript/page_view.tsx`, `page_runs.ts`|The agent page's sandbox and protocol, transcript row and freeze guard (`docs/contracts/html-render.md`).|

`ui/scripts/` holds the shot runner (`shots.ts`, one scenario file per area under `shots/`) and `i18n.ts`, which
writes `app/i18n/strings.g.ts`, the type of the app's strings, from `app/i18n/en.i18n.json` (`--check`, part of
`bun run typecheck` and `bun run build`, fails when it is stale). `shots/pages.ts` covers the page gallery and the
real-omp page scenario; `?gallery=transcript&fixture=pages` and `fixture=busy` supply page fixtures.

## Code conventions

- Classes only for what owns lifecycle state (processes, sockets, sessions, timers). Everything else is readonly
  interfaces plus free functions; an update is a spread; a getter with logic is an exported function.
- A union is a discriminated union: each case an interface with a `kind` (`{ kind: "UserItem", … }`). Enums are
  string literal unions.
- Times are epoch milliseconds (`number`, names end in `Ms` or `At`); durations are milliseconds (names end in `Ms`);
  bytes are `Uint8Array`.
- A promise made from its resolvers comes from `deferred()` (`deferred.ts`); no `Promise.withResolvers`, no
  `new Promise(executor)` elsewhere. Event streams are `EventStream<T>` and `Emitter<T>` (`core/util/stream.ts`;
  `{ buffered: true }` for one subscriber that may listen late).
- JSON enters as `unknown` and is decoded once at the boundary with the guards in `core/rpc/json_fields.ts`. No `any`.
- Errors are classes extending `Error` with `name` set. No empty catch, no swallowing.
- The oldest engine is iOS 16's WebKit (Safari 16.0): no API newer than that (`Promise.withResolvers`,
  `Array.fromAsync`, `Object.groupBy`; in CSS `:has()` is fine from 15.4, `color-mix()` and `linear()` easing are
  not). `vite.config.ts` pins the build target (`safari16`, `chrome107`, `edge107`).

## App conventions

- Solid 2.0 (`solid-js@2.0.0-rc.20`). `ui/node_modules/solid-js/CHEATSHEET.md` (its end lists the 2.0 corrections)
  is the reference: it is not React and not Solid 1. An effect's callback runs every time its compute runs, with an
  equal value too: a callback that must run only on a change (a toggle's motion) reads a `createMemo`, which compares.
  A write that derives from a signal's value uses the updater form (`set((current) => …)`): a read, `untrack` too,
  returns the value of the last flush, so two writes in one tick built from reads keep only the second.
- State lives in providers (`app/providers/`, `app/sessions/sessions_provider.ts`): a class that
  owns its state in signals or a store and exposes accessors. The app creates one of each at boot (`app/app_state.ts`)
  and hands them down through Solid contexts (`useSettings()`, `useMachines()`, …).
- Plain CSS. Design tokens are CSS custom properties in `app/theme.css`: the palette tokens of `app/palette.ts`
  kebab-cased (`--field`, `--text-muted`), the Material colour roles they drive (`--surface-container-high`) and the
  sizes. A component's CSS sits next to it, its class names prefixed with the component's name (`.composer-…`). Only
  `app/base.css` styles elements globally. `docs/design.md` applies as written: no strokes, monochrome, flat, OLED
  black, its spacing and type scale. The store screenshots (`store/fastlane/ios/screenshots/`,
  `store/fastlane/android/metadata/android/en-US/images/`, `store/microsoft/screenshots/`) are the look's reference;
  better is allowed, different for its own sake is not.
- Icons: Material Symbols Outlined by their catalog names, as SVGs from `@material-symbols/svg-400`, one import per
  icon in `app/widgets/symbols.ts`, drawn by `app/widgets/icon.tsx`, so the bundle holds only the ones in use.
- Fonts: the platform's UI font (`system-ui` stack); JetBrains Mono (bundled woff2, ligatures off) for code, terminal
  and editor (`--font-mono` in `app/theme.css`).
- Strings: every user-visible string comes from `app/i18n/en.i18n.json` / `de.i18n.json` through `app/i18n/i18n.ts`
  (`t.chat.composer.send`; parameters and plurals in slang's JSON format). A new string goes into both files.
- Platform questions (iOS, Android, a desktop, a touch screen, what the shell offers) go to `app/platform.ts`, which
  reads `shell.info` once at boot.
- Persistence: each table is one `store.*` document holding an array of rows (`machines` with their jumps inline,
  `keys`, `known_hosts`, `settings`, `read_markers`, `pinned_sessions`; `app/database/`). Secrets (private keys,
  passwords) go through `shell.secret*` under the keys `app/services/secret_store.ts` names.
- The entry chunk holds what the first frame shows (shell, sidebar, home pane, theme, English strings) and the
  providers (`docs/research/web-ui/startup.md`). A screen, pane or dialog the first frame does not show is imported
  with `lazy()` (a component, under `<Loading>`) or `lazyModule()` (functions), never statically from the shell's
  files, and registered with `preloadAfterBoot` (`app/preload.ts`) so it loads once the app has booted. Another
  language's strings load before they show (`applyLanguage`). A sourcemap build on 2026-11-02 put the entry
  (`dist/assets/index-*.js`) at 595.41 KB, 200.90 KB gzipped. The entry includes the pump script
  (`core/channel/log_script.ts`) and English page strings (`app/i18n/en.i18n.json`); the page frame and transcript page
  UI are in lazy chunks. A change that grows the entry says why.
- Motion is Material motion with the Flutter SDK's durations and curves, named where they are used, played at 0.6 of
  their length (`motionScale()`, `--motion-scale` in `theme.css`; the 50 ms state-layer fades keep theirs). Menus have
  their own motion (`menuMotion` in `widgets/popup_menu.tsx`): a fade with a 6 px move, not MenuAnchor's reveal.
  `app/motion.ts` holds the curves (`Curves.*`) and plays script-driven motion as Web Animations on transform, opacity
  and clip-path (`curveFrames`, `play`, `settled`), so the compositor runs it even while a page mounts; stylesheets use
  the Bézier curves in `theme.css` (`--curve-…`). Durations shrink to 5 % under `prefers-reduced-motion`. Page routes are
  `widgets/page_stack.tsx` (the phone layout's pages and `navigator.tsx`'s pushed pages; the platform's default
  transition, the iOS back swipe and Android's predictive back); an overlay that closes stays mounted, inert, until
  its motion ends (dialogs, menus, snack bars, tooltips). A pressable gets the pressed highlight and ripple of
  `widgets/ripple.ts` by carrying `data-ripple`; its `::before` state layer then does hover (8 %) and focus (10 %)
  only, fading over 50 ms.

## Tests

Tests defend contracts (reducers, parsers, framing, scripts, protocol), not markup or wiring, as AGENTS.md says, and
sit next to their source: `<file>.test.ts`, or `<file>.e2e.test.ts` when they need a real omp, an SSH server or the Go
core. An e2e test that needs omp uses the tested release with the fake provider (`harness/`), never a paid model; one
that needs SSH uses `harness/studio-sshd.sh`'s bastion and target (`ui/src/test/studio_sshd.ts`). Tests that need
PowerShell 7 or a Windows host skip where those are missing. Bun runs them with `--conditions=browser` (`ui/package.json`'s
`test` and `test:e2e`), so `solid-js` is the build the page runs: under bun's own conditions it resolves to Solid's
server build, whose effects never run. A single file needs the flag too: `bun test --conditions=browser <file>`.
Components that import SVG or CSS do not load under bun, so logic a test needs lives in a plain module beside the
component (`widgets/select_menu.ts`, `widgets/search_debounce.ts`).

## Shots

`ui/scripts/shots.sh` builds `ui/dist` with `VITE_GALLERIES=1` and the dev bridge, then `ui/scripts/shots.ts` serves
the one with the other (`devbridge -static`, a free port, a fresh temporary HOME) and drives Chrome, or with
`--browser webkit` Playwright's WebKit (the engine of the Apple shells' WKWebView), to PNGs in
`build/shots/<area>-<name>-<size>-<theme>.png` (`…-<theme>-webkit.png` in WebKit), desktop 1440 × 900 and phone
390 × 844 (an iPhone's insets), light and dark. Its header lists the options (`--only`, `--sizes`, `--themes`,
`--browser`, `--shot`, `--smoke`, `--omp`). The browser reports reduced motion, so the app's motion runs at 5 % of its
length and a scenario's next step does not race a 300 ms page transition; each picture waits for running motion to end.

`VITE_GALLERIES=1` makes a dev build: the dev galleries with their recorded fixtures, the in-page mock core and
`window.ompDev`. `bun run build` leaves all three out, so the release `dist` the shells bundle carries none of them.

Each `ui/scripts/shots/<area>.ts` exports `screens: Screen[]` (`ui/scripts/shot_types.ts`): a `name`, optionally a
`query` for the page (a dev gallery: `gallery=<name>` renders `app/screens/**/<name>/gallery.tsx`'s default export in
place of the shell) and `reach`, the Playwright steps from a fresh start, which may also `call` core methods and
`exec` commands through the page. A screen with `omp: true` runs only with `OMP=1` (or `--omp`), which puts the tested
omp at `~/.local/bin/omp` of the core's HOME, wired to the fake provider (`harness/dev-machine.sh`); its turns are
queued on `context.provider` (`harness/fake-provider/client.ts`). The screens of a run share one core and HOME; a
`fresh` screen gets its own at every size and theme, as does one with `env` (variables added to its core's environment,
e.g. the dev bridge's `OMPCORE_FLUTTER_DB`), a screen with `sizes` runs only at those sizes (the phone size pretends
iOS, so a desktop-only feature such as dropped paths lists `["desktop"]`), and `context.snap(step)` shoots a step on
the way as `<area>-<step>-…png`: `ui/scripts/shots/journey.ts` walks the whole app that way. A failed `reach` fails its
shot and the run (exit 1); the other shots still run. The runs the core launched omp in outlive it, as on a real
machine, so a core's end also ends their process groups before its HOME goes, and so does a slice's `stop()` (exported
by one that starts something for the whole run, as `sessions.ts` does its sshd) at the run's end; a process still left
fails the run with `LEFT RUNNING <pid> <command>`.

Pictures of the native apps come from the shells: `shells/apple/shot.sh` (iOS simulator, macOS window) and
`shells/android/smoke.sh`'s `smoke.png`, the app launched normally after its smoke run.

## Flutter data import

Releases 1.0.0 to 1.2.1 were a Flutter app. It kept its data in one SQLite file, `ompanion.sqlite` (drift, schema v1 to
v3), and its secrets in flutter_secure_storage. On every launch, before anything reads the settings, mints a
`device_id` or adds "this computer", `app/boot.ts` asks the shell for that data (`shell.flutterData`; where each
platform keeps it: `docs/contracts/bridge.md`, `shell.flutterData`). Only when the shell finds a database or a secret
does the import's code load (`app/screens/shell/flutter_import_screen.tsx`, `app/database/flutter_import.ts`):

- **Imported:** the tables `machines` (with `machine_jumps` nested in order of `position`), `ssh_keys`, `known_hosts`,
  `settings`, `read_markers` and `pinned_sessions` (sorted by `pinned_at`), each as its `store.*` document, read
  through the core's `sqlite.read`, which never writes or locks the file; and every secret, under its own key, through
  `shell.secretSet`. Ids stay as they were: secret names and the files on the machines depend on them. A database of
  schema v1 or v2 imports the tables it has.
- **Checked:** every document and secret is read back and compared with what was written.
- **Deleted:** then `shell.flutterDataClear` deletes every flutter_secure_storage entry (on Android also its key
  preferences and its Keystore key).
- **Kept as backup:** `ompanion.sqlite` and any `-journal`, `-wal` or `-shm` beside it are renamed to
  `<name>.imported`. Nothing reads them again.
- **On failure:** a full-window screen shows the error with Retry and "Continue without importing". Continuing
  records the setting `flutter_import_skipped`, leaves the Flutter data where it is and never asks again; documents
  written before the failure stay.

Tests: `app/database/flutter_import.test.ts` (the conversion), `flutter_import.e2e.test.ts` (the schema v1 to v3
databases of `harness/flutter-seed/fixtures/` through the core), and the smoke check `flutter-import`, which the
shells' smoke scripts run after `harness/flutter-seed/` (`harness/flutter-seed/README.md`) wrote a Flutter app's data
on the device.

## Code from the Flutter app

The Flutter app is in git history at commit `359d920`. Files carried over from it name their Dart source in their
first comment (`// Port of <Dart path>.` or the path alone); the research records in `docs/research/` also name Dart
paths. The paths map as follows.

| Flutter source | Here |
|---|---|
| `packages/omp_core/lib/src/<area>/<file>.dart` | `ui/src/core/<area>/<file>.ts` (same base name) |
| `lib/<dir>/<file>.dart` (not `screens/`) | `ui/src/app/<dir>/<file>.ts` or `.tsx` |
| `lib/screens/<dir>/<file>.dart` | `ui/src/app/screens/<dir>/<file>.tsx`, its styles in `<file>.css` next to it |
| `lib/widgets/*`, shared controls | `ui/src/app/widgets/` |
| `lib/i18n/*.i18n.json` | `ui/src/app/i18n/*.i18n.json` |
| Dart tests (`packages/omp_core/test`, `test/`) | `<file>.test.ts` next to the source; `<file>.e2e.test.ts` when it needs a real omp, an SSH server or the Go core |
| `ios/`, `macos/`, `android/`, `linux/`, `windows/` | `shells/apple/`, `shells/android/`, `shells/linux/`, `shells/windows/` |

What the Go core does instead of a Dart file: local processes and their shells (`transport/local_link.dart`,
`transport/host_process.dart`: `core/exec.go`, `core/pty.go`), the SSH transport (`ssh/ssh_link.dart`'s dartssh2 use,
`ssh/host_key_tap.dart`, `ssh/ssh_agent_client.dart`, `ssh/wire.dart`: `core/ssh.go`, `core/ssh_dial.go`, driven by
`ui/src/core/ssh/ssh_link.ts`), and key generation and parsing (`ssh/ed25519.dart`, `ssh/keys.dart`'s parsing:
`core/keys.go`, `keys.generate`, `keys.inspect`). What the web platform does instead of a Flutter package: drift (the
`store.*` documents), `flutter_pty2` (`pty.open`), `xterm2` (xterm.js), `re_editor` (CodeMirror 6), `gpt_markdown`
(markdown-it and KaTeX in `ui/src/markdown/`), `re_highlight` (Shiki).
