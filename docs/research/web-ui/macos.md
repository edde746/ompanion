# macOS results: Flutter app vs web spike

A dated record: these runs measured the early spike's prototype transcript (its Session view), not the app's own
`TranscriptView`, which the bench drives now. The scripts it names (`bench/flutter/`, `bench/measure/macos-*`) were
removed, never committed, with the Flutter app.

Measured on 2026-11-01 on studio.local through devpool (`host:studio`, `pool:studio-gui`), with the workload in
`bench/BENCH.md`. Scripts are in `bench/measure/`: `macos-measure.sh` (driver), `macos-measure.py` (runs on studio) and
`macos-analyse.py` (tables). Raw data is in `build/bench/results/macos/`.

## Summary

- **Memory:** in the bench the web spike uses more memory at every point:
  - 2.0× at `idle-end`: 175 vs 87 MiB.
  - 1.35× at the stream peak: 594 vs 441 MiB.
  - 2.6× at `done`: 294 vs 112 MiB.

  WebKit's processes hold all of the extra memory; the web spike's app process stays at 29 MiB. On a plain launch,
  15 s idle, the web spike uses 77 MiB, the Flutter real app 87 MiB and Flutter's hello-world floor 48 MiB.
- **CPU:** the web spike uses about 20% less CPU while streaming (11.7 vs 14.5 s) and while scrolling (5.0 vs 5.9 s),
  but about 3× more while idle and to start up.
- **Startup:** Flutter shows its first frame in 188 ms, the web spike in 427 ms.
- **Frames:** both apps rendered at the display's 60 Hz for the whole workload. Missed frames (intervals over
  33.4 ms) are 0–2 per run for both.

## Machine (recorded once, `state/state.json`)

|Item|Value|
|---|---|
|Mac|Mac17,14, Apple M5 Max: 18 CPU cores (6 + 12), 40-core GPU, 128 GiB|
|OS|macOS 27.2 (26B123); WebKit 22625.2.8.11.9|
|Display|1920 × 1080 at 60.00 Hz, scale 1 (the apps report devicePixelRatio 1)|
|Thermal|`pmset -g therm`: no thermal, performance or CPU power warning recorded|
|Power|AC (a desktop, no battery)|
|Load average|1.27 / 1.61 / 2.16 at the start of the session; between 1.1 and 2.8 at the start of each run (logged per run)|

## Method

- **Runs:**
  - 5 bench runs per app, alternated: Flutter, web, Flutter, web, and so on.
  - Then 3 idle rounds of Flutter real app, web spike and Flutter floor.
  - Each run had its own devpool lease. Every run is reported below; none was dropped.
- **Apps:**

  |Run|App|
  |---|---|
  |Flutter bench|`bench/flutter/bench/macos/ompanion.app`, universal, running arm64|
  |web bench|`apple/macos/Ompanion.app` with `OMPCORE_BENCH=1`|
  |Flutter real app|`bench/flutter/app-dev/macos/ompanion.app`, with `/tmp/ompanion-bench-data` and `-home` created empty before each run and deleted after|
  |web plain launch|the same spike `.app` with no `OMPCORE_*` variables|
  |Flutter floor|`bench/flutter/floor/macos/floor.app`|

  Each app ran straight from its binary.
- **Process attribution:** a process counts toward an app when it is one of these:
  - the app itself;
  - an XPC service with a pid in launchd's domain for the app (`launchctl print pid/<app pid>`, no root needed), or in
    the domain of one of those services;
  - a child of a counted process.

  The kernel's responsible pid is no use here. Under ssh the app is not responsible for itself: the app and its
  WebKit processes all report `sshd-session` as their responsible pid.

  Checked by `macos-measure.py probe` (`probe-*/run.json`):
  - The spike's domain lists `com.apple.WebKit.WebContent.<uuid>`, `.GPU.<uuid>` and `.Networking.<uuid>` with
    their pids, plus AppKit's `com.apple.SetStoreUpdateService`.
  - The GPU process's own domain holds `com.apple.audio.SandboxHelper`.
  - All of these processes start 80–225 ms after the app.
  - All of them were gone at the first sample after the app ended (≤ 110 ms), in every probe, bench and idle run.
  - In every run, the only WebKit processes that remained were another app's three (WebContent, GPU, Networking).
    They were older than the session and charged to their own app's responsible pid.

  Every Flutter app also runs `SetStoreUpdateService`. The Flutter real app starts `bash`, `dscl`, `cut` and `sleep`
  children between 0.19 and 0.42 s after exec (its "this computer" probe), and they are counted. One cold floor probe
  also had a `MTLCompilerService`; no measured run did.
- **Memory:**
  - `proc_pid_rusage(RUSAGE_INFO_V4)` `ri_phys_footprint` of each counted process, summed.
  - Sampled every 100 ms. The memory figures use every 5th sample, a 500 ms grid from exec.
  - The value at a marker is the last grid sample at or before its `epochMs`.
  - A phase's peak is the largest grid sample between its start and end markers.
  - Checked against `footprint -p` for every process in the probes (`probe-*/run.json`). For example, the spike's app
    process read 28.66 MiB here and 29 MB in `footprint`, and the Flutter bench app during the stream read 423.25 MiB
    and 423 MB. `footprint`'s MB are MiB, as here.
- **CPU:**
  - `ri_user_time + ri_system_time` of each counted process, in mach ticks converted with `mach_timebase_info`.
    Checked against `ps -o time`: for example 0.545 s here and 0:00.54 in `ps` for the Flutter bench app.
  - Summed over the processes; a process that has exited keeps its last value.
  - Interpolated linearly between the 100 ms samples at each marker's `epochMs`.
  - Phases:
    - idle = `first-frame` → `idle-end`;
    - stream = `stream-start` → `stream-end`;
    - settle + scroll = `stream-end` → `scroll-end`.
- **Startup:** studio's wall clock in the sampler immediately before `subprocess.Popen` (fork + exec), to the
  `first-frame` marker's `epochMs`. Both run on the same clock.
- **Idle runs:**
  - The footprint at the last grid sample at or before exec + 15 s.
  - The CPU between exec + 5 s and exec + 15 s.
  - Then the app gets SIGTERM, and the script watches its processes exit.

## Bench: memory (MiB, phys_footprint summed over the app's processes)

|Point|Flutter, median (range)|web, median (range)|
|---|---|---|
|at `idle-end`|87.2 (87.0–87.2)|175.0 (174.1–176.5)|
|peak during stream|441.4 (438.5–443.9)|594.3 (593.6–600.3)|
|peak during scroll|445.3 (444.5–447.9)|570.4 (568.7–574.2)|
|at `done`|112.2 (108.5–116.2)|293.6 (290.3–294.3)|

### Web spike split (MiB)

At a peak, the values are each process's footprint at the grid sample where the total peaks.

|Point|app process|WebContent|GPU|Networking|audio helper|WebKit sum|SetStoreUpdateService|total|
|---|---|---|---|---|---|---|---|---|
|at `idle-end`|29.2 (28.9–29.4)|112.6 (112.0–113.3)|20.5 (20.4–21.3)|5.0 (4.9–5.1)|5.4 (5.4–5.4)|143.8 (142.8–144.9)|2.2 (2.2–2.3)|175.0 (174.1–176.5)|
|stream peak|28.9 (28.8–29.1)|335.9 (334.7–341.8)|217.3 (217.1–217.6)|4.8 (4.8–4.9)|5.4 (5.4–5.4)|563.2 (562.3–569.2)|2.2 (2.1–2.2)|594.3 (593.6–600.3)|
|scroll peak|29.1 (27.5–29.4)|303.6 (303.4–307.2)|225.5 (224.6–226.1)|4.8 (4.8–4.9)|5.4 (5.4–5.4)|539.1 (538.8–542.9)|2.2 (2.1–2.2)|570.4 (568.7–574.2)|
|at `done`|29.1 (27.5–29.4)|213.2 (212.3–214.5)|38.3 (38.2–38.8)|4.8 (4.8–4.9)|5.4 (5.4–5.4)|262.1 (260.6–263.1)|2.2 (2.1–2.2)|293.6 (290.3–294.3)|

Flutter's split is simpler: the app process accounts for all of it except `SetStoreUpdateService`'s 2.2 MiB. Its app
process measured 85.0 (`idle-end`), 439.2 (stream peak), 443.1 (scroll peak) and 110.0 MiB (`done`).

## Bench: CPU (seconds, summed over the app's processes)

|Phase|Flutter, median (range)|web, median (range)|
|---|---|---|
|exec → `first-frame`|0.15 (0.14–0.15)|0.61 (0.57–0.63)|
|idle (`first-frame` → `idle-end`, 5 s)|0.06 (0.05–0.08)|0.19 (0.18–0.20)|
|stream (`stream-start` → `stream-end`, 30.05 s)|14.54 (14.48–14.63)|11.72 (11.71–11.84)|
|settle + scroll (`stream-end` → `scroll-end`, 2 s + 16.1 s)|5.86 (5.79–5.89)|5.00 (4.98–5.08)|
|exec → `done`|20.66 (20.52–20.74)|17.60 (17.52–17.69)|

### Web spike split (s)

|Phase|app process|WebContent|GPU|Networking|audio helper|WebKit sum|SetStoreUpdateService|total|
|---|---|---|---|---|---|---|---|---|
|exec → `first-frame`|0.15 (0.15–0.15)|0.31 (0.30–0.31)|0.10 (0.07–0.11)|0.02 (0.02–0.02)|0.02 (0.02–0.02)|0.44 (0.40–0.46)|0.02 (0.02–0.02)|0.61 (0.57–0.63)|
|idle|0.01 (0.01–0.01)|0.16 (0.16–0.17)|0.01 (0.01–0.01)|0.00|0.00|0.18 (0.17–0.19)|0.00|0.19 (0.18–0.20)|
|stream|1.12 (1.11–1.13)|8.21 (8.19–8.29)|2.39 (2.38–2.42)|0.00|0.00|10.59 (10.59–10.71)|0.00|11.72 (11.71–11.84)|
|settle + scroll|0.54 (0.53–0.54)|3.45 (3.44–3.50)|1.02 (1.00–1.04)|0.00|0.00|4.46 (4.45–4.54)|0.00|5.00 (4.98–5.08)|

## Bench: startup (ms, studio clock before exec → `first-frame` `epochMs`)

|Metric|Flutter, median (range)|web, median (range)|
|---|---|---|
|exec → `first-frame`|188 (169–194)|427 (426–440)|

## Bench: frames (the in-app `done` metrics)

Flutter's columns are its `interval*` fields, the gaps between `FrameTiming` vsync starts. Web's columns are the gaps
between `requestAnimationFrame` callbacks. The missed-frame row (over 33.4 ms) is the one that compares directly.

|Stream|Flutter, median (range)|web, median (range)|
|---|---|---|
|frames|1801 (1800–1803)|1802 (1802–1803)|
|interval p50 ms|16.72 (16.69–16.74)|17 (17–17)|
|interval p90 ms|18.35 (18.30–18.39)|17 (17–17)|
|interval p99 ms|20.40 (20.12–20.86)|19 (19–20)|
|interval max ms|35.43 (24.45–38.44)|38 (31–40)|
|intervals over 16.7 ms (not comparable, see caveats)|913 (893–935)|165 (155–168)|
|**intervals over 33.4 ms (missed frames)**|**2 (0–2)**|**1 (0–1)**|
|Flutter frame cost (`totalSpan`) p50 / p90 / p99 ms|5.46 / 7.68 / 9.60|—|
|Flutter build / raster p90 ms|6.07 / 1.24|—|
|`renderLagMs` at `stream-end`|10.5 (8.7–16.4)|8 (5–12)|

|Scroll|Flutter, median (range)|web, median (range)|
|---|---|---|
|frames|965 (964–965)|962 (962–962)|
|interval p50 ms|16.28 (16.26–16.31)|17 (17–17)|
|interval p90 ms|23.28 (23.21–23.45)|17 (17–17)|
|interval p99 ms|25.51 (25.12–25.54)|19 (18–19)|
|interval max ms|29.18 (29.14–38.21)|25 (19–27)|
|intervals over 16.7 ms (not comparable)|416 (411–419)|41 (30–55)|
|**intervals over 33.4 ms (missed frames)**|**0 (0–1)**|**0 (0–0)**|
|Flutter frame cost (`totalSpan`) p50 / p90 / p99 ms|2.72 / 9.01 / 10.95|—|
|Flutter build / raster p90 ms|7.20 / 1.21|—|

## Bench: every run, in run order

|Run|startup ms|MiB at `idle-end`|stream peak|scroll peak|at `done`|CPU s idle|CPU s stream|CPU s settle+scroll|load avg before|
|---|---|---|---|---|---|---|---|---|---|
|1 Flutter|181|87.0|443.9|445.3|111.5|0.06|14.54|5.87|1.56 1.47 1.98|
|1 web|426|174.1|598.7|568.7|290.3|0.18|11.71|4.98|1.56 1.51 1.96|
|2 Flutter|169|87.1|439.7|444.8|108.5|0.08|14.52|5.85|1.56 1.55 1.95|
|2 web|427|176.5|593.6|571.1|293.6|0.20|11.72|5.03|2.52 1.89 2.05|
|3 Flutter|188|87.2|438.5|447.9|112.2|0.06|14.57|5.89|1.74 1.80 2.00|
|3 web|426|175.0|600.3|570.4|293.0|0.19|11.71|5.08|2.50 2.02 2.07|
|4 Flutter|194|87.2|441.4|444.5|116.2|0.05|14.48|5.79|2.08 2.00 2.06|
|4 web|431|175.1|593.9|574.2|294.3|0.20|11.78|4.98|2.24 2.07 2.08|
|5 Flutter|191|87.2|442.8|446.2|112.4|0.06|14.63|5.86|2.84 2.27 2.15|
|5 web|440|175.0|594.3|570.0|293.7|0.19|11.84|5.00|1.99 2.14 2.11|

|Run|stream frames|stream interval p50/p99/max ms|stream >16.7|stream >33.4|scroll frames|scroll interval p50/p99/max ms|scroll >16.7|scroll >33.4|`renderLagMs`|
|---|---|---|---|---|---|---|---|---|---|
|1 Flutter|1801|16.71/20.87/35.43|916|2|965|16.31/25.53/29.18|419|0|16.4|
|1 web|1803|17/19/31|155|0|962|17/18/27|38|0|12|
|2 Flutter|1801|16.74/20.64/36.03|935|1|965|16.26/25.43/38.21|411|1|8.7|
|2 web|1802|17/20/38|163|1|962|17/19/25|47|0|5|
|3 Flutter|1800|16.72/20.40/38.44|910|2|965|16.28/25.54/29.15|413|0|10.5|
|3 web|1802|17/20/40|165|1|962|17/19/25|55|0|10|
|4 Flutter|1801|16.69/20.37/35.12|893|2|964|16.29/25.12/29.17|416|0|11.5|
|4 web|1802|17/19/32|168|0|962|17/19/19|41|0|5|
|5 Flutter|1803|16.72/20.12/24.45|913|0|965|16.27/25.51/29.66|417|0|9.3|
|5 web|1802|17/19/39|167|1|962|17/18/27|30|0|8|

Every run exited by itself with code 0, 56.4 s (Flutter) and 56.7 s (web) after exec. In every run the stream took
30.04–30.05 s with 1877 updates, and the scroll 16.06–16.07 s (Flutter) or 16.02–16.03 s (web).

## Idle: 15 s at the first screen, plain launch

|App (3 runs each)|Footprint at 15 s, MiB|app process|WebContent|GPU|WebKit sum|other XPC|peak 0–15 s (500 ms grid)|CPU s, 5–15 s|
|---|---|---|---|---|---|---|---|---|
|Flutter real app (dev overrides)|87.4 (87.4–87.7)|85.3 (85.2–85.5)|—|—|—|2.2 (2.2–2.2)|430.9 (427.0–431.3)|0.002 (0.002–0.002)|
|web spike, plain launch|76.8 (76.7–77.1)|28.5 (28.3–28.5)|22.9 (22.9–23.0)|13.0 (13.0–13.2)|46.2 (46.1–46.5)|2.2 (2.2–2.2)|284.6 (284.1–285.0)|0.008 (0.007–0.008)|
|Flutter floor|48.4 (48.3–48.4)|46.2 (46.1–46.3)|—|—|—|2.2 (2.1–2.2)|385.7 (385.5–385.7)|0.002 (0.002–0.002)|

The web spike's WebKit sum also includes Networking (about 5 MiB) and the audio helper (5.4 MiB).

|Run|footprint at 15 s|app process|WebKit|other|peak 0–15 s|CPU s, 5–15 s|load avg before|
|---|---|---|---|---|---|---|---|
|1 Flutter real app|87.4|85.2|—|2.2|427.0|0.002|1.49 1.98 2.05|
|1 web|77.1|28.5|46.5|2.2|285.0|0.008|1.30 1.92 2.03|
|1 floor|48.4|46.3|—|2.2|385.7|0.002|1.32 1.89 2.02|
|2 Flutter real app|87.4|85.3|—|2.2|430.9|0.002|1.29 1.84 2.00|
|2 web|76.7|28.3|46.2|2.2|284.1|0.008|1.17 1.79 1.97|
|2 floor|48.4|46.2|—|2.2|385.7|0.002|1.13 1.75 1.95|
|3 Flutter real app|87.7|85.5|—|2.2|431.3|0.002|1.30 1.75 1.95|
|3 web|76.8|28.5|46.1|2.2|284.6|0.007|1.15 1.69 1.93|
|3 floor|48.3|46.1|—|2.1|385.5|0.002|2.56 1.96 2.01|

What each app shows. `screencapture` inside the devpool lease fails with "could not create image from display", so
the screens come from the on-screen window list (CGWindowList) and the code:

|App|Window|Screen|
|---|---|---|
|Flutter real app|1280 × 800|the wide shell (sidebar, home pane, dock) on an empty data directory; in its first half second it probes "this computer" (the `bash`/`dscl` children) [INFERENCE: from `lib/app/app.dart` of commit `359d920`, `ShellScreen` and the child processes; not seen]|
|web spike|1100 × 760 content (792 with the title bar)|the Session tab: header, omp settings card, empty transcript, composer [INFERENCE: from the spike's `ui/src/App.tsx` of that day, which the app's shell has replaced; not seen]|
|Flutter floor|800 × 600 content (632 with the title bar)|the `flutter create` counter page [INFERENCE: not seen]|

## Caveats

- **Whole product vs prototype:** the Flutter real app has the database, notifications, the Sparkle updater, the
  local-machine probe and the full shell UI. The web spike is a prototype on its Session tab. The idle numbers compare
  different screens and features. The floor is Flutter's minimum on this machine.
- **The bench compares like with like, mostly:**
  - Both apps render the real transcript renderer in a 1100 × 760 view at devicePixelRatio 1.
  - Flutter's bench page is the transcript alone. The web page also has the app header (`bench/BENCH.md`, WebBench
    notes).
  - Flutter's `first-frame` is the first frame with the transcript. The web `first-frame` also counts the dynamic
    import of the answer text.
- **The in-app frame numbers mean different things:**
  - Flutter's `interval*` fields come from `FrameTiming` vsync timestamps. The web `p*` fields come from rAF callback
    times on a 1 ms clock.
  - `over16` does not compare. Flutter counts intervals over 16.7 ms at µs resolution, so about half of a steady
    16.67 ms cadence counts. Web counts intervals over 16.7 ms plus the 1 ms clock step.
  - Flutter's scroll p90 of 23 ms with p50 under 16.67 ms is jitter in its vsync timestamps. Its frame count still
    matches the 60 Hz display: 965 frames in 16.07 s.
  - Missed frames (over 33.4 ms) and frame counts are what compare. WebKit has no `longtask` entries.
- **Graphics memory drives both peaks.** `footprint -p` during the stream (`probe-*-bench/footprint-<pid>.txt`, at
  exec + 6 s):
  - Flutter: 327 of 423 MB is "Owned physical footprint (unmapped) (graphics)".
  - The web GPU process: 188 of 209 MB is graphics.
  - WebContent: 74 MB graphics, plus 97 MB of WebKit Malloc, 53 MB of it reclaimable.

  Both engines release most of it once frames stop:
  - Flutter falls from about 423 to 87 MiB by 1.5 s after exec, once the startup frames are done.
  - The web GPU process falls to 38 MiB after the scroll.

  That explains:
  - the startup transients in the idle "peak 0–15 s" column;
  - the per-process kernel lifetime maxima in `run.json`: Flutter bench app 454 MiB, WebContent 361 MiB, GPU 226 MiB.

  At scale 2 (Retina) the frame buffers hold four times the pixels [INFERENCE: not measured].
- **The 500 ms grid can miss short peaks.** The kernel's per-process lifetime maxima above are the cross-check: the
  Flutter bench app process peaked at 454 MiB against 445 MiB on the grid.
- **WindowServer is not counted:** neither app's compositing work in WindowServer is attributed to it.
- **Shared host:** `host:studio` takes up to 8 leases, so other agents' work may have run at the same time. Load
  averages were 1.1–2.8 on 18 cores. Runs of the same app agree closely: stream and scroll CPU stay within 2% of the
  median.
- **Sampler cost is not counted:** the sampler (Python) and its `launchctl print` every 500 ms (about 3 ms each) run
  on the same machine but outside the counted processes.
- **Flutter version:** the builds come from FlutterBench's `build.sh`. The build Mac's SDK is Flutter 3.47.1 (Dart
  3.13.1) [UNVERIFIED that these builds used it].
- **Left on studio:** the runs created `~/Library/Containers/com.example.floor` (the floor is sandboxed) and a
  `flutter_local_notifications_presentation_options` key in `com.edde746.ompanion`'s defaults. Both were removed.
  The pre-existing `~/Library/Caches/app.ompanion.spike/WebKit` cache was updated by the spike runs.

## Reproduce

```sh
bench/measure/macos-measure.sh stage     # apps + sampler to studio:~/ompanion-bench/MacMeasure
bench/measure/macos-measure.sh state     # machine state
bench/measure/macos-measure.sh probe web # attribution check (also: web-bench, flutter-bench, flutter-app, flutter-floor)
bench/measure/macos-measure.sh bench 1 5 # rounds 1..5: Flutter bench, then web bench
bench/measure/macos-measure.sh idle 1 3  # rounds 1..3: Flutter real app, web plain, Flutter floor
bench/measure/macos-measure.sh analyse   # tables.md + summary.json, computed on studio
bench/measure/macos-measure.sh clean     # remove the staging folder
```

Each run is one `devpool run --need host:studio --need pool:studio-gui -- python3 macos-measure.py <mode> <app> runs/<run>`.
Every run passed (`RESULT: PASS`).
