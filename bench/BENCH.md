# Bench contract: Flutter app vs web app

Both apps ran one scripted workload on the same machine, in release builds, so their numbers compare; the web app
still runs it. The workload exercises the transcript: the app's real chat transcript, its markdown renderer and its
message list, not the network or omp.

## Content

`answer.md` (120,080 bytes, ASCII, 422 blocks of headings, paragraphs with inline styles and links, lists, `dart`
fences, tables and `$…$`/`$$…$$` math), made by `make-answer.ts`. Both harnesses embedded this exact file.

## Workload

1. **Launch.** Build the transcript: 20 prior turns, each a user message `Question <k>` and an assistant message
   holding the first 6,000 bytes of `answer.md`. The view sits at the bottom. Emit `first-frame` after the first
   frame that shows the transcript.
2. **Idle.** Wait 5 s. Emit `idle-end`.
3. **Stream.** Append a 21st turn: a user message, then an assistant message that grows by 64 bytes of `answer.md`
   every 16 ms, on a schedule (at elapsed time t the message holds `min(120080, floor(t / 16 ms) * 64)` bytes), so a
   slow renderer catches up instead of stretching the run. That is 1,877 updates over about 30 s. The view follows
   the bottom. Emit `stream-start` before the first update and `stream-end` once the full text has been rendered,
   with `renderLagMs`, the time from the last update to the frame that shows it.
4. **Settle.** Wait 2 s.
5. **Scroll.** Animate the scroll position from the bottom to the top over 8 s, then back to the bottom over 8 s,
   both linear, driven by the app (Flutter `ScrollController.animateTo` with `Curves.linear`, the page with its own
   per-frame interpolation of the transcript's `scrollTop`). Emit `scroll-start` and `scroll-end`.
6. **Idle.** Wait 3 s. Emit `done` with the in-app metrics, then exit with code 0.

## The two harnesses

- **Flutter:** an entrypoint of its own (`flutter build … -t`) that drove the Flutter app's transcript; it was
  removed with the Flutter app.
- **Web:** `ui/src/transcript_bench.tsx` renders the app's chat transcript (`TranscriptView`, as the chat screen
  shows it) and feeds it as a session does. The prior turns are seeded with `withMessages`, as a session opens with
  its messages. The 21st turn arrives as omp's RPC frames through `reduce` (`ui/src/core/store/reducer.ts`):
  `agent_start`, the user message's `message_start` and `message_end`, the reply's `message_start`, one
  `message_update` per step carrying the whole reply so far (as omp's do), then `message_end` and `agent_end` right
  after the last step. The frames are objects: no JSON is parsed. Each scroll step is a wheel event followed by the
  `scrollTop` write, because the transcript treats only the reader's scrolls as leaving the bottom. The way back down
  aims at the bottom as it stands at each frame, since rows built on the way replace estimated heights with measured
  ones.

## Markers

One line per event, `BENCH {"event": "<name>", "epochMs": <wall clock ms>, …}`. Harnesses read the time from
`epochMs`, so the app and the harness need only share a clock, not a pipe.

|App|Trigger|Where the lines go|
|---|---|---|
|Flutter (removed)|its own entrypoint|stdout (`print`); on Android logcat tag `flutter`|
|web app|`OMPCORE_BENCH=1` in the core's environment (`core.info` → `bench: true`); Android intent extra `--ez bench true`|`core.log`: stderr, `$OMPCORE_LOG`, Android logcat tag `GoLog`|

`first-frame` carries `viewWidth`, `viewHeight` and `devicePixelRatio`; `stream-end` `renderLagMs`, `updates` and
`bytes`; `scroll-start` `distancePx`. A web run that fails emits `error` with `message` and exits with code 1.

`done` carries, per phase (`stream`, `scroll`), the frames the app produced and their pacing:

|Field|Flutter|web|
|---|---|---|
|`frames`|`FrameTiming`s reported in the phase|`requestAnimationFrame` callbacks in the phase|
|`p50Ms`, `p90Ms`, `p99Ms`, `maxMs`|of `totalSpan` (vsync start to raster end)|of the interval between consecutive callbacks|
|`over16`, `over33`|frames with `totalSpan` over 16.7 / 33.4 ms|intervals over 16.7 / 33.4 ms (more than the clock's resolution over)|
|`buildP90Ms`, `rasterP90Ms`|from `FrameTiming`|—|
|`longTasks`, `longTaskMs`|—|`PerformanceObserver` `longtask` entries, where the engine has them (`null` in WebKit)|

The web `done` also carries `clockResolutionMs` (1 in WebKit, 0.1 in Chromium) and `userAgent`.

The in-app numbers measure different things in each engine. On Android the authoritative frame numbers come from
outside both apps: Perfetto's FrameTimeline (`actual_frame_timeline_slice`) for every layer of the app's processes.

## External measurements

|Metric|macOS|Android|
|---|---|---|
|memory|`footprint` (phys_footprint) summed over the app and every process it is responsible for (WebKit's WebContent, GPU and Networking for the web app)|`dumpsys meminfo` total PSS of the app process plus its WebView renderer process|
|CPU|CPU time of those processes between markers|`utime + stime` from `/proc/<pid>/stat` between markers|
|startup|harness clock before `exec` → `first-frame`|`am start -W` TotalTime, and device clock before `am start` → `first-frame`|

Memory is sampled every 500 ms; reports give the value at `idle-end` and the peak during stream and scroll.

## Running it

- **One web run, macOS:** the app with `OMPCORE_BENCH=1` and `OMPCORE_LOG=<file>` in its environment, launched in
  studio's GUI session through devpool (`--need host:studio --need pool:studio-gui`, `open -n -W -F --env …`, as
  `shells/apple/smoke.sh` does); the `BENCH` lines land in the log file and the app exits after `done`.
- **Startup:** `measure/startup-measure.sh` (its header lists the commands) launches the app on macOS, the iOS
  simulator and the Pixel 7 through devpool and reports launch to first frame; `measure/startup-floor.sh` builds the
  floor it compares against.
- **Recorded comparisons with the Flutter app:** `docs/research/web-ui/` (`macos.md`, `android.md`, `startup.md`,
  `sizes.md`). `macos.md` and `android.md` measured a prototype transcript, not the app's `TranscriptView`; the
  scripts that drove the Flutter side were removed with the Flutter app.
