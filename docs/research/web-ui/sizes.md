# Sizes: Flutter app vs web app

Download and installed size of the shipped Flutter app (GitHub release 1.2.1) and of the web app, packaged the same
way, per platform; then where the bytes go in each. `sizes.sh` recomputes every Flutter and web app number below from
the artifacts (measured 2026-11-01). The early spike rows are the prototype this app grew from, measured the same day
before the full app was built; their builds are gone, so `sizes.sh` no longer makes them. MB is 10^6 bytes. `sizes.sh`
and the Flutter builds it read (`bench/flutter/`) were removed, never committed, with the Flutter app.

## What the apps are

- **Flutter app 1.2.1** is the shipped product: omp sessions over SSH (dartssh2, jump hosts, keys, known_hosts) and on
  this computer (flutter_pty2), the transcript (gpt_markdown, KaTeX math through flutter_math_fork, code highlighting),
  a terminal (xterm2), a code editor (re_editor), a drift database over SQLite, secure storage, local notifications and
  push (Firebase on Android, a notification service extension on iOS), Sparkle updates (macOS), file picking, drag and
  drop, window management and translations. It carries its own engine and renderer.
- **The web app** is the same app rebuilt (`docs/app.md`): its screens and its Dart core in TypeScript (Solid,
  markdown-it, KaTeX, Shiki, xterm.js, CodeMirror 6) on a Go core (SSH with jump chains, SFTP, PTYs, exec, keys,
  forwards, the app's documents), in thin shells over the system webview (WKWebView, Android System WebView,
  WebKitGTK 6, WebView2), which its packages do not contain. The builds measured had no push and no self-updater.
- **The early spike** was a prototype on the same core functions: a session view, a terminal, markdown and agent
  HTML, without database, editor, settings or the app's screens.

The `flutter create` hello world is the floor on the Flutter side.

## Summary

- The web app downloads 1.7–3.6× smaller and installs 1.9–3.4× smaller than Flutter 1.2.1: arm64 macOS 5.5 vs
  14.4 MB download, 16.9 vs 42.8 MB installed; iOS 9.2 vs 15.9 MB, 19.5 vs 37.7 MB; Android arm64 10.1 vs 34.8 MB
  (Flutter at HEAD); Linux 5.2 vs 17.1 MB, 15.4 vs 42.6 MB; Windows 5.5 vs 19.9 MB, 15.7 vs 47.4 MB.
- Against an empty Flutter app it is smaller on macOS (arm64: 5.5 / 16.9 MB vs 6.1 / 19.5 MB) and Android arm64
  (10.1 vs 15.5 MB), larger on iOS (9.2 / 19.5 MB vs 6.2 / 14.4 MB), where 4.2 MB of it is the compiled app icon
  (`Assets.car`).
- From the early spike to the full app, the Go core grew from 4.5–5.5 to 7.3–8.9 MB and `ui/` code from 1.9 to
  5.8 MB; the web app is 1.7–2.5× the spike installed.
- In the web app the Go core is the largest part (38–82%); `ui/` code is 5.8 MB, 1.3 MB as stored (compressed) in the
  APK. In the Flutter app, Dart AOT code (19–21 MB) and the engine are 81–91% of the bytes.

## Download and installed size

### macOS

|Build|Architectures|Download (MB)|Installed (MB)|
|---|---|--:|--:|
|Flutter 1.2.1, release dmg (ULMO)|arm64 x86_64|28.0|83.3|
|Flutter 1.2.1, the same app repacked here (ULMO)|arm64 x86_64|28.1|83.3|
|Web app, dmg (ULMO)|arm64 x86_64|9.2|26.7|
|Early spike, dmg (ULMO)|arm64 x86_64|4.2|13.9|
|Flutter 1.2.1, the same app repacked (UDZO)|arm64 x86_64|39.5|83.3|
|Web app, dmg (UDZO)|arm64 x86_64|12.1|26.7|
|Early spike, dmg (UDZO)|arm64 x86_64|5.9|13.9|
|Flutter 1.2.1, thinned, dmg (ULMO)|arm64|14.4|42.8|
|Web app, thinned, dmg (ULMO)|arm64|5.5|16.9|
|Early spike, thinned, dmg (ULMO)|arm64|2.4|7.9|
|Flutter hello world (`flutter create`), dmg (ULMO)|arm64 x86_64|12.4|38.5|
|Flutter hello world, thinned, dmg (ULMO)|arm64|6.1|19.5|

- The release dmg is ULMO (LZMA), so the like-for-like rows are ULMO; UDZO (zlib) is shown as well.
- `hdiutil` does not produce the same bytes every run: eight repacks of the Flutter app on 2026-11-01 gave
  27.9–28.7 MB (the table shows the most common, 28.1).
- The release app is signed and notarized, the web app ad-hoc signed. The thinned copies' signatures no longer match
  (sizes only).

### iOS

|Build|Architectures|Download (MB)|Installed (MB)|
|---|---|--:|--:|
|Flutter 1.2.1, release ipa|arm64|15.9|37.7|
|Web app, ipa|arm64|9.2|19.5|
|Early spike, ipa|arm64|2.8|7.8|
|Flutter hello world (`flutter create`)|arm64|6.2|14.4|

All are unsigned, as the release ships its ipa (a sideloading tool signs it). App Store thinning and encryption are
not measured.

### Android

|Build|ABIs|Download (MB)|Installed (MB)|
|---|---|--:|--:|
|Flutter 1.2.1, release APK|arm64-v8a armeabi-v7a x86_64|98.7|98.7|
|Flutter app at HEAD, release APK (built here)|arm64-v8a armeabi-v7a x86_64|101.7|101.7|
|Web app, release APK|arm64-v8a armeabi-v7a x86 x86_64|35.5|35.5|
|Early spike, release APK|arm64-v8a armeabi-v7a x86 x86_64|21.8|21.8|
|Flutter app at HEAD, `--split-per-abi` arm64 APK (built here)|arm64-v8a|34.8|34.8|
|Web app, arm64 APK|arm64-v8a|10.1|10.1|
|Early spike, arm64 APK|arm64-v8a|5.8|5.8|
|Flutter hello world (`flutter create`), arm64 APK|arm64-v8a|15.5|15.5|

- The release has no per-ABI APK, so the arm64 Flutter APK is built from HEAD (`359d920`, Flutter 3.47.1). HEAD's
  universal APK is 3.0 MB larger than 1.2.1's, so the arm64 row overstates 1.2.1 by up to that much.
- Download is the APK file, as the GitHub release serves it. Play would serve compressed, per-device splits (not
  measured).
- Every native library in these APKs is stored uncompressed, so Android maps it from the APK and the installed size
  is the APK. The code ART compiles after install is not counted.
- The web APKs are R8-minified release builds, debug-key signed.

### Linux

|Build|Architectures|Download (MB)|Installed (MB)|
|---|---|--:|--:|
|Flutter 1.2.1, release zip|x86-64|17.1|42.6|
|Flutter 1.2.1, release Flatpak (app only)|x86-64|12.5|42.5|
|Web app, zip|x86-64|5.2|15.4|
|Early spike, zip|x86-64|2.9|7.7|

- The Flatpak's installed size is flatpak's own (`xa.installed-size`). It does not count the org.freedesktop.Platform
  26.08 runtime the app needs, which other Flatpaks share.
- Both zips rely on system libraries: GTK 3 for Flutter; GTK 4 and WebKitGTK 6 for the web app.

### Windows

|Build|Architectures|Download (MB)|Installed (MB)|
|---|---|--:|--:|
|Flutter 1.2.1, release zip|x86-64|19.9|47.4|
|Web app, zip|x86-64|5.5|15.7|
|Early spike, zip|x86-64|3.2|8.2|
|Flutter 1.2.1, the same files zipped here|x86-64|19.5|47.4|

The release zips with PowerShell's `Compress-Archive`; the web app's zip is `zip -qr`, which gives 19.5 MB for the
Flutter files. The web app needs the WebView2 runtime, which it does not ship. The Windows build measured had never
run.

## Where the bytes go

Installed bytes per part (MB); APK rows count the bytes as stored in the APK.

### Flutter app

|Build|Dart AOT|Engine|Assets|Fonts|Plugins|Runner|Other|Total|
|---|--:|--:|--:|--:|--:|--:|--:|--:|
|macOS, thinned to arm64|20.11|15.49|0.29|1.15|3.51|0.84|1.44|42.83|
|iOS|19.95|10.42|0.28|1.15|2.04|2.36|1.48|37.67|
|Android arm64 APK (HEAD, `--split-per-abi`)|19.27|11.75|0.18|0.62|2.64|0.00|0.31|34.76|
|Linux x64|20.61|18.08|0.31|1.15|2.37|0.02|0.01|42.55|
|Windows x64|21.12|22.14|0.31|1.15|2.59|0.11|0.00|47.42|
|Hello world, macOS, thinned to arm64|3.41|15.47|0.12|0.26|0.00|0.07|0.20|19.53|
|Hello world, iOS|3.45|10.40|0.11|0.26|0.00|0.09|0.08|14.39|
|Hello world, Android arm64 APK|3.21|11.75|0.11|0.12|0.24|0.00|0.07|15.49|

- **Dart AOT:** `App.framework`'s binary, `libapp.so`, `data/app.so`.
- **Engine:** `FlutterMacOS.framework` / `Flutter.framework` (with `icudtl.dat`), `libflutter.so`,
  `libflutter_linux_gtk.so` and `flutter_windows.dll` with `data/icudtl.dat`.
- **Fonts:** `.ttf`/`.otf` in `flutter_assets` (Material Symbols, JetBrains Mono, KaTeX). **Assets:** the rest of
  `flutter_assets` (licenses, shaders, `ompx.js`).
- **Plugins:** every other framework or native library (SQLite, Sparkle, flutter_pty2, plugin DLLs) and, on Android,
  the dex: Flutter's Java embedding, Firebase and the plugins' Java and Kotlin code.
- **Runner:** the app's executable. **Other:** icons (`Assets.car`), plists, signatures, Android resources, the iOS
  notification extension, zip headers and the APK signing block.

### Web app

|Build|Go core|`ui/` code|`ui/` fonts|Bench content|Shell|Other|Total|
|---|--:|--:|--:|--:|--:|--:|--:|
|macOS, thinned to arm64|7.39|5.83|0.35|0.12|1.73|1.50|16.92|
|iOS|7.32|5.83|0.35|0.12|1.68|4.19|19.49|
|Android arm64 APK|8.25|1.28|0.35|0.01|0.11|0.09|10.09|
|Linux x64|8.89|5.83|0.35|0.12|0.20|0.01|15.40|
|Windows x64|8.35|5.83|0.35|0.12|0.77|0.24|15.67|
|Early spike, macOS, thinned to arm64|4.59|1.92|0.26|0.12|0.97|0.02|7.88|
|Early spike, iOS|4.47|1.92|0.26|0.12|1.00|0.00|7.77|
|Early spike, Android arm64 APK|5.03|0.41|0.26|0.01|0.08|0.06|5.85|
|Early spike, Linux x64|5.50|1.92|0.26|0.00|0.04|0.00|7.71|
|Early spike, Windows x64|5.24|1.92|0.26|0.12|0.44|0.19|8.18|

- **Go core:** `libgojni.so`, `libompcore.so`, `libompcore.dll`. On Apple the core is linked statically into the
  executable: its share is the size of the sections the `Ompcore.xcframework` archive's members bring (`size -m`,
  without zero fill and debug info). `sizes.sh` checks that the archive's `__gopclntab` matches the executable's.
- **`ui/` code and fonts:** `ui/dist` (JS, CSS, HTML, `licenses.json`; KaTeX's and JetBrains Mono's woff2 fonts). The
  JS is 5.7 MB in 148 files: the entry chunk (0.56 MB), Shiki's grammars, each its own lazy chunk (the largest, C++,
  0.80 MB), xterm.js (0.33 MB), the file editor with CodeMirror (0.32 MB), KaTeX (0.26 MB), the companion bundle
  `ompx.js` (0.12 MB) and the app's lazy screens. **Bench content:** `answer-*.js`, the lazy chunk holding
  `BENCH.md`'s text, which a product build would not carry.
- **Shell:** the rest of the executable on Apple (Swift shell, Mach-O headers, link-edit data), `ompanion`,
  `ompanion-spike.exe`, or the Android dex (Kotlin shell, androidx.webkit, gomobile's Java side). The Apple
  executables keep their symbol table: `strip -x` takes 1.41 MB off the arm64 macOS one.
- **Other:** the compiled app icon (`Assets.car`: 4.16 MB on iOS, 1.41 MB on macOS, from `shells/apple/Resources/
  ompanion.icon`), plists, `WebView2Loader.dll` and the icon on Windows, Android resources, zip headers and the APK
  signing block.

## Method

`sizes.sh` prints every Flutter and web app table row above. It downloads release 1.2.1 (`gh release download 1.2.1`)
when missing and writes what it makes to `build/bench/sizes/`: `flutter-1.2.1/` (release assets),
`unpacked/`, `pkg/` (packages it built) and `thin/`.

- **Inputs:** the six release assets; the web app's builds in `build/` (`apple/macos-universal`
  and `apple/ios-device` from `shells/apple/build.sh --universal --device`, `android/app-release-{universal,arm64}.apk`
  from `shells/android/build.sh --release`, `linux-amd64` without its `smoke/` output, `windows-x64`,
  `core/apple/Ompcore.xcframework`); FlutterBench's builds in `build/bench/flutter/` (`app/android/` at
  HEAD, `floor/` for the hello world).
- **Packaging,** as `.github/workflows/build.yml` packages the release:
  - dmg: the app next to an `/Applications` link, `hdiutil create -format ULMO` (and UDZO);
  - ipa: the app in `Payload/`, `ditto -c -k --keepParent`;
  - zip: the folder's contents at the root, `zip -qr`.
- **Download:** the package's file size.
- **Installed:** the sum of the regular files' sizes in the unpacked app: the `.app` copied out of the dmg
  (`hdiutil attach -readonly -nobrowse`, then detach), the `.app` in the ipa, the zip's files. For an APK, the APK plus
  any compressed arm64 library Android would extract (none here). For the Flatpak, the bundle's `xa.installed-size`:
  flatpak's sum of its files, each rounded up to 512 bytes.
- **Architectures:** `lipo -archs` of every Mach-O file in a bundle, the ABIs under the APK's `lib/`, `file` on the
  Linux and Windows executables.
- **Thinning:** a `ditto` copy of the bundle, then `lipo -thin arm64` on every universal Mach-O file in it.
- **Breakdowns:** each file goes to the first part whose path pattern it matches (`flutter_rules`, `web_rules` in
  `sizes.sh`).
