# Third-party licences

Recorded 2026-11-02 from the builds of `VERSION` 1.2.1+4: the page (`ui/dist`), the macOS and iOS simulator apps, the
Android debug APK, and the generator's Linux and Windows output (below says how each was made).

**Result: no GPL, LGPL or AGPL third-party code and no code without a known licence ships in any build.** The two
MPL-2.0 Shiki grammars (`hcl`, `terraform`) ship; MPL-2.0 is per-file copyleft, satisfied because ompanion's source,
those files included, is public. Two grammars are left out of the bundle: `nginx` (GPL-3.0) and `glsl` (no licence
anywhere upstream); fences in those languages show as plain text. The build itself enforces both rules (Method).

The in-app list (Settings > About > Open-source licenses) shows every entry below with its licence text. It is complete
for what each build bundles; what the operating system provides (system frameworks, Android System WebView, the
WebView2 Runtime, GTK and WebKitGTK on Linux) is not bundled and not listed.

## Method

One file, `licenses.json` beside the page's `index.html`, in three groups; the page shows the groups that apply to the
platform it runs on.

| Group | Written by | From |
|---|---|---|
| `page` (Interface) | `ui/vite.config.ts`, `bundledLicenses`, on every `vite build` | every npm package the bundle holds a module or an asset of (the asset sources catch fonts a stylesheet `@import`s): `name`, `version`, `license` and the `LICENSE*`/`COPYING*` file of its `package.json` directory; every Shiki grammar in the bundle (`@shikijs/langs/<grammar>`) with its upstream licence from the NOTICE of `tm-grammars` 1.32.22, the grammar record Shiki 4.5.0 was built from (its `pnpm-lock.yaml`); `ui/licenses/index.json`, which supplies the licence a package lacks and lists third-party code and fonts that are no package of their own |
| `core` (Core) | `core/cmd/licenses`, which each shell's build script runs on the copy of the page it bundles | `go list -deps -json` of what the shell links (`./ompcore` and gomobile's `golang.org/x/mobile/bind/seq` for Apple and Android, `./capi` for Linux and Windows) with `GOOS` set to the target, each module's licence files from the module cache, and `$GOROOT/LICENSE` for the standard library of the Go that builds it |
| `platform` (Platform) | `core/cmd/licenses` | Apple: the Swift package products each target of `shells/apple/project.yml` links, followed through `swift package dump-package` of every resolved package (platform conditions applied) to the packages they need, with each one's licence files from the checkout `xcodebuild -resolvePackageDependencies` made; Android: the release runtime classpath (`licenseInputs` in `shells/android/app/build.gradle.kts`), each library's POM licence (its parent's where it has none) and the licence files inside its AAR or JAR, including the `third_party_licenses.json`/`.txt` pairs Google's libraries carry; Windows: the WebView2 NuGet package's `.nuspec` and licence file, and the licence files llvm-mingw installs for the runtimes `-static` links in |

Licence ids come from the package's own metadata (npm `license`, POM `<license>`, tm-grammars' SPDX line); for Go
modules, Swift packages and notices `core/cmd/licenses` names the licence whose wording comes first in the text. A
library whose POM names the Apache License 2.0 and whose package has no copy gets apache.org's text
(`core/cmd/licenses/apache-2.0.txt`); a BSD/MIT/ISC library without its notice fails the build until its text is in
`shells/android/licenses/<group>/<artifact>.txt`. Google's Play services libraries list their licence as Google's
oss-licenses plugin shows it, the POM's licence name and URL (`LicensesTask.addLicensesFromPom` writes the POM's
`<url>` as the text), plus each library's embedded `third_party_licenses` entries (`addEmbeddedLicenses`).

Both writers fail the build on an entry without a licence text and on a GPL-family licence id; the vite plugin also on
an npm package or grammar without a licence id.

## Per target

Counts are entries in the shipped `licenses.json`.

| Target | Interface | Core | Platform | Total | Source of the count |
|---|---|---|---|---|---|
| macOS (direct) | 116 | 7 | 1 | 124 | `ompanion.app/Contents/Resources/ui/licenses.json` of `shells/apple/build.sh`, built on this Mac (studio has no XcodeGen) |
| iOS | 116 | 6 | 6 | 128 | the same file in the iOS simulator app; macOS-only entries are marked and hidden there |
| Android | 116 | 6 | 105 | 227 | `assets/ui/licenses.json` of `shells/android/build.sh`'s `app-debug.apk`, built on studio |
| Linux zip and Flatpak | 116 | 6 | 0 | 122 | `go run ./cmd/licenses -target linux` on studio's `ui/dist` |
| Windows (zip, MSIX) | 116 | 6 | 3 | 125 | studio: the generator with the WebView2 package (1 entry); the two llvm-mingw notices are added in the Docker build [UNVERIFIED: no Docker on studio] |

### Interface (every target): 116

49 npm packages, 64 Shiki grammars, 3 vendored entries. Licences: MIT 103, Apache-2.0 4, OFL-1.1 2, MPL-2.0 2,
TextMate bundle licence 2, BSD-3-Clause 1, BSD-2-Clause 1, ISC 1.

- npm: CodeMirror, Lezer, Shiki, markdown-it, KaTeX, xterm.js, SolidJS and their dependencies (MIT, except `entities`
  BSD-2-Clause, `yaml` ISC, `@material-symbols/svg-400` Apache-2.0); `@fontsource-variable/jetbrains-mono` (OFL-1.1),
  now listed because its fonts are counted.
- `solid-js` and `@solidjs/web` 2.0.0-rc.20 ship without a licence file: the MIT `LICENSE` sits at the root of the
  `solidjs/solid` monorepo, and npm packs only `packages/solid` and `packages/web`. `ui/licenses/solid-js.txt` is that
  file at tag `solid-js@2.0.0-rc.20`.
- Vendored: KaTeX's fonts (OFL-1.1: the name tables of all 20 fonts say "Copyright (c) 2009-2010, Design Science, Inc.
  … Copyright (c) 2014-2018 Khan Academy … licensed under the SIL Open Font License, Version 1.1"; the `katex` package
  itself is MIT), the `auto_awesome` glyph from google/material-design-icons (Apache-2.0), and `src/app/hct.ts`, a port
  of Google's material_color_utilities 0.13.0 (Apache-2.0).

### Grammars

The 64 shipped grammars and their licences, from tm-grammars' NOTICE unless `ui/licenses/index.json` says otherwise:

| Grammars | Licence | Evidence |
|---|---|---|
| 58, incl. the sub-grammars `cpp-macro` (microsoft/vscode), `markdown-nix` (nix-community/vscode-nix-ide), `markdown-vue`, `vue-directives`, `vue-interpolations`, `vue-sfc-style-variable-injection` (vuejs/language-tools) | MIT | NOTICE `Files:` lines name each, `SPDX: MIT` |
| `haskell` | BSD-3-Clause | NOTICE |
| `hcl`, `terraform` (hashicorp/syntax) | MPL-2.0 | NOTICE: "Copyright IBM Corp. 2026 / Mozilla Public License Version 2.0" |
| `elixir` (elixir-editors/elixir-tmbundle) | Apache-2.0 | its `LICENSE` at commit 43c8cd9: "Copyright 2012 Plataformatec. Licensed under the Apache License, Version 2.0"; GitHub and tm-grammars record `NOASSERTION` because the file is that notice, not the licence text; `ui/licenses/elixir-tmbundle.txt` is the notice and the licence |
| `toml`, `yaml` (textmate/toml.tmbundle, textmate/yaml.tmbundle) | TextMate bundle licence | each README.mdown at the commit tm-grammars took the grammar from: "files in this repository fall under the following license: Permission to copy, use, modify, sell and distribute this software is granted. This software is provided "as is" without express or implied warranty…"; neither grammar file carries a licence of its own |

Left out:

| Grammar | Licence | Evidence | How |
|---|---|---|---|
| `nginx` (hangxingliu/vscode-nginx-conf-hint) | GPL-3.0 | NOTICE `SPDX: GPL-3.0`; GitHub API `spdx_id: GPL-3.0` | not in `highlighter.ts` |
| `glsl` (polym0rph/GLSL.tmbundle) | none | the repository at 6998d3b holds Commands, Preferences, README.textile, Snippets, Syntaxes, info.plist; none states a licence, GitHub API `license: null`, tm-grammars records none | `cpp` imports it for shader strings: `withoutGrammars` in `vite.config.ts` replaces the module with an empty one and `highlighter.ts` loads C++ without it |

A test (`highlighter.test.ts`) checks that `nginx` and `glsl` fences stay plain and C++ still highlights. Absence in
the builds: no `nginx`/`glsl` chunk and no chunk with a grammar whose `scopeName` is `source.glsl` or `source.nginx` in
`ui/dist/assets/`, in the macOS and iOS simulator apps' `ui/assets/`, or in the APK's `assets/ui/assets/` (grep of
each chunk); the only remaining `source.glsl` strings are two `include` references inside the C++ grammar, which match
nothing.

### Core

| Module | Licence | macOS | iOS | Android | Linux | Windows |
|---|---|---|---|---|---|---|
| Go standard library (the building Go: 1.26.2 on this Mac, 1.27.3 on studio, the Docker images' on Linux/Windows) | BSD-3-Clause | ✓ | ✓ | ✓ | ✓ | ✓ |
| golang.org/x/crypto v0.58.0 | BSD-3-Clause | ✓ | ✓ | ✓ | ✓ | ✓ |
| golang.org/x/sys v0.49.0 | BSD-3-Clause | ✓ | ✓ | ✓ | ✓ | ✓ |
| github.com/pkg/sftp v1.13.12 | BSD-2-Clause | ✓ | ✓ | ✓ | ✓ | ✓ |
| github.com/kr/fs v0.1.0 | BSD-3-Clause | ✓ | ✓ | ✓ | ✓ | ✓ |
| golang.org/x/mobile v0.0.0-20261011034528-197770444867 (gomobile's runtime) | BSD-3-Clause | ✓ | ✓ | ✓ | | |
| github.com/creack/pty v1.1.24 | MIT | ✓ | | | ✓ | |
| github.com/charmbracelet/x/conpty v0.2.0 | MIT | | | | | ✓ |

`github.com/coder/websocket` is in `core/go.mod` for the dev bridge only; no shipped build links it.

### Platform

- **macOS:** Sparkle 2.10.0 (MIT; its LICENSE also carries bsdiff/bspatch BSD-2-Clause, sais MIT, ed25519 zlib and
  SUSignatureVerifier BSD-2-Clause), an embedded framework (`otool -L`: `@rpath/Sparkle.framework/Versions/B/Sparkle`).
- **iOS:** firebase-ios-sdk 12.19.2, GoogleUtilities 8.1.5, GoogleDataTransport 10.1.1, promises 2.4.1 (Apache-2.0),
  GoogleUtilities/third_party/IsAppEncrypted (MIT), nanopb 2.30910.1 (Zlib), linked statically; the walk matches the
  object files of the archive's `ompanion.LinkFileList`. Resolved but not linked, so not listed: abseil-cpp-binary,
  app-check, google-ads-on-device-conversion-ios-sdk, GoogleAppMeasurement, grpc-binary, gtm-session-fetcher,
  interop-ios-for-google-sdks, leveldb. The Notification Service Extension links no package.
- **Android:** 74 Maven libraries (Apache-2.0 66; Android Software Development Kit License 7: play-services-base,
  -basement, -cloud-messaging, -stats, -tasks, firebase-iid-interop, firebase-measurement-connector; BSD-3-Clause 1:
  androidx.datastore:datastore-preferences-external-protobuf, a repackaged protobuf-javalite 4.28, whose notice is
  protobuf's v28.2 LICENSE in `shells/android/licenses/`) and 31 notices embedded in Google's AARs (Apache-2.0 27,
  MIT 2, BSD-3-Clause 2: Kotlin, Guava, Dagger, J2ObjC, JSR 305, protobuf, …). The release build is R8-minified, so
  this is an upper bound. The Play services libraries are proprietary (not open source, not copyleft).
- **Windows:** Microsoft.Web.WebView2 1.0.4314.35, whose `WebView2Loader.dll` ships next to the exe (BSD-3-Clause
  style, Microsoft); LLVM 23.1.4's libc++, libc++abi, libunwind and compiler-rt (Apache-2.0 WITH LLVM-exception, from
  `/opt/llvm-mingw/LICENSE.TXT`): libc++, libc++abi and libunwind in `ompanion.exe`, compiler-rt builtins in both
  binaries; the mingw-w64 runtime (`COPYING.MinGW-w64-runtime.txt`, the file mingw-w64 asks a statically linked
  program to ship: ZPL-2.1 and BSD/ISC/MIT notices), in both. winpthreads is linked into neither (no `pthread_*`
  reference, no matching member, no `libwinpthread-1.dll` import).
- **Linux:** nothing. The zip holds `ompanion`, `libompcore.so`, `ui/` and the icon; the Flatpak adds `release-tty`
  (ompanion's own). Both link GTK 4, WebKitGTK 6, libsoup 3, GLib, libsecret, libstdc++ and glibc dynamically: the zip
  from the system, the Flatpak from the GNOME 51 runtime that `flatpak install` fetches from Flathub
  (`flatpak build-bundle --runtime-repo`), not from the bundle.

## Copyleft check

Every licence id in every target's `licenses.json` is in the tables above: no GPL, LGPL or AGPL id, and the builds fail
on one. A scan of every licence *text* for "GNU … General Public License" finds two, both notices Google ships inside
its Play services AARs for components that are not in the APK:

| Text | What it covers | In the APK? |
|---|---|---|
| "Kotlin": the Kotlin distribution's third-party file, "Files: kotlinc/lib/trove4j.jar … GNU LESSER GENERAL PUBLIC LICENSE Version 2.1" | trove4j, a library of the Kotlin compiler | no: 0 `Lgnu/trove/` classes in the debug APK's five dex files (every library's classes, before R8) |
| "J2ObjC": J2ObjC's licence bundle, "GNU General Public License Version 2" (with the Classpath Exception, for its JRE emulation) | J2ObjC's Java runtime for iOS | no: 0 `Lcom/google/j2objc/` classes |

Per target:

- **Page (every build):** npm licence ids and grammar records as above; `nginx` and `glsl` absent from every bundle
  (Grammars).
- **Core:** BSD and MIT modules only (`go list -deps` per target).
- **Apple:** Apache-2.0, MIT and Zlib packages; no package outside the linked set.
- **Android:** no GPL-family POM licence; the two GNU texts above are notices for classes the APK does not contain.
- **Windows:** no GPL or LGPL code linked. Every GPL/LGPL match in mingw-w64's `mingw-w64-crt` and `winpthreads`
  sources is a build script, a test, the ZPL's "GPL compatible" sentence, or the profiling runtime (`gcrt*.o`,
  `libgmon.a`) that only `-pg` links (not used; no match in the binaries).
- **Linux:** the LGPL system libraries are linked dynamically and not bundled.

Risks, not violations:

- **Windows: data from Wine-derived headers.** mingw-w64's `uuid.o` (linked through `-luuid`) holds 692 GUIDs and 1067
  PROPERTYKEYs, and `notifications.cpp` compiles 8 WinRT IIDs and interface layouts, from headers and IDLs that
  mingw-w64 imported from Wine under LGPL-2.1. LGPL-2.1 §5: object code that uses "only numerical parameters, data
  structure layouts and accessors, and small macros and small inline functions (ten lines or less in length)" is
  unrestricted [INFERENCE: that covers constants and layouts]. Removing the `uuid.o` part means defining the six GUIDs
  the shell uses itself and dropping `-luuid`.
- **Linux and the GCC-built core:** a dynamically linked program also carries glibc's start files (LGPL with an
  exception for linking them) and parts of libgcc (GPL with the GCC Runtime Library Exception), whose exceptions allow
  any licence for the program [INFERENCE: standard GCC linking, not inspected in our binaries].
- **Grammar records:** tm-grammars' NOTICE holds each upstream's licence file as of its default branch when tm-grammars
  was generated, not at the grammar's commit. `tm-grammars` must stay at the version the bundled `@shikijs/langs` was
  built from (Shiki's lock file); a Shiki update needs it updated in the same change.

Not legal advice.

## Checking again

The build checks itself; this lists what a build ships and flags any GNU text:

```sh
# a licenses.json from any build (ui/dist, build/apple/ui, build/android/ui-*, build/linux-*/ui, build/windows-*/ui)
python3 - build/apple/ui/licenses.json <<'PY'
import collections, json, re, sys
data = json.load(open(sys.argv[1]))
for group in data['groups']:
    print(group['id'], len(group['packages']), dict(collections.Counter(p['license'] for p in group['packages'])))
for i, text in enumerate(data['texts']):
    if re.search(r'GNU (AFFERO |LESSER |LIBRARY )?GENERAL PUBLIC LICENSE', text, re.I):
        print('GNU text:', sorted({p['name'] for g in data['groups'] for p in g['packages'] if p['text'] == i}))
PY
```
