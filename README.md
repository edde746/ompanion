# omp-app

Flutter client for [omp](https://github.com/can1357/oh-my-pi). Plan and decisions: `docs/PLAN.md`; agent
guide: `AGENTS.md`.

## Build

The app bundles the companion extension it uploads to every machine (`docs/contracts/ompx.md`). The
bundle is a build artifact, so build it before any `flutter build`, `flutter run` or `flutter test`:

```sh
scripts/build_companion.sh      # companion/dist/ompx.js → assets/companion/ompx.js (needs bun)
flutter build macos
```

Without it `pubspec.yaml` names a missing asset and the build fails; a build that still lacks the file
reports every machine as failed with "This build has no companion".

## Development

Run the app against an isolated omp home and the fake provider, never your real `~/.omp`: see
`testing/README.md`, section "Dev machine", for the demo server and the `OMP_APP_LOCAL_HOME`,
`OMP_APP_DATA_DIR` and `OMP_APP_SECRET_PREFIX` defines (`lib/app/dev_overrides.dart`).

The chat transcript has a streaming benchmark, a profile-mode target (2,000-item session, a 12 KB reply streamed at
50 updates per second). It prints frame build and raster percentiles and writes them to
`build/integration_response_data.json`; results are in `docs/research/ui-libraries.md`, section "Performance":

```sh
flutter drive --profile -d macos --driver=test_driver/integration_test.dart \
  --target=integration_test/transcript_benchmark_test.dart
```
