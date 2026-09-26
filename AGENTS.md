# ompanion agent guide

Flutter client for omp. Architecture, decisions and milestones: `docs/PLAN.md`. Feature routes:
`docs/parity.md`. Wire contracts: `docs/contracts/`.

## Repository map

| Path | Contents |
|---|---|
| `lib/`, `test/`, platform dirs | Flutter app (`ompanion`) |
| `packages/omp_core/` | pure Dart: transport (`HostLink`), SSH, host scripts, session channels, RPC client, companion client, session store |
| `companion/` | TypeScript companion extension loaded into omp with `-e` |
| `testing/` | fake OpenAI-compatible provider, isolated omp homes, recorded fixtures, SSH test containers |
| `docs/` | plan, parity contract, research, wire contracts |
| `.tools/` | downloaded omp release binaries (gitignored) |

`packages/omp_core` exposes one library per area (`package:omp_core/transport.dart`, `rpc.dart`, …). No
barrel file re-exporting everything.

## Running omp in tests

- Binaries: `.tools/omp/18.3.1/omp-darwin-arm64` (this Mac), `omp-linux-arm64`, `omp-linux-x64`.
  SHA-256 checked against the release's `SHA256SUMS.txt`.
- Always run omp with an isolated `HOME` (a temp dir). Never touch the real `~/.omp`: it holds the
  user's sessions, credentials and a running omp 18.3.0 whose natives cache a newer omp would delete.
- omp refuses to start RPC mode without a model. The isolated home gets a `models.yml` pointing at the
  fake provider in `testing/fake-provider/`; pass `--model fake/<id>`.
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
- TypeScript: no `any` (`unknown` plus guards; `as unknown as T` with a reason only where a library type
  is wrong). `Promise.withResolvers()` over `new Promise(...)`.

## Tests

- A test defends an observable contract: protocol framing, reducers, parsers, scripts, companion verbs.
  No tests of markup, plumbing or defaults.
- Pure Dart: `dart test` in `packages/omp_core`. Flutter: `flutter test`. Companion: `bun test` in
  `companion/`.
- Integration tests that need omp or Docker are tagged (`@Tags(['omp'])`, `@Tags(['docker'])` in Dart;
  a separate file suffix in Bun) so the unit suite runs without them.
