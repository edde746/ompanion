# Startup: launch to first frame, Flutter app vs web app

Measured on 2026-11-01 on studio.local through devpool. Scripts: `bench/measure/startup-measure.sh` (driver),
`bench/measure/startup.py` (macOS and iOS simulator runs, report), `bench/measure/android-device.py startup` (Android),
`bench/measure/startup-floor.sh` (the floor build). Raw data: `build/bench/results/startup/<platform>-<session>/`. The
Flutter side (`bench/flutter/`) was removed, never committed, with the Flutter app; the scripts now measure the web
app alone.

## Summary

|Platform|Flutter|web before|web after|
|---|--:|--:|--:|
|Android (Pixel 7), `am start` → first frame|238 (227–278)|419 (407–440)|**272 (262–437)**|
|macOS, exec → first frame|268 (202–371)|325 (286–525)|**292 (277–307)**|
|iOS simulator, `simctl launch` → first frame|—|916 (801–989)|**835 (799–969)**|

Median (range) of 7 runs, ms. The Android before and after sessions ran back to back with the same harness; the
Flutter column is the before session's (the after session's: 235 (215–252)). The macOS row is one session (`quiet`,
load average 12–25), all apps alternating.

- **Android: 419 → 272 ms, 34–37 ms above Flutter.** The web app now paints its first frame 191 ms after the kernel
  started its process, before the 218 ms of a static page with no app at all (round 1's floor). What is left is the
  WebView's own start: 78 ms creating it on the UI thread, then ~75 ms from the page's response to the end of parsing
  even for a 1 KB page. Flutter's whole first frame, ~155 ms after its process started, takes about as long as those
  two.
- **macOS: 325 → 292 ms in the same session, 24 ms above Flutter by the page's own mark, ~30 ms below it by WebKit's.**
  WebKit reports the kept frame's first contentful paint at 237 ms after process start (before: 284), but runs the
  page's first animation frame, where the page's mark is taken, only at 287 ms, next to the entry's start. Flutter's
  runs spread over 202–371 ms in this session (196–213 in round 1's quieter ones).
- **iOS simulator: 916 → 835 ms**, but the page's part did not change (≈ 57 ms from parsed to painted, before and
  after); the simulator's process launches dominate: 222 ms from process start to `main`, 238 ms waiting for the
  WebContent process.

## What changed, and what each did

|Change|Where|Measured effect|
|---|---|---|
|The last launch's first frame, kept in localStorage and painted by an inline script in `index.html` before the entry runs|`ui/src/app/first_frame.ts`, `first_frame_restore.js`|Android: first frame at 203 ms after process start instead of the app's own render at 293 (5 runs, `stage1`); macOS: WebKit's first contentful paint 284 → 237 ms|
|Round 1's harness killed the app within ms of its first frame, before Chromium commits localStorage (5 s after a write): every run now keeps the app 7 s, as a user's session would (`STAY_S`)|`bench/measure/startup.py`, `android-device.py`|The kept frame shows from the third launch after install (the second still reads the first's platform snapshot)|
|Not on iOS: the frame was saved and its inputs matched, but iOS WebKit ran the first animation frame at 727 ms, after the app's own render at 715 (probe of 3 launches on the simulator): it never painted first|`first_frame_restore.js`|—|
|The entry's stylesheet and the restore script inline in `index.html` (the CSP allows the script by its hash)|`ui/vite.config.ts` (`inlineFirstFrame`)|Android: parsing ends at 183 ms instead of 199–211, the kept frame at 191 instead of 203–204; the median launch 292 → 272|
|Screens, panes and dialogs off the first frame load lazily (`lazy`/`lazyModule`, preloaded after boot); German strings only for German|`shell_screen.tsx`, `sidebar.tsx`, `home_pane.tsx`, `machine_sessions.tsx`, `app/preload.ts`, `app/i18n/i18n.ts`, `app/language.ts`|Entry 920 → 557 KB (gzip 296 → 185 KB), CSS 102 → 27 KB. The app's own render barely moved: Android `liveFrameMs` 299 (round 1's one 920 KB file) → 293, iOS unchanged; the first frame no longer waits for it where the kept frame shows|
|WebView's package check and debugging switch moved from the start of `onCreate` to right before the WebView is made (left from the start-up experiment below)|`MainActivity.kt`|The core's thread starts before WebView loads; not measured apart|
|Tried and reverted: `WebViewCompat.startUpWebView` on a background thread|`MainActivity.kt`|Worse: the window drew earlier (`am start -W` 187 → 91 ms) but the WebView existed at 104 ms instead of 91 and the first frame came later (median 328 vs 292, 5 runs)|
|Tried and reverted: Safe Browsing off, page assets stored uncompressed in the APK|manifest, `build.gradle.kts`|No measurable change: response end 103 vs 104 ms, first frame within noise (5 runs, `shell2`)|
|Checked: the core's `libgojni.so` is stored uncompressed and page-aligned already|`zipalign -c -P 16`|—|

Not done, because the numbers say it would not move the first frame: deferring the providers and the TypeScript core
(`ui/src/core/session`, `ui/src/core/rpc`, `ui/src/core/channel`, ~170 KB of the 557 KB entry). The first 360 KB cut
moved the app's own render by 6 ms on Android and nothing on iOS, and where the kept frame shows the entry is off the
first frame. Sessions' `runtimeFor` is also synchronous by contract.

## Method

- **End point, both apps: the first frame of the real app** (the shell with sidebar and home pane).
  - Flutter: `bench/flutter/startup_main.dart` runs the app's own `main` and prints `BENCH {"event":"first-frame"}`
    with the first `FrameTiming`'s `rasterFinishWallTime` (`bench/flutter/build.sh startup`; macOS with app-dev's data
    overrides, Android arm64 release).
  - Web: the page's marks (`ui/src/app/boot_timing.ts`) go to the shell as `shell.timing`, which logs the `shell timing`
    line on every launch (`docs/contracts/bridge.md`, Launch timing). `firstFrameMs` is the task after the frame painted
    (`requestAnimationFrame` then `setTimeout`): the kept frame when it painted before the app rendered, else the app's
    own render.
- **Start point:** macOS: studio's clock right before fork + exec of the app binary. Android: the phone's clock right
  before `am start -W` after `am force-stop` and 3 s. iOS simulator: right before `xcrun simctl launch`.
- **Runs:** one warm-up launch per app (it also creates the app's data), then 7 rounds alternating the apps; each app
  runs 7 s after its first frame, then quits. macOS sessions also run the old web build and the floor in the same
  rounds. Android sessions run one web build each, with the Flutter app.
- **The floor:** the shells as built, serving `bench/startup-floor/` (a static page with a few lines of text and a
  2 KB script that reports the same marks) instead of `ui/dist`.

## Android (Pixel 7, Android 16, WebView 156)

|Session|Flutter|web|
|---|--:|--:|
|`before2` (round 1's build)|238 (227–278)|419 (407–440)|
|`stage1` (lazy screens, kept frame; 5 runs)|239 (220–280)|292 (278–372)|
|`shell1` (+ async WebView start-up, Safe Browsing off, stored assets; 5 runs)|250 (233–273)|328 (301–436)|
|`shell2` (Safe Browsing off, stored assets; 5 runs)|244 (233–253)|307 (253–361)|
|`inline` (final: stylesheet and restore script inline)|235 (215–252)|272 (262–437)|
|round 1's floor (static page)|—|298 (270–314)|

`inline`'s 437 is its first measured launch, the one whose kept frame still had the install's platform snapshot.

Stages, ms since the kernel started the process (median):

|Stage|before2|inline|
|---|--:|--:|
|shell's first code|15|15|
|WebView created|93|93|
|navigation start|95|95|
|HTML received (`responseEnd`)|105|107|
|HTML parsed (`domInteractive`)|188|183|
|kept frame painted|—|191|
|**first frame**|**333**|**191**|
|entry began evaluating|292|244|
|app rendered|326|290|
|app's render painted|333|292|
|core answered `core.info`|335|306|

## iOS simulator (iPhone 17, iOS 27.0), web only

`final` 835 (799–969) and `before2` 916 (801–989), one after the other on two simulators. Stages (ms since process
start, median, `final`): `main` 222, shell 232, WKWebView 276, `load` 281, window shown 351, main queue 373, navigation
policy 611, navigation start 638, parsed 642, entry 669, rendered 694, painted 699. Before: parsed 720, painted 778.

- **222 ms before `main`:** the same binary (8.9 MB, ~38,000 fixups, the same as the macOS one's) reaches `main` in
  12–17 ms on macOS. [INFERENCE] the simulator's process launch (dyld_sim and the simulator runtime), not the app.
- **238 ms from the main queue to the navigation policy:** [INFERENCE] WKWebView launching its WebContent process,
  another simulator process launch. The web view is made 10 ms after `main`, in the app delegate's init.
- **Page: ~57 ms from parsed to painted, before and after:** fetching, compiling and running the entry took 48 ms
  for 920 KB in ~130 files and 52 ms for 557 KB in one. The kept frame cannot paint before it (above).

## macOS

Session `quiet` (7 rounds, load average 12–25): Flutter 268 (202–371), web before 325 (286–525), web after
292 (277–307), floor 311 (266–382). Stages, ms since process start (median):

|Stage|before|after|floor|
|---|--:|--:|--:|
|`main`|15|16|18|
|shell's first code|57|56|58|
|web view created|98|101|95|
|`load`|119|122|116|
|window shown|170|174|166|
|navigation policy|219|223|221|
|navigation start|223|227|227|
|HTML parsed|227|231|229|
|WebKit's first contentful paint|284|**237**|—|
|entry began evaluating|267|285|269|
|app rendered|276|297|269|
|**first frame (page's mark)**|**325**|**292**|**311**|
|core answered `core.info`|289|300|313|

- Process start → navigation, ~225 ms, is the shell and WebKit and the same for all three: round 1 found WKWebView
  starting its WebContent process at the first `load` and its processes reporting ready only when AppKit's launch
  lets the main run loop turn; creating the web view before `NSApplication`, sizing it at creation and showing the
  window earlier changed nothing.
- The kept frame paints right after parsing (FCP 237); the page's mark sees it at the first animation frame WebKit
  runs, ~50 ms later. The other sessions: `final` (load average 250–400): Flutter 379, before 387, after 352, floor
  397; `stage1` (loaded): Flutter 269, before 327, after 328, floor 313.

## Caveats

- `host:studio` was shared with other agents' test runs. Load averages ran from 3 (round 1) to 250–400 (the `final`
  macOS session); compare rows of the same session. The Pixel 7 sits on air.local and was not shared.
- Flutter's mark is the raster end of its first frame; the web's is the task after its frame painted in the web
  content process. Neither includes the window server or SurfaceFlinger presenting it. The engines' own
  first-contentful-paint entries disagree with the web mark in both directions: Chromium's on Android lands ~110 ms
  after it, for the kept frame and the app's render alike (round 1: 116 ms), WebKit's on macOS ~50 ms before it.
  [UNVERIFIED] which of them is closer to the screen; only a SurfaceFlinger / window server trace of both apps would
  tell.
