# ompanion contributor guide

Flutter client for omp. Architecture, decisions and milestones: `docs/PLAN.md`. Feature routes:
`docs/parity.md`. Wire contracts: `docs/contracts/`. UI rules: `docs/design.md`.

## Repository map

| Path | Contents |
|---|---|
| `lib/`, `test/`, `integration_test/`, platform dirs | Flutter app (`ompanion`) |
| `packages/omp_core/` | pure Dart: transport (`HostLink`), SSH, host scripts, session channels, RPC client, companion client, session store |
| `companion/` | TypeScript companion extension loaded into omp with `-e` |
| `relay/` | push relay: a Bun server on our VPS that forwards encrypted notifications to FCM (`relay/README.md`) |
| `harness/` | fake OpenAI-compatible provider, isolated omp homes, recorded fixtures, SSH test containers |
| `scripts/` | build the companion, fetch an omp release binary, regenerate icons, sign and notarize the macOS app |
| `.github/workflows/` | CI (Linux and a Windows host), the per-platform build and release |
| `store/` | the store submission checklist and console answers, the review demo host, screenshot captions |
| `website/` | ompanion.app (SvelteKit, static), deployed by Cloudflare Workers Builds (`website/README.md`) |
| `docs/` | plan, parity contract, UI rules, research, wire contracts |
| `.tools/` | downloaded omp release binaries (gitignored) |

`packages/omp_core` exposes one library per area (`package:omp_core/transport.dart`, `rpc.dart`, …). No
barrel file re-exporting everything.

## Running omp in tests

- Binaries: `.tools/omp/18.3.1/omp-<os>-<arch>`, fetched by `scripts/fetch_omp.sh <os>-<arch>...` (e.g.
  `darwin-arm64 linux-arm64` for a macOS host and the Linux SSH test machines) and SHA-256 checked
  against the release's `SHA256SUMS.txt`. Dart tests pick them through `packages/omp_core/test/omp_binary.dart`
  (this computer's, and Docker's architecture for the SSH test machines); Bun tests by `process.platform`
  and `process.arch`.
- Always run omp with an isolated `HOME` (a temp dir). Never touch the real `~/.omp`: it holds the
  user's sessions and credentials, and a running omp's natives cache is deleted by a newer omp.
- omp refuses to start RPC mode without a model. The isolated home gets a `models.yml` pointing at the
  fake provider in `harness/fake-provider/`; pass `--model fake/<id>`.
- Never make a paid model call. Real providers are off limits in tests and spikes.
- Kill every process you start. Do not kill processes you did not start.

## Writing

- Plain words. Conclusion first, then evidence. Every sentence is a fact, a decision or a risk.
- Docs state what is true now. No changelog prose in docs.
- Commit subject: `type(scope): lowercase imperative summary`, no period.

## Code

- Minimal and boring. No abstraction until the third caller. No wrapper around a single call.
- Plain data plus pure functions. Classes only when they own lifecycle state (sockets, processes, sessions).
- Errors fail loudly at the boundary. No empty `catch`. No swallowing.
- Comments only for a non-obvious why: a constraint, a protocol requirement, a measured decision.
- Delete dead code in the same change that orphans it. No compatibility shims.
- Dart: `provider` + `ChangeNotifier` in the app; no Bloc, Riverpod or GetIt. Sealed classes for unions.
  No `dynamic` outside JSON decoding boundaries; decode once into typed values.
- Dart formatting is `dart format` at 120 columns (`analysis_options.yaml`); CI checks it. Generated files
  (`*.g.dart`, `lib/i18n/strings*.g.dart`, drift's migration schemas) are excluded: the generators own
  their bytes.
- TypeScript: no `any` (`unknown` plus guards; `as unknown as T` with a reason only where a library type
  is wrong). `Promise.withResolvers()` over `new Promise(...)`.

## Tests

- A test defends an observable contract: protocol framing, reducers, parsers, scripts, companion verbs.
  No tests of markup, plumbing or defaults.
- Pure Dart: `dart test` in `packages/omp_core`. Flutter: `flutter test`. Companion: `bun test` in
  `companion/`. Relay: `bun test` in `relay/`.
- Integration tests are tagged so the unit suite runs without them: `@Tags(['omp'])`, `@Tags(['docker'])` and
  `ffmpeg` in Dart (`dart test -P integration` runs them), `*.e2e.test.ts` in Bun (`bun run test:e2e`). Tests tagged
  `windows` need a prepared Windows host and run with `-P windows`.
- `packages/omp_core/test/ssh/fixtures/` holds throwaway private keys (OpenSSH and PEM, plain and
  passphrase-protected, plus ECDSA) that exist only for the SSH key and known_hosts tests; no other code
  reads them. They are test material, not credentials.
