# Store screenshots

The harness that captures the App Store and Play listing images from the real app, and the script that
composes them. `capture.sh` drives a simulator or emulator headlessly, seeds an SSH demo host, scripts the
model turns, photographs the screen from the host and writes the store images into the fastlane directories.

## What is here

| Path | Contents |
| --- | --- |
| `capture.sh` | One device class: boots the device, seeds the host, runs `flutter drive`, composes |
| `compose.py` | Composes every store image from its raw capture, renders the icons and the feature graphic |
| `layouts.json` | One composition per image and class: the light, the device and the magnified crops, the caption's place |
| `captions.json` | The label, headline (with its lime phrase) and subline of every shot (plain words, no trademarks) |
| `contact-sheet.sh` | One image of everything that was composed, for a quick review |
| `demo/turns.ts` | The scripted model turns, queued on the fake provider's control API |
| `demo/seed-host.sh` | Puts the omp home and the demo projects on the SSH host |
| `demo/rehearse.ts` | Runs the scripted session locally against a real omp, without the app |
| `demo/projects/` | The three demo projects with their git history |

Raw captures stay in `/tmp/ompanion-store/StoreShots/raw/<class>/` and are never committed.

## Requirements

- The SSH demo host: `harness/sshd/up.sh`, then its keys in `.tools/ssh-test/` and the `omp` user on
  127.0.0.1:22221 with the bastion on 22220. The container needs `git`, `node` and `npm` for the demo projects;
  `capture.sh` installs them over `docker exec` when the host is `omp-sshd-target`.
- `flutter` on PATH with an iOS simulator runtime (iPhone 17 Pro Max, iPad Pro 13-inch M5) or the Android SDK
  in `$ANDROID_HOME`, arm64 system images, `emulator` and `avdmanager` under it.
- `bun`, and `docker` while the demo host is the container.
- `python3 -m pip install pillow` and `brew install librsvg` for `compose.py`.
- A built companion and, for the local rehearsal, this computer's omp: `scripts/build_companion.sh`,
  `scripts/fetch_omp.sh darwin-arm64`.

## Refresh

```sh
harness/sshd/up.sh
store/screenshots/capture.sh ios-phone
store/screenshots/capture.sh ios-ipad
store/screenshots/capture.sh play-phone
store/screenshots/capture.sh play-7in
store/screenshots/capture.sh play-10in
python3 store/screenshots/compose.py --review /tmp/ompanion-store/StoreShots/review
harness/sshd/down.sh
```

Each run takes ten to twenty minutes: the app builds, uploads the companion to the host and runs a real omp
session. Heavy work belongs in a private copy of the checkout (`rsync -a --exclude build --exclude .dart_tool
--exclude node_modules <checkout>/ /tmp/<me>-copy/`) so nobody else's build is disturbed; pass
`--repo /tmp/<me>-copy` to `capture.sh`.

`--keep` leaves the simulator booted, `--keep-avds` keeps the temporary tablet AVDs, `--no-compose` captures
only, `--no-container` skips the `docker exec` package install when the demo host is a machine you prepared
yourself (then also pass `--provider-url http://127.0.0.1:<port>/v1`).

Before spending a capture run on a change to `demo/turns.ts`, rehearse it:

```sh
bun store/screenshots/demo/rehearse.ts --session hero     # prints the transcript, the diff and the test run
bun store/screenshots/demo/rehearse.ts --session deploy --keep
```

## How a capture works

1. `capture.sh` starts the fake provider (`harness/fake-provider`) on port 18991 unless one is listening.
2. `demo/seed-host.sh` writes `~/.omp/agent/{models.yml,config.yml}` (provider `local`, models `Fast` and
   `Reasoning`, `modelRoles.default`) and the projects `~/code/api-server`, `~/code/dashboard-web` and
   `~/work/pipeline` into the demo host's home, each with a small git history.
3. Two `demo/turns.ts` processes queue the scripted turns: `hero` in `api-server` (read, plan, subagent,
   write, an edit with a diff, a passing test run, a markdown answer, then the `ask` question) and `deploy` in
   `pipeline` (an edit and a smoke test, both behind the project's `tools.approvalMode: always-ask`).
4. `flutter drive` runs `integration_test/store_screenshots_test.dart`. The test builds the real app graph,
   seeds the machines through `MachinesProvider`/`KeysProvider` (so no form typing can go wrong), taps through
   the UI, and calls `binding.takeScreenshot(<shot>)`.
5. `integration_test/driver/store_driver.dart` photographs the screen when the test asks for it, from the host:
   `xcrun simctl io <udid> screenshot` or `adb exec-out screencap -p` — the only capture that carries the real
   status bar (`9:41`, full battery, full signal, System UI demo mode on Android). A screenshot the app takes
   itself renders only the Flutter view, and `integration_test`'s `onScreenshot` callback only runs after the
   test, so the timing is a file channel: the test writes `<system temp>/ompanion-shots/<name>.request` in its
   own sandbox and waits for `<name>.done`, the driver polls that directory (a path on this Mac for a
   simulator) and answers with the PNG.
6. `compose.py` composes every raw capture by its entry in `layouts.json`, draws the words from `captions.json`
   and writes the store images.

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
  is a rectangle of the same capture, cut on element or row boundaries (`crop` in `layouts.json`, capture pixels),
  magnified with a Lanczos filter, rounded, and lifted on a black shadow. No lines, rims, borders, callouts or
  gradient text. On tablets the dock (agents, tree, files, terminal) is on the right of the capture, so tablet
  zooms come from there, and a device that carries a zoomed dock keeps that dock inside the canvas.

`compose.py` fails a class when a caption runs into a device or a zoom. `--review <dir>` writes what to judge a
class by: the gallery as a contact sheet, the gallery at store-thumbnail size (300 px wide) and the hero at full
size, plus the feature graphic at full and small size.

The feature graphic is the wordmark and the headline's phrase beside the dithered π, which bleeds off the bottom
edge.

## What the shots show

| Shot | Screen | Composition |
| --- | --- | --- |
| `01-chat` | The finished task: tool cards with the diff and the test run, the markdown answer | The dithered π rising behind the device |
| `02-approval` | The deploy machine: the applied edit and a tool call waiting for approval | The approval card magnified over the device it came from |
| `03-tree` | The session tree of the same session, in the dock | A headline at display size over an offset device |
| `04-machines` | Machines, projects and sessions in the sidebar | The machine groups lifted out of the sidebar, no device |
| `05-terminal` | An SSH terminal on the machine (`git status`) | The terminal output as a field, a mono headline with a cursor |
| `06-files` | The edited file with its diff against HEAD | The diff magnified, the device bleeding off an edge |
| `07-agents` | The Agent Hub: the roster, or one subagent's transcript (Play phone, 10-inch) | The roster or transcript magnified beside an offset device |
| `08-config` | Machine configuration and the model list the machine serves | The model dialog magnified over the dimmed device |

`04-machines` is captured last, so the sidebar shows both machines with their sessions and what each is
waiting for. The tablet sets have no `02-approval`: from the iPad simulator and the tablet emulators, the
bastion hop to build-server did not come online within the test's 120 s.

## Outputs and their sizes

Cited from the stores' own help pages, read 2026-09-26:

| Surface | Size | Where |
| --- | --- | --- |
| App Store iPhone 6.9" | 1320×2868, no alpha | `ios/fastlane/screenshots/en-US/<NN>-<shot>-iphone69.png` |
| App Store iPad 13" | 2048×2732, no alpha | `ios/fastlane/screenshots/en-US/<NN>-<shot>-ipad13.png` |
| Play phone | 1080×1920 (9:16) | `android/fastlane/metadata/android/en-US/images/phoneScreenshots/` |
| Play 7-inch | 1920×1080 (16:9) | `.../images/sevenInchScreenshots/` |
| Play 10-inch | 2560×1440 (16:9) | `.../images/tenInchScreenshots/` |
| Play icon | 512×512, 32-bit PNG | `.../images/icon.png` |
| Play feature graphic | 1024×500, 24-bit PNG | `.../images/featureGraphic.png` |
| App Store marketing icon | 1024×1024, no alpha | `store/app-icon-1024.png` |

- Apple screenshot sizes: [Screenshot specifications](https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications).
  The iPad set is 2048×2732 (portrait, the orientation the simulator captures in), an accepted 13-inch
  resolution that is also on fastlane `deliver`'s own size list.
- Play assets: [Add preview assets to showcase your app](https://support.google.com/googleplay/android-developer/answer/9866151).
  Screenshots must be 1080–7680 px on the long edge and 16:9 or 9:16; tablets need at least four.
- Play asks whether each asset is AI-generated: nothing here is. Every image is a capture of the running app;
  only the model's answers are scripted, through the fake provider.

## Troubleshooting

- The app's progress log is the first place to look: `<app data container>/tmp/ompanion-shots.log` for a
  simulator (`xcrun simctl get_app_container <udid> com.edde746.ompanion data`), or
  `adb -s <serial> shell run-as com.edde746.ompanion cat cache/ompanion-shots.log` for an emulator.
- A run that produces no raw captures: check the driver log (`<raw>/<class>/driver.log`) and the run log
  (`<raw>/<class>/capture.log`).
- The simulator is only captured headless. Everything renders off screen; do not open Simulator.app, and do
  not unlock anything — nothing here needs a visible window.
- Machines and sessions are seeded on every run, and the app is installed fresh, so a stale database or a
  stale keychain entry cannot leak in.
