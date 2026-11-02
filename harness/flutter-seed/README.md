# Flutter seed

The web app imports the Flutter app's data on its first launch. To test that import against real Flutter storage,
`main_seed.dart` is an entrypoint for the Flutter app at commit `359d920` that writes a fixed data set through the
app's own `AppDatabase`, providers (`MachinesProvider`, `SettingsProvider`, `SessionPins`) and `SecretStore`, reads it
back, prints `SEEDED 7 7` (tables, secrets) and exits. Desktops print to stdout and exit; phones also log the line
(iOS console, logcat as tag `flutter`) and stay on a "seeded" screen.

| File | |
|---|---|
| `seed_data.dart` | the data set: plain Dart constants, times as UTC instants |
| `main_seed.dart` | the entrypoint. With a file `seed-clean` next to the database it deletes the seed's secrets instead and prints `CLEANED 7` |
| `expected.json` | what the web app must hold after the import: `{"store": {<document>: [<row>]}, "secrets": {<key>: <value>}}` |
| `fixtures/flutter-v1.sqlite`, `flutter-v2.sqlite` | part of the data as app versions with schema v1 and v2 stored it (drift's generated schemas of those versions; zone America/New_York) |
| `fixtures/expected-v1.json`, `expected-v2.json` | the documents those files import to; a table the file lacks has no document |
| `fixtures/flutter-v3.sqlite` | the database of a macOS seed run on studio (Europe/Stockholm); imports to `expected.json`'s documents |
| `fixtures.sh`, `fixtures.dart` | rewrite `expected.json` and the v1/v2 files from `seed_data.dart`; run after changing it |
| `build.sh` | builds the seed |
| `run.sh` | runs it on studio through devpool: macOS, iOS simulator, the Pixel |
| `run-host.sh` | runs it on a Linux or Windows host (CI runner, container) |

## What the data set covers

Six machines: this computer (no host, user or auth); SSH with key auth (the RSA key) on port 2222 through two jumps,
one with password auth and a saved password, one with agent auth on port 2200; keyboard-interactive with an
`~/.ssh/config` alias; password auth with a saved password of non-ASCII text and an emoji; Tailscale with `none` auth,
whose three control-plane host keys come with its save; key auth with the passphrase key through a jump with key auth.
One machine name is non-ASCII. Three keys: ed25519, ed25519 with a passphrase, and an RSA 4096 PKCS#1 key of 3243
bytes (over Windows Credential Manager's 2560) without a comment. A kept key-file passphrase whose fingerprint holds
`/` and `+`. Eleven known hosts (ed25519, ECDSA P-256 and P-384, RSA; two key types for one host). Fifteen settings:
`device_id`, `language`, `local_machine_seeded`, `theme_mode`, `custom_theme` (an object), doubles (`312.5`, and
`400.0` stored as such), booleans, an enum, a string list, `usage_reminders` with JSON nulls inside, and
`project_collapsed:<machine>:<cwd>` true and false, one with a non-ASCII folder. Three read markers (UTC, `…Z`). Three
pins inserted in another order than their `pinnedAt`, one without title and first message, one with an emoji title
and a two-line first message. Times have microseconds, whole milliseconds and whole seconds, fall on both sides of the
EU's switch to summer time and in winter and summer (`+01:00`/`+02:00` in the v3 file, `-05:00`/`-04:00` in v1/v2),
and one local date differs from its UTC date. The Flutter app adds this computer only on desktops; the seed writes the
same set on every platform.

## expected.json

Each `store.*` document as `ui/src/app/database/tables.ts` reads it: times in epoch ms (the stored microseconds cut
to whole milliseconds), jumps inline in dial order, a NULL column an absent field, `tailscale` a boolean, settings
values JSON-decoded. Pins are in `pinnedAt` order; every other document lists its rows in the order the seed stored
them (the table's rowid order), which carries no meaning. Secrets are keyed by the names
`ui/src/app/services/secret_store.ts` uses, the Flutter app's own. The documents and secrets are the same on every
platform and in every time zone.

## Build

```sh
harness/flutter-seed/build.sh <macos|ios-simulator|android|linux|windows> [--out <dir>]
```

It extracts commit `359d920` (`git archive`) into `$TMPDIR/flutter-seed-src/<platform>`, adds the two Dart files and
builds with the store identity `com.edde746.ompanion`. The last line printed is the artifact: `ompanion.app` (macOS,
debug, which leaves out Sparkle), `Runner.app` (iOS simulator), `app-debug.apk` (Android, debug key; `run-as` needs a
debuggable app), `bundle/` (Linux), `Release/` (Windows), under `$TMPDIR/flutter-seed/<platform>` unless `--out`.
Flutter is `/Users/edde/Documents/flutter/bin/flutter` where it exists, else `flutter` on PATH (3.47.1).

- macOS, iOS simulator: Xcode and this Mac's "Apple Development" identity (team G88U5B5783). The macOS keychain lets
  the web app read the seed's items without a prompt only when both are signed by the same identity.
- Android: the Android SDK and JDK 21.
- Linux (Ubuntu 24.04): `clang cmake ninja-build pkg-config libgtk-3-dev liblzma-dev libstdc++-12-dev
  libsecret-1-dev`; in a bare container also `git curl unzip xz-utils ca-certificates` for Flutter.
- Windows: Visual Studio 2022 with "Desktop development with C++", Git Bash (GitHub's `windows-latest` has both).

## Run

Never on the developer's Mac or phone: the seed is the store app's identity and writes where the user's app keeps its
data.

- **macOS, iOS simulator, Pixel**: `harness/flutter-seed/run.sh <macos|ios-simulator|android> [--db <file>]` copies
  the build to studio and, in one devpool lease, checks that no `com.edde746.ompanion` app or data is there (stops if
  there is), runs the seed, lists the database's rows and the secrets, and removes everything again. `--db` keeps a
  copy of the database. Inside the lease:
  - macOS (`--need host:studio --need pool:studio-gui`): `open -n -W -F --stdout seed.txt ompanion.app`, a launch in
    the GUI session; a binary started from SSH cannot use the login keychain.
  - iOS (`--need 'ios-sim:iPhone-17 machine=studio runtime=27.0'`): `xcrun simctl install <udid> Runner.app`, then
    `xcrun simctl launch --console-pty <udid> com.edde746.ompanion` until it prints `SEEDED`, then `simctl terminate`.
  - Android (`--need device:pixel`, adb on air.local): `adb install app-debug.apk`,
    `adb shell am start -n com.edde746.ompanion/.MainActivity`, wait for `SEEDED` in `adb logcat -s flutter`, then
    `am force-stop`; `adb shell run-as com.edde746.ompanion ls files` shows `ompanion.sqlite`.
- **Linux** (CI runner, or a container on a Linux host): `harness/flutter-seed/run-host.sh linux <bundle dir>`. It
  needs `xvfb xauth dbus gnome-keyring libsecret-tools sqlite3`: without a session bus it starts one with an unlocked
  gnome-keyring, and Xvfb without a display.
- **Windows** (CI runner, Git Bash): `harness/flutter-seed/run-host.sh windows <Release dir>`.

## Where it writes, and cleaning up

`run.sh` and `run-host.sh` clean up themselves. By hand, per platform:

| Platform | Database | Secrets | Remove |
|---|---|---|---|
| macOS | `~/Library/Application Support/com.edde746.ompanion/ompanion.sqlite` | login keychain, generic passwords of service `flutter_secure_storage_service`, account = key | `touch` `seed-clean` in the folder and open the app again (`CLEANED 7`), delete the folder, `lsregister -u ompanion.app`, the app; `run.sh` also puts the `com.edde746.ompanion` defaults back as it found them |
| iOS simulator | `<data container>/Library/Application Support/ompanion.sqlite` | keychain group `G88U5B5783.com.edde746.ompanion`, service `flutter_secure_storage_service` | `seed-clean` in that folder and launch again (keychain items outlive the app), then `xcrun simctl uninstall <udid> com.edde746.ompanion` |
| Android | `files/ompanion.sqlite` | `shared_prefs/FlutterSecureStorage.xml`, its key in `FlutterSecureKeyStorage.xml` and Keystore alias `com.edde746.ompanion.FlutterSecureStoragePluginKeyOAEP` | `adb uninstall com.edde746.ompanion` |
| Linux | `${XDG_DATA_HOME:-~/.local/share}/com.edde746.ompanion/ompanion.sqlite` | one libsecret item, attribute `account=com.edde746.ompanion.secureStorage`, holding all keys as JSON | `secret-tool clear account com.edde746.ompanion.secureStorage`, delete the folder |
| Windows | `%APPDATA%\com.edde746\ompanion\ompanion.sqlite` | `flutter_secure_storage.dat` in the same folder (DPAPI) | delete the folder |
