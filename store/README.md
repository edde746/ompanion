# Store submission checklist for ompanion

Apple App Store (iPhone + iPad), Google Play (phone + tablets) and the Microsoft Store (Windows). The Mac App
Store is out of scope: it needs a sandboxed build without "this computer", the `ssh` command's `~/.ssh/config`
reading and the SSH agent, none of which this build has.

Field-by-field console answers: `store/app-store.md` and `store/google-play.md`. Privacy policy:
<https://ompanion.app/privacy>, from `website/src/routes/privacy/`. Review demo host: `store/review-demo/`.

## Before anything else

- [ ] **Check the store URLs.** `https://ompanion.app`, `https://ompanion.app/privacy` and
      `https://github.com/edde746/ompanion/issues` must load in a private window before submitting; a dead
      privacy-policy URL is an automatic rejection in every store. The site deploys from `website/` through
      Cloudflare Workers Builds (`website/README.md`, Deploy).
- [ ] Confirm `pubspec.yaml` `version:` is `0.1.0+1` (the Microsoft Store needs 1.0.0 or later: its step 3)
      and the CI run for that commit is green.
- [ ] Fill in the fields in "Fields the user must fill in" below.

## Fields the user must fill in

| Field | Where it goes |
|---|---|
| Legal name or seller name | App Store Connect account. The listings use `Edvard Wikhall` as the copyright line (`ios/fastlane/metadata/copyright.txt`), taken from your Plezy App Store seller name — confirm it or replace it. A company instead needs a **D-U-N-S number** when enrolling as an organization. |
| Contact email | App Store Connect → App Review Information (`ios/fastlane/metadata/review_information/email_address.txt`) and Play Console → Store settings → Contact details |
| Contact phone | App Store Connect → App Review Information (`phone_number.txt`); optional on Play |
| Contact first and last name | App Store Connect → App Review Information (`first_name.txt`, `last_name.txt`) |
| Demo host, port, password | `ios/fastlane/metadata/review_information/notes.txt` (line 1) and `demo_password.txt` (user `review` in `demo_user.txt`); the Play "Sign-in details" text is in `store/google-play.md` §4. Values come from `store/review-demo/.env`, and the canonical console answers are `store/review-demo/README.md` §"Console answers". |
| Play developer account | Play Console: developer name shown on the listing, contact email, and the account's trader/DSA status for the EEA |
| Apple Developer Program team | `ios/Runner.xcodeproj` pins `DEVELOPMENT_TEAM = G88U5B5783`; clear it if that id should not be public and pick the team in Xcode once per Mac |
| Apple Team ID, App Store Connect API key (or Apple ID + app-specific password) | `.env`, see Build below |
| Play upload keystore + 4 GitHub secrets | `keytool -genkeypair -v -keystore upload-keystore.jks -alias ompanion -keyalg RSA -keysize 4096 -validity 10000`; keep the file and both passwords; set `ANDROID_KEYSTORE_BASE64`, `ANDROID_STORE_PASSWORD`, `ANDROID_KEY_PASSWORD`, `ANDROID_KEY_ALIAS` as repo secrets and in `android/key.properties` for local store builds |
| Play service-account JSON key | Google Cloud service account with the Play Developer API enabled, invited under Play Console → Users and permissions; point `PLAY_JSON_KEY_PATH` in `.env` at the JSON |
| App Store Connect API key, or Apple ID | `.env`: `APP_STORE_CONNECT_API_KEY_KEY_ID`, `APP_STORE_CONNECT_API_KEY_ISSUER_ID`, `APP_STORE_CONNECT_API_KEY_KEY_FILEPATH`, or `FASTLANE_USER` + `FASTLANE_APPLE_APPLICATION_SPECIFIC_PASSWORD`; without the API key, fastlane asks for the Apple ID password and a two-factor code |
| Firebase project and push relay | Push notifications need a Firebase project with the Android and iOS apps registered, the APNs auth key uploaded to it, `android/firebase.properties` and `ios/Flutter/Firebase.xcconfig` committed (README, Push notifications), and the relay running at `push.ompanion.app` with a service-account key that may only send FCM messages (`relay/README.md`). A build without the two config files ships without push, and the settings switch says so. |

## Google Play, in order

1. [ ] Play Console: create the app, name `ompanion: omp client`, English (US), app, free.
2. [ ] Accept Play App Signing; the keystore you generated is the **upload** key. Losing it means asking
       Google to reset it.
3. [ ] Store listing: paste `android/fastlane/metadata/android/en-US/{title,short_description,full_description}.txt`;
       upload `images/icon.png` and `images/featureGraphic.png`.
4. [ ] Store settings: category **Tools**, up to 5 tags from the console's list, contact details, privacy
       policy URL.
5. [ ] App content: complete **every** declaration, including the "no" ones — see `store/google-play.md` §3.
       Data safety: the two optional data types in `store/google-play.md` §7, target audience is **18 and over
       only**, ads **No**, news app **No**, government/financial/health **No**, Advertising ID **No**.
6. [ ] Content rating questionnaire: category "Utility, Productivity, Communication, or Other"; the answers
       in `store/google-play.md` §6.
7. [ ] Sign-in details: choose **"All or some functionality is restricted"** and paste the text from
       `store/review-demo/README.md` §"Console answers" (or `store/google-play.md` §4) with the demo host and
       password filled in.
8. [ ] Upload the first AAB by hand. Build it with `flutter build appbundle --release
       --dart-define=OMPANION_CHANNEL=play` (with `android/key.properties` in place, or the bundle is signed with
       the debug key) and upload `build/app/outputs/bundle/release/app-release.aab` in Play Console → Testing →
       Internal testing → Create new release. Play's API knows no package until the console has received a
       bundle, so `(cd android && fastlane release)` fails with "Package not found" before that
       ([fastlane's `upload_to_play_store` docs](https://github.com/fastlane/fastlane/blob/master/fastlane/lib/fastlane/actions/docs/upload_to_play_store.md)).
       Later releases use the lane: a draft/internal test by default, and it refuses to run without
       `android/key.properties`.
9. [ ] **New personal developer account only:** run a closed test with at least 12 testers opted in for 14
       continuous days, then apply for production access. Internal testing does not count. Recruit 15–20
       testers. Source: <https://support.google.com/googleplay/android-developer/answer/14151465>.
10. [ ] Upload the phone, 7-inch and 10-inch screenshots; release notes come from `changelogs/1.txt`.
11. [ ] Roll out to production.

## App Store, in order

1. [ ] App Store Connect: create the app record, bundle id `com.edde746.ompanion`, SKU of your choice
       (suggest `ompanion-ios-001`), English (US).
2. [ ] App information: name, subtitle, categories `DEVELOPER_TOOLS` + `PRODUCTIVITY`, copyright, content
       rights **Yes, with the necessary rights**, price free — `store/app-store.md` §2, §6.
3. [ ] Age rating questionnaire: answers in `store/app-store.md` §5; computed 9+, with the 18+ override
       option explained there.
4. [ ] App Privacy: "Yes", with the three data types in §7 (Device ID; Other Diagnostic Data; Other Data
       Types), none linked, no tracking; plus the privacy policy URL — §7.
5. [ ] Version 0.1.0: promotional text, description, keywords, support/marketing/privacy URLs, what's new.
6. [ ] Upload the build (`(cd ios && fastlane deploy_appstore)`).
7. [ ] Export compliance: encryption **yes**, "an industry standard algorithm, not provided within the Apple
       operating system" (SSH and TLS in Dart) — §8. Upload nothing unless France is in your territories.
8. [ ] App Review Information: contact fields, **Sign-in required = Yes** with user `review` and the demo
       password (`demo_user.txt`, `demo_password.txt`), and the notes from
       `ios/fastlane/metadata/review_information/notes.txt` with `<HOST>` and `<PASSWORD>` filled in.
9. [ ] Screenshots for the iPhone 6.9-inch set (1320×2868) and the iPad set (2048×2732).
10. [ ] Pricing and Availability: opt out of **iPhone and iPad Apps on Apple Silicon Mac** and **Apple Vision
        Pro**; both are on unless you deselect them — `store/app-store.md` §2.
11. [ ] **Bring the demo host up and leave it up for the whole review window** (`store/review-demo/up.sh`).
        Leave a way to be reached: App Review will ask, and a dead demo host reads as a broken app (2.1).
12. [ ] Submit for review.

## Microsoft Store, in order

The Store takes an `.msixbundle`: `windows/build-msix.ps1` packs the same `flutter build windows --release`
output as the GitHub release's zip, unsigned (the Store signs it after certification), and the Windows job
of Actions → Build uploads it as the artifact `ompanion-windows-msix-<sha>`. The Partner Center account is the one
that publishes Plezy: publisher `CN=AA9C53CB-AD3C-48DA-B3E3-D1E8986D4E25`, publisher display name `edde746`.

1. [ ] Partner Center → Apps and games → New product → **MSIX or PWA app**; reserve the name `ompanion`.
2. [ ] Product management → **Product identity**: copy `Package/Identity/Name` into `$IdentityName` in
       `windows/build-msix.ps1`. It holds `edde746.ompanion`, the value Partner Center is expected to assign,
       not one it has shown. Check that `Package/Identity/Publisher` and
       `Package/Properties/PublisherDisplayName` equal the script's `$Publisher` and `$PublisherDisplayName`.
       Store validation rejects the upload if any of the three differs by one character. Commit to main.
3. [ ] Set `pubspec.yaml` `version:` to 1.0.0 or later. Partner Center rejects a package version whose first
       field is 0 ([package version numbering](https://learn.microsoft.com/en-us/windows/apps/publish/publish-your-app/msix/app-package-requirements#package-version-numbering));
       the script maps `major.minor.patch+build` to `major.minor.patch.0`, so `0.1.0+1` becomes `0.1.0.0`, and the
       Windows job warns about it. The fourth field belongs to the Store, so every submission needs a new
       `major.minor.patch`: a build-number bump alone collides.
4. [ ] Run Actions → Build on main with Windows selected (a release run builds it too). Download the artifact
       `ompanion-windows-msix-<sha>` and unzip it: it holds `ompanion-windows.msixbundle`.
5. [ ] Start a submission. Pricing and availability: free, the markets you want.
6. [ ] Properties: category **Developer tools**; privacy policy URL `https://ompanion.app/privacy` (the one
       Play and the App Store get); website `https://ompanion.app`; support contact
       `https://github.com/edde746/ompanion/issues`.
7. [ ] Age ratings: the IARC questionnaire. If Play's content rating is done, choose the option to enter an
       existing IARC rating ID and paste Play's, so both stores carry one rating. Otherwise answer as
       `store/google-play.md` §6: category "Utility, Productivity, Communication, or Other", Language **Yes,
       mild**, every other question **No**, the same contact email.
8. [ ] Packages: upload `ompanion-windows.msixbundle`. Partner Center checks the identity and the version on
       upload.
9. [ ] Store listings, English (United States), from `store/microsoft/`: description (`description.txt`),
       what's new (`release_notes.txt`), product features (`features.txt`, one per line), the Desktop
       screenshots (`screenshots/*.png`, in file-name order), and under additional information the short
       description (`short_description.txt`), the search terms (`search_terms.txt`, one per line) and the
       copyright (`copyright.txt`). The limits: description 10,000 characters, what's new 1,500, up to 20
       features of 200, short description 1,000, up to 7 search terms of 30 with 21 words in all, copyright
       200 ("Length check" below measures them).
10. [ ] Submission options → **Restricted capabilities**: `runFullTrust` asks for a reason. Answer: "ompanion
        is a Flutter Win32 desktop app packaged as MSIX. It runs omp, the coding agent, and the user's
        shells on this computer as child processes, which needs a full-trust desktop process." **Notes for
        certification**: the App Review notes from `store/review-demo/README.md` §"Console answers" with
        `<HOST>` and `<PASSWORD>` filled in, and the demo host up for the whole certification window.
11. [ ] Submit to the Store.

## Where every asset lives

| Asset | Path |
|---|---|
| App Store listing texts | `ios/fastlane/metadata/en-US/*.txt` |
| App Store categories and copyright | `ios/fastlane/metadata/{primary_category,secondary_category,copyright}.txt` |
| App Store review notes and contacts | `ios/fastlane/metadata/review_information/*.txt` |
| App Store screenshots | `ios/fastlane/screenshots/en-US/*.png` |
| Play listing texts | `android/fastlane/metadata/android/en-US/*.txt` |
| Play release notes | `android/fastlane/metadata/android/en-US/changelogs/1.txt` |
| Play images | `android/fastlane/metadata/android/en-US/images/{icon.png,featureGraphic.png,phoneScreenshots/,sevenInchScreenshots/,tenInchScreenshots/}` |
| Microsoft Store package and manifest | `windows/build-msix.ps1` |
| Microsoft Store package images | `windows/msix/assets/`, generated by `scripts/generate_icons.sh` |
| Microsoft Store listing texts | `store/microsoft/*.txt` |
| Microsoft Store screenshots | `store/microsoft/screenshots/*.png` |
| Screenshot capture and compose tooling | `store/screenshots/` |
| Review demo host | `store/review-demo/` |
| Console answers | `store/app-store.md`, `store/google-play.md` |
| Privacy policy | `website/src/routes/privacy/+page.svelte`, served at <https://ompanion.app/privacy> |
| fastlane lanes | `ios/fastlane/Fastfile`, `android/fastlane/Fastfile` |

## Length check

Throwaway script, re-run after any edit to a listing text. It measures the stripped value the way `deliver`
and `supply` do: characters everywhere, **bytes** for the App Store keyword field and the App Review notes.
The notes are measured without their fill-in marker line and with a 64-byte host and a 24-character password
in place of `<HOST>` and `<PASSWORD>`, since that is the text that gets pasted. The Microsoft Store's product
features and search terms are one per line and measured per line.

```bash
python3 - <<'PY'
LIMITS = [
    ("App Store name",          "ios/fastlane/metadata/en-US/name.txt",            30,   "chars"),
    ("App Store subtitle",      "ios/fastlane/metadata/en-US/subtitle.txt",        30,   "chars"),
    ("App Store keywords",      "ios/fastlane/metadata/en-US/keywords.txt",       100,   "bytes"),
    ("App Store promo text",    "ios/fastlane/metadata/en-US/promotional_text.txt",170,  "chars"),
    ("App Store description",   "ios/fastlane/metadata/en-US/description.txt",    4000,  "chars"),
    ("App Store release notes", "ios/fastlane/metadata/en-US/release_notes.txt",  4000,  "chars"),
    ("Play title",              "android/fastlane/metadata/android/en-US/title.txt", 30, "chars"),
    ("Play short description",  "android/fastlane/metadata/android/en-US/short_description.txt", 80, "chars"),
    ("Play full description",   "android/fastlane/metadata/android/en-US/full_description.txt", 4000, "chars"),
    ("Play changelog 1",        "android/fastlane/metadata/android/en-US/changelogs/1.txt", 500, "chars"),
    ("App Review notes",        "ios/fastlane/metadata/review_information/notes.txt", 4000, "bytes"),
    ("MS Store description",    "store/microsoft/description.txt",               10000,  "chars"),
    ("MS Store what's new",     "store/microsoft/release_notes.txt",              1500,  "chars"),
    ("MS Store short descr.",   "store/microsoft/short_description.txt",          1000,  "chars"),
    ("MS Store copyright",      "store/microsoft/copyright.txt",                   200,  "chars"),
]
for label, path, limit, unit in LIMITS:
    s = open(path, encoding="utf-8").read().strip()
    if s.startswith("FILL"):
        s = s.split("\n", 1)[1].strip().replace("<HOST>", "x" * 64).replace("<PASSWORD>", "x" * 24)
    n = len(s.encode()) if unit == "bytes" else len(s)
    print(f"{'ok  ' if n <= limit else 'OVER'} {label:<24} {n:>5} {unit:<5} limit {limit}")
# Partner Center: up to 20 features of 200 characters; up to 7 search terms of 30 with 21 words in all.
features = open("store/microsoft/features.txt", encoding="utf-8").read().strip().split("\n")
terms = open("store/microsoft/search_terms.txt", encoding="utf-8").read().strip().split("\n")
for label, n, limit in [
    ("MS Store features", len(features), 20),
    ("MS Store longest feature", max(map(len, features)), 200),
    ("MS Store search terms", len(terms), 7),
    ("MS Store longest term", max(map(len, terms)), 30),
    ("MS Store term words", sum(len(t.split()) for t in terms), 21),
]:
    print(f"{'ok  ' if n <= limit else 'OVER'} {label:<24} {n:>5}       limit {limit}")
PY
```

Run it from the repository root. Output on this revision (2026-09-27):

```
ok   App Store name              20 chars limit 30
ok   App Store subtitle          21 chars limit 30
ok   App Store keywords          97 bytes limit 100
ok   App Store promo text       161 chars limit 170
ok   App Store description     3941 chars limit 4000
ok   App Store release notes    660 chars limit 4000
ok   Play title                  20 chars limit 30
ok   Play short description      70 chars limit 80
ok   Play full description     3864 chars limit 4000
ok   Play changelog 1           312 chars limit 500
ok   App Review notes          3829 bytes limit 4000
ok   MS Store description      4098 chars limit 10000
ok   MS Store what's new        332 chars limit 1500
ok   MS Store short descr.       85 chars limit 1000
ok   MS Store copyright          19 chars limit 200
ok   MS Store features           17       limit 20
ok   MS Store longest feature   104       limit 200
ok   MS Store search terms        7       limit 7
ok   MS Store longest term       19       limit 30
ok   MS Store term words         12       limit 21
```

The App Store and Play descriptions are inside their limit, the App Store one by 59 characters, and the
filled-in review notes by 171 bytes: re-run this after any wording change.

## Licence

- ompanion ships under plain GPLv3 (`LICENSE`), published in both stores by its sole copyright holder. A
  contribution merged under GPLv3 alone needs its author's permission before it ships through a store.
- The terminal is `xterm2` 5.2.0 (MIT) in every build, not `xterm3` (AGPL); `flutter_pty2` 2.0.0 (MIT)
  provides the PTY. No GPL/AGPL third-party code ships in any build (scan: `docs/research/licenses.md`).
- One copyleft package is in the resolved dependency graph: `dbus` 0.7.15 (MPL-2.0), reached only by
  `file_picker_linux` and `desktop_drop`'s Linux portal path. It does **not** ship in the store binaries: the
  release AOT snapshots of both `flutter build ios --release --no-codesign` and `flutter build apk --release`
  contain no `DBUS_SESSION_BUS_ADDRESS`, `org.freedesktop.DBus` or desktop_drop portal strings, while other
  strings from the same programs are present (`docs/research/licenses.md`). That closes the "what about the
  copyleft dependency" question a reviewer could ask.
- Console answers this settles: App Store **Content Rights** Yes, with the necessary rights (open-source
  licences for the bundled libraries and for omp); Play has no licence field, so the GPLv3 line lives in the
  description.
- In-app licence and privacy text: **Settings → About** (`lib/screens/settings/about_section.dart`) shows the
  app mark, the version, "A client for omp, the oh-my-pi coding agent", and rows for the privacy policy, the
  source, the issue tracker, the licence ("GPL-3.0"), omp itself and Flutter's
  bundled-package licence list. That is the in-app half of App Review guideline 5.1.1(i); keep those rows
  working when the repository URL changes.
- Not legal advice.

## Build-side facts

- **Data safety and App Privacy:** only after the user turns push notifications on, the Firebase SDKs send
  Google the Firebase installation ID (to deliver notifications) and the diagnostics their own disclosures list.
  No accounts, no analytics SDK, no crash reporting, no ads, no tracking. Notification text is end-to-end encrypted between the user's machine and
  phone. Other traffic goes to the user's own machines over SSH, plus two requests the user starts: the omp
  release from `github.com` when a machine cannot download it itself, and a web image after "Load image".
- **Export compliance:** `dartssh2` implements SSH in Dart (ChaCha20-Poly1305, AES-GCM and AES-CTR as
  `packages/omp_core/lib/src/ssh/ssh_link.dart` orders them; Curve25519/ECDH/DH key exchange; Ed25519, RSA
  and ECDSA signatures), and the omp download's HTTPS goes through `dart:io`'s BoringSSL. So the app is
  **not** limited to encryption Apple's OS provides. `ITSAppUsesNonExemptEncryption` is deliberately not set
  in `Info.plist`, so App Store Connect asks per submission: "uses encryption — yes", standard algorithms not
  provided by the OS, and nothing is uploaded unless France is in your territories. Apple notes that
  exempt-encryption apps may owe the U.S. BIS a year-end self-classification report.
- **iOS purpose strings now in `Info.plist`:** `NSLocalNetworkUsageDescription` (SSH to a machine on the same
  network triggers iOS local-network privacy) and `NSPhotoLibraryUsageDescription` (the bundled file picker
  references `PHPhotoLibrary`/`PHPickerViewController`, so validation requires the string). No camera,
  microphone, contacts, location, Bluetooth, motion, health, calendar or tracking API is linked.
- **No tracking manifest:** `ios/Runner/PrivacyInfo.xcprivacy` sets `NSPrivacyTracking` false, no tracking
  domains, no collected data types, and declares `NSPrivacyAccessedAPICategoryFileTimestamp` reason `C617.1`
  and `NSPrivacyAccessedAPICategoryDiskSpace` reason `E174.1`. The Firebase products linked for push bring
  their own manifests, which declare the data types in `store/app-store.md` §7.
- **Android target API level:** Flutter 3.47.1 defaults (compileSdk 36, targetSdk 36, minSdk 24) already meet
  Play's requirement to target API 36 for new apps and updates from 31 August 2026. The permissions are
  `INTERNET`, `POST_NOTIFICATIONS` (asked for when push is turned on) and the normal ones Firebase Messaging and
  flutter_local_notifications add (`store/google-play.md` §3); `android:allowBackup` is false.
- **Uploads come from the Mac with fastlane, not CI:** `(cd ios && fastlane deploy_appstore)` and
  `(cd android && fastlane release)`, except Play's first bundle, which goes through the console by hand
  (checklist step 8). A brand-new Play app accepts only a draft release, so the lane's default is a
  draft/internal test; the Fastfile's `track:production release_status:completed` publishes.
- **iOS screenshots must be a pixel size fastlane knows**; an unknown size aborts that step even when App
  Store Connect would accept it. The sets are 1320×2868 (iPhone 6.9-inch, portrait) and 2048×2732 (iPad
  13-inch, portrait), both on `deliver`'s list.
- **The Microsoft Store package is the GitHub build, packaged:** the `.msixbundle` holds the same files as
  `ompanion-windows-x64.zip` (the `direct` channel, nothing gated) plus the manifest, `resources.pri` and the
  tile and taskbar images from `windows/msix/assets/`. Capabilities: `runFullTrust`, `internetClient` and
  `privateNetworkClientServer` (SSH to machines on the LAN). Installed with a test signature on the Windows
  runner, the app starts from its read-only package directory, probes "this computer", and keeps its database
  in the package's private `LocalCache`. The processes it starts carry no package identity (measured on the
  probe, the omp install and omp itself; the terminal's ConPTY spawn sets no desktop-app policy either), so they
  see the real AppData: "Install omp" on "this computer" put omp in the real `%LOCALAPPDATA%\omp`, where a
  WMI-started process, as a detached run is, ran it. MinVersion is Windows 10 1809 (10.0.17763).

## Review demo host

`store/review-demo/` is a throwaway SSH host for App Review and Play review: Docker Compose with OpenSSH
(user `review`, password auth), omp 18.3.1, and `harness/fake-provider` in `--demo` mode as the only model
provider (neutral models "Fast"/"Reasoning"). `./setup.sh` generates the password into a gitignored `.env`,
`./up.sh` builds and prints the host/port/credentials, `./reset.sh` puts the reviewer's home back, and
`./down.sh --clean` deletes the home and host keys. It publishes one port (default 22222) and everything —
security model, reviewer steps, the exact App Store Connect and Play Console answers — is in
`store/review-demo/README.md`. Run it on a throwaway VPS shortly before review and destroy that VPS
afterwards.

The App Review notes paragraph and the Play "App access" answer are written out verbatim in
`store/review-demo/README.md`, section "Console answers" — copy them from there so the host, port and
password stay in one place (only `<HOST>` and `<PASSWORD>` need filling). What is already in this repository:
`ios/fastlane/metadata/review_information/notes.txt` (that text plus the guideline paragraphs) and
`demo_user.txt` / `demo_password.txt` (user `review` and the password).

Caveats to keep honest in the listings: the demo machine has omp **preinstalled** and answers with canned
turns only, and its model picker shows the two neutral demo models, so nothing implies a real provider or a
real subscription. The omp install the listings claim is real (`packages/omp_core/lib/src/host/install.dart`
and `lib/screens/sessions/install_omp_dialog.dart`: omp 18.3.1 from its GitHub release, SHA-256 checked on
the machine) but is not what the demo shows.

## Screenshots and graphics

Paths and sizes, all PNG; no alpha except the Play icon, which Play takes as a 32-bit PNG with alpha:

| Asset | Path | Size |
|---|---|---|
| App Store iPhone | `ios/fastlane/screenshots/en-US/<NN>-<slug>-iphone69.png` | 1320×2868 (iPhone 17 Pro Max, portrait) |
| App Store iPad | `ios/fastlane/screenshots/en-US/<NN>-<slug>-ipad13.png` | 2048×2732 (iPad Pro 13-inch, portrait) |
| Play icon | `android/fastlane/metadata/android/en-US/images/icon.png` | 512×512, full-bleed from `assets/ompanion.svg` |
| Play feature graphic | `images/featureGraphic.png` | 1024×500 |
| Play phone | `images/phoneScreenshots/<NN>-<slug>.png` | 1080×1920 |
| Play 7-inch | `images/sevenInchScreenshots/` | 1920×1080 |
| Play 10-inch | `images/tenInchScreenshots/` | 2560×1440 |

`store/screenshots/capture.sh <ios-phone|ios-ipad|play-phone|play-7in|play-10in>` boots the simulator or
emulator headlessly, seeds the demo host, runs `flutter drive`
(`integration_test/store_screenshots_test.dart`, driver `integration_test/driver/store_driver.dart`; screenshots are taken
from the host so the real status bar is in the picture), then `store/screenshots/compose.py` composes the
store images from `store/screenshots/captions.json`. The app's own SSH session goes to a Linux host with a real
omp 18.3.1 and the fake provider; the model list is neutral ("Fast", "Reasoning"), no vendor names.

**Not in any capture, so the listings must not claim them as screenshot evidence:** "this computer"
(desktop-only), mesh-VPN peer import, SSH-config import, the omp install-on-a-host flow, OAuth provider
sign-in, Windows hosts, dropping files, and the light theme. Also not captured: usage limits, MCP/plugins/
skills panes, compaction, branching, pause/resume, steer/queue.

Desktop-only features are therefore **out of both listing descriptions entirely** (this is also App Review
guideline 2.3.10: keep the metadata about the platforms the app is on). The descriptions do claim the mobile
features the captures do not happen to show (usage, MCP/plugins/skills, steer/queue); that is
honest description, not invented capability, and the omp-install claim is real on mobile — it just is not what
the demo host shows.

AI declaration for Play's per-asset question: **No.** Every pixel is a real capture of the real app against a
real omp; only the model output is scripted through the fake provider, and the composed headline text is plain
type, not generated imagery.

What the captures prove: the app runs a real omp session over SSH from a phone or tablet and shows its
transcript, tool cards with diffs, approvals, questions, terminal, files, subagents, todos and configuration.
