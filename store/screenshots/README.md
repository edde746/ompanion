# Store screenshots

The harness that captures the App Store, Play and Microsoft Store listing images from the real app, and the
script that composes them. `capture.sh` runs the app in its shell on studio.local through devpool (an iOS simulator,
the Pixel 7, the macOS window), seeds an SSH demo host, scripts the model turns, photographs the screen from the host
and composes the store images into the fastlane directories and `store/microsoft/screenshots/`.

## What is here

| Path | Contents |
| --- | --- |
| `capture.sh` | This Mac's side: stages the built apps on studio, runs `capture.ts` per class in a devpool lease, fetches the raw captures, composes |
| `capture.ts` | Studio's side: the fake provider, the demo host, the scripted turns, the device, the pictures, the cleanup |
| `scenario/` | The steps a capture takes in the app (`main.ts`, with its bridge and DOM helpers), bundled and injected into the page |
| `compose.py` | Composes every store image from its raw capture, renders the icons and the feature graphic |
| `layouts.json` | One composition per image and class: the light, the device and the magnified parts, the caption's place |
| `captions.json` | The label, headline (with its lime phrase) and subline of every shot (plain words, no trademarks) |
| `contact-sheet.sh` | One image of everything that was composed, for a quick review |
| `demo/host.sh` | The SSH demo host on studio: a bastion and a target (user-level OpenSSH), the home at `/Users/Shared/omp` |
| `demo/seed-host.sh` | Puts the omp home and the demo projects on the SSH host |
| `demo/turns.ts`, `demo/prompts.ts` | The scripted model turns, queued on the fake provider's control API, and the prompts the scenario types |
| `demo/rehearse.ts` | Runs the scripted session against a real omp, without the app |
| `demo/projects/` | The three demo projects with their git history |

## Requirements

- The builds: `shells/apple/build.sh` (`build/apple/ios-simulator/ompanion.app`, `build/apple/macos/ompanion.app`),
  `shells/android/build.sh` (the debug `build/android/app-debug.apk`: the harness reaches its WebView over DevTools
  and answers through `run-as`), `scripts/build_companion.sh`, `scripts/fetch_omp.sh darwin-arm64`.
- For composing on this Mac: `uv` and `rsvg-convert` (`brew install uv librsvg`); `uv` brings Pillow for the run.
- Nothing of the store app's (`com.edde746.ompanion`) on studio or the phone: the macOS class claims and cleans
  through `shells/apple/studio-app.sh`, the iOS classes make a simulator of their own and delete it, the Pixel run
  stops when the app is installed and puts back every setting it changed.

## Refresh

```sh
store/screenshots/capture.sh ios-phone ios-ipad play-phone macos   # into this checkout's store/… directories
store/screenshots/capture.sh --out build/store-shots ios-phone      # a trial run, the committed images untouched
python3 store/screenshots/compose.py --review build/store-shots/review   # (uv run --with pillow …)
scripts/studio.sh store-shots --clean
```

Before spending a capture on a change to `demo/turns.ts`, rehearse it on studio:

```sh
scripts/studio.sh <stage> -- bun store/screenshots/demo/rehearse.ts --session hero
```

## How a capture works

1. `capture.sh` copies the class's app into the studio copy and runs `capture.ts` there in a devpool lease
   (`host:studio`; plus `pool:studio-gui` for macOS, `device:pixel` for the phone).
2. `capture.ts` starts the fake provider (`harness/fake-provider`), the demo host (`demo/host.sh`: the tested omp in
   `~/.local/bin`, the prompt `omp@target:~/code/api-server$`, listening on the LAN at devpool's ports 8800–8999 for
   the phone), and `demo/seed-host.sh` writes `~/.omp/agent/{models.yml,config.yml}` (provider `local`, models `Fast`
   and `Reasoning`) and the projects `~/code/api-server`, `~/code/dashboard-web` and `~/work/pipeline`.
3. Two `demo/turns.ts` processes queue the scripted turns: `hero` in `api-server` (read, plan, three subagents,
   write, an edit with a diff, a passing test run, a markdown answer) and `deploy` in `pipeline` (an edit and a smoke
   test, both behind the project's `tools.approvalMode: always-ask`). Turns match the prompt as a conversation
   request carries it (`"text":"…`), not omp's title request; a subagent's turns match a quoted phrase of its own
   assignment.
4. The app starts with the scenario (`scenario/main.ts`, bundled by `Bun.build`) behind `window.ompStoreShots`: the
   Apple shells' `OMPCORE_PAGE_SCRIPT`, on Android `Page.addScriptToEvaluateOnNewDocument` over the WebView's DevTools
   (`adb forward` on air.local, an SSH tunnel). Its first load writes the machines `dev-box` and `build-server` (the
   same target through the bastion), their key and trusted host keys and the settings (dark, English, no "this
   computer") into the app's store and reloads; the second taps through the app.
5. At each picture the scenario logs `STORE-SHOT {name, regions, viewport}` through `core.log` (`$OMPCORE_LOG`,
   logcat's `GoLog`) and waits: `capture.ts` photographs the screen from the host — `xcrun simctl io … screenshot`,
   `adb exec-out screencap` (System UI demo mode: 9:41, full battery and signal), the only pictures with the real
   status bar — and answers with `<the app's cache>/store-shots/<name>.done`. On macOS the scenario asks the shell
   for the window's picture itself (`shell.snapshot`). `regions` are the boxes of the elements the zooms show.
6. `compose.py` composes every raw capture by its entry in `layouts.json`: a zoom names a region, so its cut follows
   the element wherever this layout puts it.

Raw captures land in `build/store-shots/raw/<class>/`: `<shot>.png`, `<shot>.json` (regions), `capture.log`,
`app.log` (the app's lines), the turns' logs, the sshd logs, and `failed.png` when the scenario stopped.

## The Windows capture

`ms-desktop` (3840×2160, the app's window at 1600×900 at 200 %) needs a Windows desktop with a console session that
reaches the demo host. devpool's Windows machines (`pc`, `win11-dev`) were down when this harness was ported
(2026-11-02), and a GitHub Actions Windows runner was not tried: its display cannot be expected to take 3840×2160 at
200 %, and the demo host would have to run in it (WSL 1, OpenSSH, the Linux omp). The committed
`store/microsoft/screenshots/` stay the Flutter app's until a Windows desktop is back; `capture.ts` then needs a
`windows` device (the shell's WebView2 takes the scenario over DevTools with
`WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS=--remote-debugging-port=<port>`, as on Android).

## The look

Every image is its own composition, fitted to what its screen is about, and neighbours in a gallery never share
a layout. What they share is the family, the same as the website's:

- **Light.** OLED black and one light: the π gradient as an ordered 4×4 Bayer dither of square cells on a fixed
  grid, each cell either full colour or black. The colour runs from lime `#C4F042` at the hottest cells through
  emerald `#22C55E` to deep emerald `#0E4A25` where it dissolves. Wide pools of it are lit on every other row
  (scanlines) and fray at the edge; the π itself is lit on every row so the mark stays whole. The hero of every
  class stands the π, built from those cells, behind the device. Where the light falls changes per image, and it
  fades out around the words, so they always sit on black.
- **Type.** SF Pro Bold for the headline (-0.04 em, leading 1.02), with one phrase in solid lime (the part in
  `[brackets]` in `captions.json`); the white part and the lime phrase each start a line. SF Mono uppercase with
  wide tracking for the numbered label, SF Pro Regular in `#8F8F8F` for the subline. The terminal shot sets its
  headline in SF Mono with a lime block cursor.
- **Devices and zooms.** A device is the whole capture in a plain body (near black, one grey outer edge). A zoom
  is an element of the same capture (`region` in `layouts.json`, widened by `pad` capture pixels), magnified with a
  Lanczos filter, rounded, and lifted on a black shadow. No lines, rims, borders, callouts or gradient text. A capture
  is never shown larger than it was taken: `compose.py` fails a device wider than its capture.
- **The Windows window.** On the Microsoft Store the device is the app's window as Windows drew it: its own
  title bar and frame, no body around it, cut to the Windows 11 corner radius (8 px at 100 %, `corner` in
  capture pixels), on the same black shadow.

`compose.py` fails a class when a caption runs into a device or a zoom. `--review <dir>` writes what to judge a
class by: the gallery as a contact sheet, the gallery at store-thumbnail size (300 px wide) and the hero at full
size, plus the feature graphic at full and small size.

## What the shots show

| Shot | Screen | Composition |
| --- | --- | --- |
| `01-chat` | The finished task: tool cards with the diff and the test run, the markdown answer | The dithered π rising behind the device |
| `02-approval` | The deploy machine: the applied edit and a tool call waiting for approval | The approval card magnified over the device it came from |
| `03-tree` | The session tree of the same session, in the dock | A headline at display size over an offset device |
| `04-machines` | Machines, projects and sessions in the sidebar | The machine groups lifted out of the sidebar, no device |
| `05-terminal` | An SSH terminal on the machine (`git status`) | The terminal output as a field, a mono headline with a cursor |
| `06-files` | The edited file with its diff against HEAD | The diff magnified, the device bleeding off an edge |
| `07-agents` | The Agent Hub: one subagent's transcript, or the roster on tablets | The transcript or roster magnified beside an offset device |
| `08-config` | Machine configuration and the model list the machine serves | The model dialog magnified over the dimmed device |

`04-machines` is captured last, so the sidebar shows both machines with their sessions and what each is waiting for.

## Outputs and their sizes

Cited from the stores' own help pages, read 2026-09-26:

| Surface | Size | Where |
| --- | --- | --- |
| App Store iPhone 6.9" | 1320×2868, no alpha | `store/fastlane/ios/screenshots/en-US/<NN>-<shot>-iphone69.png` |
| App Store iPad 13" | 2048×2732, no alpha | `store/fastlane/ios/screenshots/en-US/<NN>-<shot>-ipad13.png` |
| Play phone | 1080×1920 (9:16) | `store/fastlane/android/metadata/android/en-US/images/phoneScreenshots/` |
| Play 7-inch | 1920×1080 (16:9) | `.../images/sevenInchScreenshots/` |
| Play 10-inch | 2560×1440 (16:9) | `.../images/tenInchScreenshots/` |
| Play icon | 512×512, 32-bit PNG | `.../images/icon.png` |
| Play feature graphic | 1024×500, 24-bit PNG | `.../images/featureGraphic.png` |
| App Store marketing icon | 1024×1024, no alpha | `store/app-icon-1024.png` |
| Microsoft Store Desktop | 3840×2160 (16:9), no alpha | `store/microsoft/screenshots/<NN>-<shot>.png` |

- Apple screenshot sizes: [Screenshot specifications](https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications).
  The iPad set is 2048×2732 (portrait, the orientation the simulator captures in), an accepted 13-inch
  resolution that is also on fastlane `deliver`'s own size list.
- Play assets: [Add preview assets to showcase your app](https://support.google.com/googleplay/android-developer/answer/9866151).
  Screenshots must be 1080–7680 px on the long edge and 16:9 or 9:16; tablets need at least four. devpool has no
  Android tablet or tablet emulator now, so the 7- and 10-inch sets stay the Flutter app's.
- Microsoft Store: [App screenshots, images, and trailers for MSIX app](https://learn.microsoft.com/en-us/windows/apps/publish/publish-your-app/msix/screenshots-and-images),
  read 2026-09-27. Desktop screenshots are PNG, 1366×768 or larger (4K, 3840×2160, supported), up to 10 and
  under 50 MB each; critical visuals and text belong in the top two thirds.
- Play asks whether each asset is AI-generated: nothing here is. Every image is a capture of the running app;
  only the model's answers are scripted, through the fake provider.

## Troubleshooting

- `build/store-shots/raw/<class>/capture.log` is the run's log, with the scenario's `STORE-LOG` lines; `app.log`
  has every line the app logged; `failed.png` is the screen when the scenario stopped.
- The demo host's home is fixed (`/Users/Shared/omp`, short because the chat header can show the session's path);
  a capture refuses to start while a process uses it, removes one left behind, and removes it, its sshd and its
  omp runs when it ends.
- `capture.sh` reads itself while it runs: do not edit it during a capture.
