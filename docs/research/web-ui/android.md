# Android results: Flutter app vs web spike

A dated record: these runs measured the early spike's prototype transcript (its Session view), not the app's own
`TranscriptView`, which the bench drives now. The scripts it names (`bench/flutter/`, `bench/measure/android-*` but
`android-device.py`) were removed, never committed, with the Flutter app; `android-device.py` keeps only the startup run.

Pixel 7, Android 16, WebView 156, 90 Hz display, through devpool `device:pixel`; release arm64 builds; workload in `bench/BENCH.md`. Collected by `bench/measure/android-measure.sh` (raw data and traces in `build/bench/results/android/`). The measuring run was stopped while writing up, so this is its generated table without further analysis.

- FrameTimeline counts no surface frames for Flutter: its SurfaceView frames carry no app frame token. The SurfaceFlinger present table is the like-for-like frame measure.
- The Flutter bench and the web bench render the same transcript content with each app's real renderer; the Flutter real app is the whole product, the web spike a prototype on its Session tab.

### Machine state

|Session|Battery|Battery temp|Thermal status|Power|studio load avg (1/5/15 min)|Left on the phone|
|---|--:|--:|--:|--:|--:|--:|
|bench-20261101-125820|75 → 75 %|33.6 → 35.4 °C|0 → 0|status 4, USB|{ 1.13 1.25 1.30 } → { 1.29 1.20 1.25 }|none; stay-awake 15 → 15|
|memory-20261101-131031|75 → 75 %|35.5 → 37.1 °C|0 → 1|status 4, USB|{ 1.55 1.28 1.27 } → { 1.32 1.26 1.25 }|none; stay-awake 15 → 15|
|launch-20261101-131741|75 → 75 %|37.3 → 36.6 °C|1 → 1|status 4, USB|{ 1.26 1.23 1.24 } → { 1.26 1.21 1.22 }|none; stay-awake 15 → 15|

Display refresh during stream and scroll, from the spacing of SurfaceFlinger's expected display-frame presents in each trace: 90.4 (90.4–90.4) Hz (vsync period 11.06 (11.06–11.06) ms).

### Startup

Cold `am start -W` TotalTime after `am force-stop` (ms):

|App|Runs|Median (range)|Every run|
|---|--:|--:|--:|
|Flutter bench|5|195 (192–204)|193, 195, 202, 192, 204|
|Flutter real app|5|221 (212–231)|226, 212, 231, 221, 213|
|Web spike, normal launch|5|188 (185–202)|185, 202, 191, 188, 188|
|Flutter floor|5|184 (180–190)|190, 181, 189, 180, 184|
|Flutter bench, frame runs (tracing on)|5|211 (190–286)|286, 211, 192, 236, 190|
|Web spike bench, frame runs (tracing on)|5|191 (191–206)|198, 191, 191, 191, 206|

The first launch after install, not in the medians (ms): Flutter real app 273, Web spike (normal launch) 200, Flutter floor 189.

Phone clock before `am start` → `first-frame` epochMs (ms):

|Runs of|Runs|Median (range)|Every run|
|---|--:|--:|--:|
|Flutter bench, frame runs|5|252 (219–284)|284, 252, 232, 281, 219|
|Web spike bench, frame runs|5|779 (752–834)|818, 834, 779, 752, 772|
|Flutter bench, cold starts|5|237 (224–246)|237, 224, 246, 242, 234|

### Memory

PSS from `dumpsys meminfo --local`, polled back to back per process through memory runs (MiB):

|App|Runs|idle-end|Stream peak|Scroll peak|done|
|---|--:|--:|--:|--:|--:|
|Flutter|3|165 (164–173)|197 (191–235)|194 (193–199)|192 (191–197)|
|Web spike|3|301 (298–302)|572 (523–719)|578 (560–788)|349 (346–351)|
|↳ app process|3|149 (148–149)|185 (179–189)|192 (183–195)|157 (157–157)|
|↳ renderer|3|153 (149–153)|392 (355–531)|391 (388–619)|192 (189–194)|

Each process was read every 735 (537–840) ms (one `dumpsys meminfo` after the other).

PSS from `dumpsys meminfo --local` late in the first idle phase (first-frame + 1.5 s, done before idle-end) and in the last (scroll-end + 0.3 s, done before `done`), frame runs (MiB):

|App|Runs|Idle (idle-end)|Final idle (done)|Web split at idle: app + renderer|at done: app + renderer|
|---|--:|--:|--:|--:|--:|
|Flutter|5|164 (161–173)|192 (192–197)|—|—|
|Web spike|5|300 (293–302)|382 (362–386)|149 (148–150) + 151 (146–152)|168 (165–170) + 214 (195–216)|

Every one of these dumpsys calls ended before its marker: yes.

RSS summed over the app's processes, sampled every ~500 ms from `/proc/<pid>/status`, frame runs (MiB). The web spike's two processes share WebView's mapped files, which RSS counts once per process:

|App|Runs|idle-end|Stream peak|Scroll peak|done|
|---|--:|--:|--:|--:|--:|
|Flutter|5|224 (222–235)|256 (255–264)|256 (254–264)|253 (252–259)|
|Web spike|5|510 (507–513)|729 (689–735)|767 (712–778)|571 (568–577)|

GPU memory (`gpu_mem_total`, Perfetto `android.gpu.memory`) of the app's processes, frame runs (MiB):

|App|Runs|idle-end|Stream peak|Scroll peak|done|
|---|--:|--:|--:|--:|--:|
|Flutter|5|82 (79–82)|82 (82–82)|82 (82–82)|82 (82–82)|
|Web spike|5|74 (74–75)|124 (122–127)|125 (122–129)|84 (83–86)|

Idle memory 15 s after a cold launch, at the first screen: `dumpsys meminfo --local` TOTAL PSS (MiB):

|App|Runs|Total|App process|Renderer|Every run (total)|
|---|--:|--:|--:|--:|--:|
|Flutter real app|3|170 (169–170)|170 (169–170)|—|168.8, 170.1, 169.7|
|Web spike (normal launch)|3|193 (193–195)|142 (141–142)|51 (51–53)|193.3, 192.7, 194.9|
|Flutter floor|3|140 (139–141)|140 (139–141)|—|140.7, 139.9, 138.8|

### CPU

`utime + stime` of the app's processes (the web spike: app + renderer), frame runs: CPU seconds, and in brackets the median share of one core:

|Window|Flutter|Web spike|Web split: app + renderer|
|---|--:|--:|--:|
|launch + idle: `am start` → idle-end|0.30 (0.27–0.89) [6 %]|2.29 (2.22–2.31) [39 %]|0.88 (0.86–0.95) + 1.39 (1.36–1.41)|
|idle: first sample after first-frame → idle-end|0.03 (0.01–0.08) [1 %]|0.40 (0.32–0.45) [9 %]|0.25 (0.20–0.29) + 0.14 (0.12–0.16)|
|stream: stream-start → stream-end|33.05 (32.95–33.61) [110 %]|45.11 (45.02–45.42) [150 %]|17.57 (17.46–17.65) + 27.55 (27.47–27.77)|
|settle: stream-end → scroll-start|0.35 (0.31–0.42) [18 %]|0.61 (0.45–0.65) [31 %]|0.36 (0.29–0.37) + 0.26 (0.16–0.28)|
|scroll: scroll-start → scroll-end|17.37 (16.15–17.62) [108 %]|22.75 (22.65–23.13) [142 %]|11.27 (10.96–11.37) + 11.55 (11.48–11.76)|
|tail: scroll-end → done|0.24 (0.15–0.26) [8 %]|0.98 (0.35–1.11) [33 %]|0.24 (0.18–0.24) + 0.76 (0.10–0.87)|

The sampler's first reading comes 520 (476–621) ms (Flutter) and 627 (596–674) ms (web) after `am start`, after Flutter's first frame, so launch and idle are not split; the idle row covers the last 4,735 (4,662–4,746) ms (Flutter) and 4,667 (4,595–4,734) ms (web) of the 5 s idle.

### Frames (Perfetto)

Presents of the app's layer, from SurfaceFlinger's FrameTracer (`android.surfaceflinger.frame`): Flutter's `SurfaceView[…](BLAST)` layer, the web spike's `app.ompanion.spike/…MainActivity` window layer:

|Phase: metric|Flutter|Web spike|
|---|--:|--:|
|stream: Frames presented|1,660 (1,648–1,669)|1,713 (1,697–1,732)|
|stream: Frames per second|55.2 (54.8–55.5)|57.0 (56.5–57.6)|
|stream: Share of the 90 Hz refresh|61 (61–61) %|63 (62–64) %|
|stream: Present interval p50 (ms)|21.9 (21.8–22.0)|11.2 (11.1–11.2)|
|stream: p90 (ms)|33.1 (33.0–33.1)|33.0 (22.2–33.0)|
|stream: p99 (ms)|33.4 (33.3–33.4)|33.3 (33.2–33.3)|
|stream: max (ms)|44.6 (44.3–55.1)|44.3 (44.2–55.3)|
|stream: Intervals over 1 vsync (> 1.5 × 11.1 ms)|849 (845–856)|821 (803–828)|
|stream: Intervals over 2 vsyncs (> 2.5 ×)|200 (190–210)|179 (151–180)|
|stream: Vsyncs without a new frame|1,052 (1,045–1,066)|996 (979–1,010)|
|scroll: Frames presented|973 (957–992)|965 (956–970)|
|scroll: Frames per second|60.6 (59.5–61.7)|60.1 (59.6–60.4)|
|scroll: Share of the 90 Hz refresh|67 (66–68) %|66 (66–67) %|
|scroll: Present interval p50 (ms)|11.1 (11.1–11.1)|11.1 (11.1–11.1)|
|scroll: p90 (ms)|22.2 (22.2–22.3)|22.1 (22.1–22.2)|
|scroll: p99 (ms)|44.2 (33.3–44.2)|33.2 (33.2–33.2)|
|scroll: max (ms)|88.3 (55.4–99.7)|110.5 (88.5–110.5)|
|scroll: Intervals over 1 vsync (> 1.5 × 11.1 ms)|379 (367–385)|444 (434–445)|
|scroll: Intervals over 2 vsyncs (> 2.5 ×)|78 (75–88)|27 (22–33)|
|scroll: Vsyncs without a new frame|475 (454–493)|479 (475–489)|

FrameTimeline (`android.surfaceflinger.frametimeline`, `actual_frame_timeline_slice`) of the app's layers:

|Phase|App|Surface frames|Presented|Janky|By jank type|Duration p50 (ms)|p90|p99|
|---|--:|--:|--:|--:|--:|--:|--:|--:|
|stream|Flutter|0 (0–0)|0 (0–0)|0 (0–0)|—|—|—|—|
|stream|Web spike|1,715 (1,699–1,734)|1,715 (1,699–1,734)|53 (45–55)|App Deadline Missed: 24 (19–30); Buffer Stuffing: 26 (25–30); Prediction Error: 0 (0–1)|6.3 (6.3–6.4)|11.6 (11.5–11.8)|17.7 (17.3–18.8)|
|scroll|Flutter|0 (0–0)|0 (0–0)|0 (0–0)|—|—|—|—|
|scroll|Web spike|968 (959–972)|968 (959–972)|43 (37–56)|App Deadline Missed: 22 (19–27); Buffer Stuffing: 21 (18–29)|6.6 (6.5–6.8)|12.8 (12.4–13.1)|17.9 (17.8–18.1)|

In-app numbers from `done` (BENCH.md; Flutter's `interval*` and the web spike's `p*`/`over*` are both gaps between frames the app produced):

|Phase: metric|Flutter|Web spike|
|---|--:|--:|
|stream: frames|1,662 (1,649–1,671)|2,686 (2,673–2,691)|
|stream: gap p50 / p90 / p99 (ms)|18.5 (18.3–18.6) / 26.8 (26.5–26.9) / 34.0 (33.0–35.3)|11.1 (11.1–11.1) / 11.1 (11.1–11.1) / 22.0 (11.5–22.1)|
|stream: gaps over 16.7 ms|949 (939–967)|29 (24–40)|
|stream: gaps over 33.4 ms|21 (15–22)|0 (0–1)|
|stream: Flutter totalSpan p50 / p90 / p99 (ms)|13.8 (13.5–14.0) / 19.3 (19.0–19.4) / 26.1 (25.4–26.9)|—|
|scroll: frames|976 (960–994)|1,435 (1,432–1,440)|
|scroll: gap p50 / p90 / p99 (ms)|13.8 (13.4–14.1) / 29.4 (28.8–29.5) / 41.0 (39.6–43.0)|11.1 (11.1–11.1) / 11.1 (11.1–11.1) / 11.2 (11.2–11.2)|
|scroll: gaps over 16.7 ms|397 (381–400)|5 (3–6)|
|scroll: gaps over 33.4 ms|35 (31–46)|2 (1–3)|
|scroll: Flutter totalSpan p50 / p90 / p99 (ms)|8.8 (8.6–9.5) / 24.0 (23.7–24.4) / 34.3 (32.8–37.5)|—|
|stream-end renderLagMs|29.3 (14.1–31.5)|12.1 (9.9–20.2)|

### Every run

Frame runs, in the order they ran:

|Run|done|TotalTime (ms)|→ first-frame (ms)|PSS idle (MiB)|PSS done (MiB)|CPU stream (s)|CPU scroll (s)|Stream presents / skipped vsyncs|Scroll presents / skipped vsyncs|FT janky stream|FT janky scroll|
|---|--:|--:|--:|--:|--:|--:|--:|--:|--:|--:|--:|
|frames-flutter-bench-1|yes|286|284|172.8|197.4|33.05|17.21|1669 / 1045|968 / 482|0|0|
|frames-web-bench-1|yes|198|818|293.5|362.0|45.02|23.13|1712 / 996|970 / 475|55|37|
|frames-flutter-bench-2|yes|211|252|161.5|192.9|33.45|17.44|1651 / 1059|974 / 475|0|0|
|frames-web-bench-2|yes|191|834|299.6|385.0|45.30|22.67|1697 / 1010|965 / 479|45|56|
|frames-flutter-bench-3|yes|192|232|164.4|192.1|33.61|17.37|1660 / 1052|973 / 474|0|0|
|frames-web-bench-3|yes|191|779|300.9|385.7|45.11|22.83|1718 / 993|966 / 479|53|43|
|frames-flutter-bench-4|yes|236|281|164.3|192.4|32.98|17.62|1648 / 1066|992 / 454|0|0|
|frames-web-bench-4|yes|191|752|301.5|381.7|45.02|22.75|1713 / 999|965 / 479|53|48|
|frames-flutter-bench-5|yes|190|219|164.6|192.3|32.95|16.15|1664 / 1048|957 / 493|0|0|
|frames-web-bench-5|yes|206|772|299.3|370.7|45.42|22.65|1732 / 979|956 / 489|52|43|

Memory runs (PSS, MiB):

|Run|done|idle-end|Stream peak|Scroll peak|done|Polls per process|Poll interval (ms)|
|---|--:|--:|--:|--:|--:|--:|--:|
|memory-flutter-bench-1|yes|173.3|197.5|199.1|197.4|76|537|
|memory-web-bench-1|yes|298.0|523.5|560.4|346.0|63, 64|687, 694|
|memory-flutter-bench-2|yes|164.4|235.2|193.8|192.4|62|680|
|memory-web-bench-2|yes|301.8|718.8|578.4|349.0|56, 56|820, 808|
|memory-flutter-bench-3|yes|165.0|191.2|192.8|191.5|58|735|
|memory-web-bench-3|yes|301.1|572.3|788.2|350.5|54, 54|838, 840|

Idle runs:

|Run|Total PSS (MiB)|App process (MiB)|Focused window|Screenshot|
|---|--:|--:|--:|--:|
|idle-flutter-app-1|168.8|168.8|mCurrentFocus=Window{258ed2f u0 com.edde746.ompanion/com.edde746.ompanion.MainActivity};   mFocusedApp=ActivityRecord{19327749 u0 com.edde746.ompanion/.MainActivity t4557}|idle-flutter-app-1.png|
|idle-flutter-app-2|170.1|170.1|mCurrentFocus=Window{8d6be66 u0 com.edde746.ompanion/com.edde746.ompanion.MainActivity};   mFocusedApp=ActivityRecord{57277350 u0 com.edde746.ompanion/.MainActivity t4560}|idle-flutter-app-2.png|
|idle-flutter-app-3|169.7|169.7|mCurrentFocus=Window{4e45350 u0 com.edde746.ompanion/com.edde746.ompanion.MainActivity};   mFocusedApp=ActivityRecord{16873358 u0 com.edde746.ompanion/.MainActivity t4563}|idle-flutter-app-3.png|
|idle-web-1|193.3|142.2|mCurrentFocus=Window{9da71b1 u0 app.ompanion.spike/app.ompanion.spike.MainActivity};   mFocusedApp=ActivityRecord{90477158 u0 app.ompanion.spike/.MainActivity t4558}|idle-web-1.png|
|idle-web-2|192.7|141.4|mCurrentFocus=Window{b2f8ed4 u0 app.ompanion.spike/app.ompanion.spike.MainActivity};   mFocusedApp=ActivityRecord{189344448 u0 app.ompanion.spike/.MainActivity t4561}|idle-web-2.png|
|idle-web-3|194.9|141.8|mCurrentFocus=Window{3a7de1c u0 app.ompanion.spike/app.ompanion.spike.MainActivity};   mFocusedApp=ActivityRecord{38020166 u0 app.ompanion.spike/.MainActivity t4564}|idle-web-3.png|
|idle-floor-1|140.7|140.7|mCurrentFocus=Window{3329855 u0 com.example.floor/com.example.floor.MainActivity};   mFocusedApp=ActivityRecord{187993002 u0 com.example.floor/.MainActivity t4559}|idle-floor-1.png|
|idle-floor-2|139.9|139.9|mCurrentFocus=Window{67c9f6 u0 com.example.floor/com.example.floor.MainActivity};   mFocusedApp=ActivityRecord{164624292 u0 com.example.floor/.MainActivity t4562}|idle-floor-2.png|
|idle-floor-3|138.8|138.8|mCurrentFocus=Window{f5046de u0 com.example.floor/com.example.floor.MainActivity};   mFocusedApp=ActivityRecord{12565759 u0 com.example.floor/.MainActivity t4565}|idle-floor-3.png|

