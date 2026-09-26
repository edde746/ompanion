# Third-party licences

Every package the two lock files resolve — `pubspec.lock` (the app) and `packages/omp_core/pubspec.lock` — with the
licence file in its `~/.pub-cache/hosted/pub.dev/<name>-<version>/` directory read and classified by its own text,
not by package metadata. Recorded 2026-09-26, after the terminal moved from `xterm3` (AGPL-3.0) to `xterm2` (MIT).

**Result: no GPL or AGPL third-party code ships in any build, and no store build needs a licence review beyond the
project's own GPLv3.** The one copyleft package, `dbus` (MPL-2.0), is reached only by desktop drag-and-drop and the
Linux file picker, and is not in the iOS app binary (checked, below).

## Method

For every hosted entry: read `LICENSE`, `LICENSE.md`, `LICENSE.txt`, `COPYING`, `LICENCE` or any other
`LICENSE*`/`COPYING*` file in the package directory in the pub cache, then match the body against the licence texts
(GNU GPL/Affero/Lesser, Mozilla, Apache, MIT, BSD, ISC, Zlib, Unlicense, Creative Commons, BSL). Bodies, not names:
the MPL-2.0 text *mentions* the GPL, the LGPL and the AGPL in its own §1.12 definition of "Secondary License",
which is not AGPL code and not a copyleft claim by the package. `source: sdk` and `source: path` entries have no
licence file of their own (they are the Flutter SDK and `packages/omp_core`).

## Result

183 resolved packages, by what their licence file is:

| Licence | Packages | Ships in |
|---|---|---|
| BSD (3-clause, mostly Flutter/Google packages) | 119 | every target |
| MIT | 44 | every target |
| Apache-2.0 | 8 | every target |
| MIT + BSD (`node_preamble` 2.0.2, dev-only) | 1 | test runs only |
| Apache-2.0 + MIT + BSD (`sqlcipher_flutter_libs` 0.7.0+eol: wrapper MIT, OpenSSL Apache-2.0, SQLCipher Zetetic BSD) | 1 | every target |
| MPL-2.0 (`dbus` 0.7.15) | 1 | desktop only, see below |
| Flutter SDK packages (`flutter`, `sky_engine`, …, BSD-3) and `packages/omp_core` | 9 | every target |
| **GPL, LGPL or AGPL code** | **0** | — |

Notable packages: `xterm2` 5.2.0 and `flutter_pty2` 2.0.0 (MIT, the terminal), `dartssh2` 4.1.0 (MIT, SSH),
`drift` 2.35.0, `slang`, `provider`, `re_editor`, `re_highlight`, `gpt_markdown` (MIT/BSD/Apache, all permissive).

`companion/` adds nothing: its `package.json` has only `devDependencies` (TypeScript and the `@oh-my-pi/*` type
packages), and the bundle marks `@oh-my-pi/*` external, so no npm code is vendored into the app.

## `dbus` (MPL-2.0)

`dbus` is a pure-Dart client with no platform implementation. Two packages depend on it, both for desktop:

- `desktop_drop` 0.8.4 → `lib/src/channel.dart`, which resolves XDG portal file-transfer keys with `DBusClient`
  for the Linux `performOperation_portal` path. `desktop_drop` declares macOS, Windows, Linux, Android and web,
  not iOS.
- `file_picker_linux` 2.0.0 → the Linux implementation of `file_picker`.

So the MPL-2.0 code is on the Linux desktop path. Checked for the store-critical case anyway: two release builds
(`flutter build ios --release --no-codesign`, `flutter build apk --release --dart-define=OMPANION_CHANNEL=play`)
contain none of the dbus or desktop-portal strings, while strings from the same programs that *are* in them are
present:

| Literal | Source | iOS `App.framework/App` | Android `lib/arm64-v8a/libapp.so` |
|---|---|---|---|
| `OMPANION_TERMINAL_READY` | ompanion, `lib/terminal/shell_launch.dart` | present | present |
| `SSH-2.0-` | dartssh2 | present | present |
| `bracketedPaste` | xterm2 | present | present |
| `DBUS_SESSION_BUS_ADDRESS`, `org.freedesktop.DBus` | dbus | absent | absent |
| `desktop_drop` (method channel name) | desktop_drop | absent | absent |
| `performOperation_macos`, `apple-bookmark` | desktop_drop | absent | absent |

The mechanism — the widget that builds `DropTarget` is behind a desktop `Platform` check, and the AOT tree shaker
drops the rest — is [INFERENCE]; what is measured is the string table of each built store binary. MPL-2.0 is
per-file copyleft and has no equivalent of GPLv3 §6/§10, so it would not conflict with App Store terms either way;
the check is recorded because "no GPL/AGPL third-party code" is only worth stating if the one copyleft package is
also accounted for.

## What this means for the stores

- Nothing in the iOS or Android build is GPL or AGPL except ompanion itself, which is GPLv3 with the additional
  permission in `LICENSE-EXCEPTION.md`. See `docs/PLAN.md` R11 for why that exception is required and
  <https://www.gnu.org/licenses/gpl-faq.en.html> for the FSF's position that only copyright holders can grant one.
- The wording of that exception follows the precedent of other GPL projects shipping on the App Store (Signal's
  `libsignal-protocol-c` exception, <https://signal.org/blog/license-update/>): grant conveyance through the store,
  keep every other GPL duty, keep the Corresponding Source available, and let downstream remove the permission
  (GPLv3 §7).
- `xterm3`'s AGPL-3.0 could not have been covered by that exception, which is why the terminal is `xterm2` in every
  build rather than only in store builds (`docs/research/ui-libraries.md` §4).
- Not legal advice. Re-run the scan after any dependency change:

```sh
# every hosted package's licence body, with the copyleft ones flagged (needs pyyaml: pip install pyyaml)
python3 - <<'PY'
import os, re, yaml
cache = os.path.expanduser('~/.pub-cache/hosted/pub.dev')
for lock in ['pubspec.lock', 'packages/omp_core/pubspec.lock']:
    for name, spec in sorted(yaml.safe_load(open(lock))['packages'].items()):
        if spec.get('source') != 'hosted':
            continue
        base = os.path.join(cache, f"{name}-{spec['version']}")
        body = ''
        for f in sorted(os.listdir(base)):
            if f.upper().startswith(('LICENSE', 'LICENCE', 'COPYING')):
                body += open(os.path.join(base, f), encoding='utf-8', errors='replace').read()
        flags = [k for k in ['GNU General Public', 'GNU Affero', 'GNU Lesser', 'Mozilla Public'] if k in body]
        if flags:
            print(name, spec['version'], flags)
PY
```
