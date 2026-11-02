# ompanion contributor guide

GUI client for omp: one web page that runs in a thin native shell over each platform's system webview, on a Go core.
Architecture, decisions and milestones: `docs/PLAN.md`. How the UI is organised and its conventions: `docs/app.md`.
Feature routes: `docs/parity.md`. Wire contracts: `docs/contracts/` (`bridge.md`: page, core and shells). UI rules:
`docs/design.md`. Building and releasing: `README.md`, "Building from Source".

## Repository map

| Path | Contents |
|---|---|
| `ui/` | the app: one web page (SolidJS 2, TypeScript, plain CSS) that every shell bundles as `ui/dist`. `ui/src/core/` is the client core (RPC client, session reducer, detached runs, companion calls, host scripts, SSH links over the Go core); `ui/src/app/` the screens, providers and widgets; `ui/scripts/` the shot runner and the strings' types (`docs/app.md`) |
| `core/` | Go core: request dispatcher, streams with flow control, local exec and PTYs, SSH with jump chains and prompts, SFTP, forwards, keys, the app's documents, `sqlite.read`; bindings `ompcore/` (gomobile: Apple, Android) and `capi/` (C: Linux, Windows), `cmd/devbridge` (the core over a WebSocket, so the page runs in a desktop browser), `cmd/licenses` (adds the core's and the shell's native libraries to the licences page's list; each shell's build runs it, `docs/research/licenses.md`), `scripts/` (build the bindings) |
| `shells/apple/` | macOS and iOS app: Swift, WKWebView, XcodeGen (`project.yml`), the Notification Service Extension, Sparkle (macOS) |
| `shells/android/` | Android app: Kotlin, Android System WebView, Gradle; push through Firebase Cloud Messaging |
| `shells/linux/` | Linux app: C++20, GTK 4, WebKitGTK 6, CMake, built in Docker; the Flatpak in `flatpak/` |
| `shells/windows/` | Windows app: C++20, Win32, WebView2, CMake, cross-built with llvm-mingw in Docker; the MSIX in `msix/` |
| `companion/` | TypeScript companion extension loaded into omp with `-e` |
| `relay/` | push relay: a Bun server on our VPS that forwards encrypted notifications to FCM (`relay/README.md`) |
| `harness/` | fake OpenAI-compatible provider, isolated omp homes, recorded fixtures, the OpenSSH bastion and target of the e2e tests (`studio-sshd.sh`), the Flutter seed of the data import tests (`flutter-seed/`) |
| `bench/` | the transcript bench (`BENCH.md`) and the startup measurement (`measure/`) |
| `scripts/` | build the companion, fetch an omp release binary, regenerate icons, sign and notarize the macOS app, run a command on studio.local (`studio.sh`), release to the stores and GitHub (`release/deploy.py`) |
| `.github/workflows/` | CI (`ci.yml`), the per-platform build and the release (`build.yml`) |
| `store/` | the store submission checklist and console answers, the fastlane lanes and listings (`fastlane/`), release notes, the review demo host, the screenshot capture |
| `website/` | ompanion.app (SvelteKit, static), deployed by Cloudflare Workers Builds (`website/README.md`) |
| `docs/` | plan, app organisation, parity contract, UI rules, research, wire contracts |
| `VERSION` | the app's version, `<semver>+<build>`; every build reads it and nothing else |
| `.tools/`, `build/` | downloaded omp release binaries; build outputs (both gitignored) |

## Running omp in tests

- Binaries: `.tools/omp/<version>/omp-<os>-<arch>`, fetched by `scripts/fetch_omp.sh <os>-<arch>...` (e.g.
  `darwin-arm64`, `linux-x64`) and SHA-256 checked against the release's `SHA256SUMS.txt`. The version is the tested
  one in `harness/omp-version`, or `$OMP_VERSION` for every script and test (`OMP_VERSION=18.3.1` runs the minimum,
  `minimumOmpVersion` in `ui/src/core/host/probe.ts`). Tests pick this computer's binary by `process.platform` and
  `process.arch`: the UI's through `ui/src/test/omp.ts`, the companion's through `harness/omp-home.ts`.
- Always run omp with an isolated `HOME` (a temp dir). Never touch the real `~/.omp`: it holds the
  user's sessions and credentials, and a running omp's natives cache is deleted by a newer omp.
- omp refuses to start RPC mode without a model. The isolated home gets a `models.yml` pointing at the
  fake provider in `harness/fake-provider/`; pass `--model fake/<id>`.
- Never make a paid model call. Real providers are off limits in tests and spikes. The one exception is the
  owner's review demo server: `store/review-demo/verify/` sends a prompt to its capped key only when asked.
- Kill every process you start. Do not kill processes you did not start.

## Writing

- Plain words. Conclusion first, then evidence. Every sentence is a fact, a decision or a risk.
- Docs state what is true now. No changelog prose in docs.
- Commit subject: `type(scope): lowercase imperative summary`, no period.

## Code

- Minimal and boring. No abstraction until the third caller. No wrapper around a single call.
- Plain data plus pure functions. Classes only when they own lifecycle state (sockets, processes, sessions, timers).
- Errors fail loudly at the boundary. No empty `catch`. No swallowing.
- Comments only for a non-obvious why: a constraint, a protocol requirement, a measured decision.
- Delete dead code in the same change that orphans it. No compatibility shims.
- Lines are at most 120 columns. No formatter runs in CI; follow the file's style.
- Logic belongs in the page or the core. A shell hosts the page and answers the `shell.*` services
  `docs/contracts/bridge.md` lists for its platform, nothing more.
- TypeScript (`ui/`, `companion/`, `relay/`, `harness/`): strict `tsc` (`ui/tsconfig.json` adds
  `noUncheckedIndexedAccess` and `noUnused*`). No `any`: `unknown` plus guards, decoded once at the boundary;
  `as unknown as T` with a reason only where a library type is wrong. Unions are discriminated by `kind`. The page
  follows `docs/app.md` (Code conventions, App conventions): Solid 2 (not React, not Solid 1), `deferred()` instead of
  `Promise.withResolvers()` or `new Promise(...)`, nothing newer than Safari 16, every string in the i18n files.
  `ui/src/app/i18n/strings.g.ts` is generated by `bun run i18n` in `ui/`; never edit it by hand.
- Go (`core/`): standard library first; a new module dependency needs a reason (the binaries' size matters). Errors
  carry a code the page can act on (`docs/contracts/bridge.md`, Error codes). Tests sit next to the code
  (`*_test.go`); fixtures in `core/testdata/`.
- Swift (`shells/apple/`): Swift 6. `project.yml` is the project; XcodeGen writes `ompanion.xcodeproj` (gitignored).
- Kotlin (`shells/android/`): Gradle Kotlin DSL; JVM unit tests in `app/src/test/`.
- C++ (`shells/linux/`, `shells/windows/`): C++20, CMake.

## Tests

- A test defends an observable contract: protocol framing, reducers, parsers, scripts, companion verbs.
  No tests of markup, plumbing or defaults.
- Suites, each run from its directory:

  | Part | Command |
  |---|---|
  | UI types and strings | `bun run typecheck` in `ui/` |
  | UI unit | `bun run test` in `ui/` (`bun test --conditions=browser`, without `*.e2e.test.ts`) |
  | UI end to end | `bun run test:e2e` in `ui/`: real omp with the fake provider, the Go core's dev bridge, OpenSSH (`harness/studio-sshd.sh`), ffmpeg |
  | Core | `go vet ./...` and `go test -race ./...` in `core/` |
  | Companion | `bun run typecheck` and `bun test` in `companion/`; `bun run test:e2e` starts omp |
  | Relay | `bun run typecheck` and `bun test` in `relay/` |
  | Website | `bun run check` in `website/` |
  | Release script | `python3 scripts/release/test_deploy.py` |
  | Android shell | `./gradlew testDebugUnitTest` in `shells/android/` |
  | Shells, every platform | `smoke.sh` in each `shells/<platform>/` (`docs/contracts/bridge.md`, Smoke runs); on CI runners `shells/linux/ci.sh` and `shells/windows/ci.ps1` |

- Bun runs the UI's tests with `--conditions=browser`, a single file too (`bun test --conditions=browser <file>`):
  without it `solid-js` resolves to its server build, whose effects never run.
- The end-to-end tests need `scripts/build_companion.sh` and this computer's omp in `.tools/`
  (`scripts/fetch_omp.sh`). Tests that need PowerShell 7 or a Windows host skip where those are missing, and the
  ffmpeg tests skip without ffmpeg unless `CI` is set.
- CI (`.github/workflows/ci.yml`) runs every suite above for every push and pull request to `main`, except the
  companion's `test:e2e` and the shells' `smoke.sh`: the UI's e2e tests against the tested omp and the minimum, and
  the Windows host ones (`windows_host`, `windows_session`) against a Windows runner's own Win32-OpenSSH; the Apple
  shell's builds (macOS, iOS simulator, iOS device); the Android shell's release build and unit tests; on Linux x64
  the build, the Flatpak and `shells/linux/ci.sh` (smoke with the Flutter data import, on the runner and in the
  Flatpak); the Windows cross-build and `shells/windows/ci.ps1` on x64 and arm64 runners (the zip's app and the MSIX's,
  with the Flutter data import).
- The maintainer's Mac holds the real app and its data, so nothing runs there: `scripts/studio.sh <stage>
  [--need …] [--fetch <path>] -- <command>` runs a command in a copy of the repo on studio.local under a devpool lease
  (its header says what is copied), and the shells' `smoke.sh` and `shot.sh` lease their devices themselves.
- `ui/src/core/ssh/fixtures/` holds throwaway private keys (OpenSSH and PEM, plain and passphrase-protected, plus
  ECDSA) that exist only for the SSH key and known_hosts tests; `core/keys_test.go` and `harness/flutter-seed/` hold
  more of the same. No other code reads them. They are test material, not credentials.
