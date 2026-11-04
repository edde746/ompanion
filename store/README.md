# Store submission checklist for ompanion

Apple App Store (iPhone + iPad), Google Play (phone + tablets) and the Microsoft Store (Windows). The Mac App
Store is out of scope: it needs a sandboxed build without "this computer", the `ssh` command's `~/.ssh/config`
reading and the SSH agent, none of which this build has.

Field-by-field console answers: `store/app-store.md` and `store/google-play.md`. Privacy policy:
<https://ompanion.app/privacy>, from `website/src/routes/privacy/`. Review demo host: `store/review-demo/`.
The checklists below are each store's first submission; every later version goes out with one command (Later
releases).

## Before anything else

- [ ] **Check the store URLs.** `https://ompanion.app`, `https://ompanion.app/privacy` and
      `https://github.com/edde746/ompanion/issues` must load in a private window before submitting; a dead
      privacy-policy URL is an automatic rejection in every store. The site deploys from `website/` through
      Cloudflare Workers Builds (`website/README.md`, Deploy).
- [ ] Confirm `VERSION` (`<major.minor.patch>+<build>`, which every platform ships) is the release you mean to
      submit, and the CI run for that commit is green.
- [ ] Fill in the fields in "Fields the user must fill in" below.

## Fields the user must fill in

| Field | Where it goes |
|---|---|
| Legal name or seller name | App Store Connect account. The listings use `Edvard Wikhall` as the copyright line (`store/fastlane/ios/metadata/copyright.txt`), taken from your Plezy App Store seller name — confirm it or replace it. A company instead needs a **D-U-N-S number** when enrolling as an organization. |
| Contact email | App Store Connect → App Review Information (`store/fastlane/ios/metadata/review_information/email_address.txt`) and Play Console → Store settings → Contact details |
| Contact phone | App Store Connect → App Review Information (`phone_number.txt`); optional on Play |
| Contact first and last name | App Store Connect → App Review Information (`first_name.txt`, `last_name.txt`) |
| Demo password | `demo_password.txt` (App Store Connect's Sign-In Information); the user is `root` (`demo_user.txt`). `store/fastlane/ios/metadata/review_information/notes.txt` holds no password: its step 1 points App Review to Sign-In Information, and the host `217.160.119.181` is already in it. The Play "Sign-in details" text is in `store/google-play.md` §4. The password is `REVIEW_PASSWORD` in `store/review-demo/.env`, and the canonical console answers are `store/review-demo/README.md` §"Console answers". |
| Play developer account | Play Console: developer name shown on the listing, contact email, and the account's trader/DSA status for the EEA |
| Apple Developer Program team | `shells/apple/project.yml` pins `DEVELOPMENT_TEAM: G88U5B5783`; clear it if that id should not be public and pick the team in Xcode once per Mac |
| Apple Team ID, App Store Connect API key (or Apple ID + app-specific password) | `.env`, see Build below |
| Play upload keystore + 4 GitHub secrets | `keytool -genkeypair -v -keystore upload-keystore.jks -alias ompanion -keyalg RSA -keysize 4096 -validity 10000`; keep the file and both passwords; set `ANDROID_KEYSTORE_BASE64`, `ANDROID_STORE_PASSWORD`, `ANDROID_KEY_PASSWORD`, `ANDROID_KEY_ALIAS` as repo secrets, and for local store builds put the `.jks` in `shells/android/app/` and its passwords and alias in `shells/android/key.properties` |
| Play service-account JSON key and track | Google Cloud service account with the Play Developer API enabled, invited under Play Console → Users and permissions; point `PLAY_JSON_KEY_PATH` in `.env` at the JSON. `PLAY_TRACK` in `.env` is the track the release pipeline releases on (Later releases) |
| App Store Connect API key, or Apple ID | `.env`: `APP_STORE_CONNECT_API_KEY_KEY_ID`, `APP_STORE_CONNECT_API_KEY_ISSUER_ID`, `APP_STORE_CONNECT_API_KEY_KEY_FILEPATH`, or `FASTLANE_USER` + `FASTLANE_APPLE_APPLICATION_SPECIFIC_PASSWORD`; without the API key, fastlane asks for the Apple ID password and a two-factor code, and the release pipeline does not run |
| Microsoft Store Submission API | `.env`: `MSSTORE_TENANT_ID`, `MSSTORE_CLIENT_ID`, `MSSTORE_CLIENT_SECRET` of the Azure AD application Plezy's pipeline uses (same Partner Center account), `MSSTORE_APP_ID=9P9DVTKZ3SB9`, and `MSSTORE_PRICE_ID` (Later releases) |
| Firebase project and push relay | Push notifications need a Firebase project with the Android and iOS apps registered, the APNs auth key uploaded to it, `shells/android/firebase.properties` and `shells/apple/Firebase.xcconfig` committed (`docs/contracts/push.md`), and the relay running at `push.ompanion.app` with a service-account key that may only send FCM messages (`relay/README.md`). A build without the two config files ships without push, and the settings switch says so. |

## Google Play, in order

1. [ ] Play Console: create the app, name `ompanion: omp client`, English (US), app, paid (US$4.99).
2. [ ] Accept Play App Signing; the keystore you generated is the **upload** key. Losing it means asking
       Google to reset it.
3. [ ] Store listing: paste `store/fastlane/android/metadata/android/en-US/{title,short_description,full_description}.txt`;
       upload `images/icon.png` and `images/featureGraphic.png`.
4. [ ] Store settings: category **Tools**, up to 5 tags from the console's list, contact details, privacy
       policy URL.
5. [ ] App content: complete **every** declaration, including the "no" ones — see `store/google-play.md` §3.
       Data safety: the two optional data types in `store/google-play.md` §7, target audience is **18 and over
       only**, ads **No**, news app **No**, government/financial/health **No**, Advertising ID **No**.
6. [ ] Content rating questionnaire: category "Utility, Productivity, Communication, or Other"; the answers
       in `store/google-play.md` §6.
7. [x] Sign-in details: choose **"All or some functionality is restricted"**, one set named `Demo server`
       with username `root` and the demo password, and in "Any other information" (500 characters at most)
       the text in `store/google-play.md` §4.
8. [ ] Upload the first AAB by hand. Build it with `shells/android/build.sh --release --core` (with
       `shells/android/key.properties` in place, or the bundle is signed with the debug key) and upload
       `build/android/app-release.aab`, the `play` channel, in Play Console → Testing → Internal testing → Create
       new release. Play's API knows no package until the console has received a bundle, so every API upload (the
       release pipeline's and `fastlane android release`) fails with "Package not found" before that
       ([fastlane's `upload_to_play_store` docs](https://github.com/fastlane/fastlane/blob/master/fastlane/lib/fastlane/actions/docs/upload_to_play_store.md)).
       Later releases go through the release pipeline (Later releases), which uploads the bundle the release run
       built and signed in CI. The lane (run from `store/`) stays as the manual path: a draft/internal test by
       default, and it refuses to run without `shells/android/key.properties`.
9. [ ] **New personal developer account only:** run a closed test with at least 12 testers opted in for 14
       continuous days, then apply for production access. Internal testing does not count. Recruit 15–20
       testers. Source: <https://support.google.com/googleplay/android-developer/answer/14151465>. The closed
       track's testers are the Google Group `edde-testers@googlegroups.com`: anyone who joins it
       (<https://groups.google.com/g/edde-testers>) and opts in at
       <https://play.google.com/apps/testing/com.edde746.ompanion> can install the app. The website's Google Play
       button opens a dialog with those two steps (`https://ompanion.app/#google-play`, which the README links).
10. [ ] Upload the phone, 7-inch and 10-inch screenshots; release notes come from `changelogs/1.txt`.
11. [ ] Roll out to production.

## App Store, in order

1. [ ] App Store Connect: create the app record, bundle id `com.edde746.ompanion`, SKU of your choice
       (suggest `ompanion-ios-001`), English (US).
2. [ ] App information: name, subtitle, categories `DEVELOPER_TOOLS` + `PRODUCTIVITY`, copyright, content
       rights **Yes, with the necessary rights**, price US$4.99 — `store/app-store.md` §2, §6.
3. [ ] Age rating questionnaire: answers in `store/app-store.md` §5; computed 9+, with the 18+ override
       option explained there.
4. [ ] App Privacy: "Yes", with the three data types in §7 (Device ID; Other Diagnostic Data; Other Data
       Types), none linked, no tracking; plus the privacy policy URL — §7.
5. [ ] Version 1.0.0: promotional text, description, keywords, support/marketing/privacy URLs, what's new.
6. [ ] Upload the build (`fastlane ios deploy_appstore`, run from `store/`; it builds with
       `shells/apple/build.sh --ipa --core`).
7. [ ] Export compliance: encryption **yes**, "an industry standard algorithm, not provided within the Apple
       operating system" (SSH and TLS in the app's Go core) — §8. Upload nothing unless France is in your territories.
8. [x] App Review Information: contact fields, **Sign-in required = Yes** with user `root` and the demo
       password (`demo_user.txt`, `demo_password.txt`), and the notes: the whole of
       `store/fastlane/ios/metadata/review_information/notes.txt`, unchanged.
9. [ ] Screenshots for the iPhone 6.9-inch set (1320×2868) and the iPad set (2048×2732).
10. [ ] Pricing and Availability: opt out of **iPhone and iPad Apps on Apple Silicon Mac** and **Apple Vision
        Pro**; both are on unless you deselect them — `store/app-store.md` §2.
11. [ ] **Keep the demo server up for the whole review window.** Before submitting, run
        `ssh root@217.160.119.181 ompanion-demo-reset` and `verify.ts` (`store/review-demo/README.md`,
        Commands), and check that the OpenRouter key has credit left. Leave a way to be reached: App Review
        will ask, and a dead demo server reads as a broken app (2.1).
12. [ ] Submit for review.

## Microsoft Store, in order

The Store takes an `.msixbundle`: `shells/windows/msix/build-msix.ps1` packs the same `shells/windows/build.sh`
output as the GitHub release's zip, unsigned (the Store signs it after certification), and CI's package-windows
job uploads it as the artifact `ompanion-windows-msix-<sha>`. The Partner Center account is the one
that publishes Plezy: publisher `CN=AA9C53CB-AD3C-48DA-B3E3-D1E8986D4E25`, publisher display name `edde746`.

1. [x] Partner Center → Apps and games → New product → **MSIX or PWA app**; the name `ompanion` is reserved:
       Store ID `9P9DVTKZ3SB9`.
2. [x] Product management → **Product identity** matches `shells/windows/msix/build-msix.ps1`: `Package/Identity/Name`
       `edde746.ompanion`, the publisher above, package family name `edde746.ompanion_13q3sv6jzathm`. Store
       validation rejects the upload if any of the three differs by one character.
3. [x] `VERSION` was 1.0.0+1 for the first submission, which packs as `1.0.0.0`: the script maps
       `major.minor.patch+build` to `major.minor.patch.0`, and Partner Center rejects a package version whose first field is 0
       ([package version numbering](https://learn.microsoft.com/en-us/windows/apps/publish/publish-your-app/msix/app-package-requirements#package-version-numbering)),
       which the Windows job warns about. The fourth field belongs to the Store, so every submission needs a new
       `major.minor.patch`: a build-number bump alone collides.
4. [ ] Run Actions → Build on main with Windows selected (a release run builds it too). Download the artifact
       `ompanion-windows-msix-<sha>` and unzip it: it holds `ompanion-windows.msixbundle`.
5. [ ] Start a submission. Pricing and availability: **US$4.99** (the owner's choice, as on the App Store and Play;
       the GitHub build is free), no free trial, every market including future ones, public and discoverable,
       published automatically after certification. No store listing says "free".
6. [ ] Properties: category **Developer tools**; privacy policy URL `https://ompanion.app/privacy` (the one
       Play and the App Store get); website `https://ompanion.app`; support contact
       `https://github.com/edde746/ompanion/issues`. Product declarations:
       - **Accesses, collects or transmits personal information: yes.** The app sends SSH user names,
         passwords, keys and the user's prompts and files to the user's own machines; policy 10.5.1 then asks
         for the privacy policy URL above.
       - **Incorporates generative AI features: yes.** The chat shows live output of the AI models the user's
         omp calls, which is policy 11.16's "dynamic content created by generative AI models in response to
         user inputs". Its four duties: the description's "AI-generated content" section discloses it; this
         declaration notes it; the content is the user's own agent's output on the user's own machine, shown
         to nobody else; users report content to the developer from Settings → About → Report an issue (the
         GitHub tracker), which the description names.
       - The rest stay at their defaults; "tested to meet accessibility guidelines" stays unticked.
7. [ ] Age ratings: the IARC questionnaire. If Play's content rating is done, choose the option to enter an
       existing IARC rating ID and paste Play's, so both stores carry one rating. Otherwise answer as
       `store/google-play.md` §6: category "Utility, Productivity, Communication, or Other", Language **Yes,
       mild**, every other question **No**. The answers preview as ESRB Everyone 10+, PEGI 3, IARC 3+; saving
       them accepts IARC's terms of use, which is the owner's to accept.
8. [ ] Packages: upload `ompanion-windows.msixbundle`. Partner Center checks the identity and the version on
       upload.
9. [ ] Store listings, English (United States), from `store/microsoft/`: description (`description.txt`),
       what's new (`release_notes.txt`), product features (`features.txt`, one per line), the Desktop
       screenshots (`screenshots/*.png`, in file-name order), and under additional information the short
       description (`short_description.txt`), the search terms (`search_terms.txt`, one per line) and the
       copyright (`copyright.txt`). The limits: description 10,000 characters, what's new 1,500, up to 20
       features of 200, short description 1,000, up to 7 search terms of 30 with 21 words in all, copyright
       200 ("Length check" below measures them).
10. [ ] Submission options shows no **Restricted capabilities** section for this package, so `runFullTrust` asks
        for no reason (checked 2026-09-27 with the release bundle validated). If a later submission shows one,
        answer: "ompanion is a Win32 desktop app (a WebView2 window over a native core) packaged as MSIX. It runs
        omp, the coding agent, and the user's shells on this computer as child processes, which needs a full-trust
        desktop process." **Notes for
        certification** live under Supplemental info → **Additional Testing Information**: the Partner Center
        text from `store/review-demo/README.md` §"Console answers" as the description, the password in the page's
        Credentials table (Partner Center refuses a description that contains credentials), and the demo server
        up for the whole certification window.
11. [ ] Submit to the Store.

## Later releases

Every version after the first goes to the three stores and GitHub with `scripts/release/deploy.py` (README,
Releasing → The stores); the checklists above are not repeated.

1. Write the GitHub release notes in `store/release-notes/<version>.md`. Edit a store's notes by hand when it
   should say something else: `store/fastlane/android/metadata/android/en-US/changelogs/<build>.txt` (Play, 500
   characters; `<build>` is `VERSION`'s build number plus one), `store/fastlane/ios/metadata/en-US/release_notes.txt`
   (App Store, 4,000) and `store/microsoft/release_notes.txt` (Microsoft Store, 1,500). The pipeline keeps a file
   that is new or changed since the last release tag and fits its limit, and generates the others from the GitHub notes
   with `claude`. "Length check" below measures them.
2. Fill `.env` (README, The stores). `PLAY_TRACK` is `alpha`, the default closed-testing track, while the app
   has no production access (Google Play step 9), then `production`. `MSSTORE_PRICE_ID` is below.
3. `uv run scripts/release/deploy.py release --version <version> --dry-run` prints every action; the same
   command without `--dry-run` releases. It asks before it publishes the GitHub release.
4. App Store review: with `--submit`, the `asc` phase submits the version for review after asking whether App
   Store step 11 (demo server reset, `verify.ts`, OpenRouter credit) is done. Without `--submit`, or after a no,
   the phase stays pending: a later `release --submit` resumes it, or submit in App Store Connect after step 11.
   Play review and Microsoft Store certification sign in to the same demo server: keep it up through them too.
   App Store Connect copies the review information (demo account, notes, contact) to a new version by itself,
   and `Info.plist` answers export compliance (`store/app-store.md` §8).
5. The `ios` phase signs through the Apple ID signed in to Xcode (Settings → Accounts), with team
   `G88U5B5783`'s cloud-managed Apple Distribution certificate: the App Store Connect API key gets "Cloud
   signing permission error". Without such an account the export step of `shells/apple/build.sh --ipa` has no
   distribution certificate to sign with, and the phase stops.

Microsoft Store pricing: Partner Center's pricing page stores US$4.99 as a base price that the Submission API
reads back as `Base` and refuses on PUT, and a submission without a price publishes the app for free (Plezy
2.19.1 shipped at $0 that way). `MSSTORE_PRICE_ID` names the tier instead; the `msstore` phase accepts only a
`TierNNNN` id and checks the tier the API stored before it commits. US$4.99 is `Tier1052`: Tier1012 to Tier1102 are
$0.99 to $9.99 in steps of $0.10, in the table a Microsoft maintainer posted on
[msstore-cli#175](https://github.com/microsoft/msstore-cli/pull/175) on 2026-09-23 (Partner Center's Pricing and
availability → view conversion table also lists the ids). A tier is one base price spread to every market by that
table; ompanion's only market overrides are Lebanon and Western Sahara as not available (checked 2026-10-07), which
the cloned submission keeps.

The Submission API only works on a product with one submission completed in Partner Center
([create an app submission](https://learn.microsoft.com/en-us/windows/uwp/monetize/create-an-app-submission)),
so the `msstore` phase works from the second version on. A submission still pending in Partner Center stops
it unless `--msstore-replace-pending` deletes that submission.

## Where every asset lives

| Asset | Path |
|---|---|
| App Store listing texts | `store/fastlane/ios/metadata/en-US/*.txt` |
| App Store categories and copyright | `store/fastlane/ios/metadata/{primary_category,secondary_category,copyright}.txt` |
| App Store review notes and contacts | `store/fastlane/ios/metadata/review_information/*.txt` |
| App Store screenshots | `store/fastlane/ios/screenshots/en-US/*.png` |
| Play listing texts | `store/fastlane/android/metadata/android/en-US/*.txt` |
| Play release notes | `store/fastlane/android/metadata/android/en-US/changelogs/<build number>.txt` |
| GitHub release notes | `store/release-notes/<version>.md` |
| Play images | `store/fastlane/android/metadata/android/en-US/images/{icon.png,featureGraphic.png,phoneScreenshots/,sevenInchScreenshots/,tenInchScreenshots/}` |
| Microsoft Store package and manifest | `shells/windows/msix/build-msix.ps1` |
| Microsoft Store package images | `shells/windows/msix/assets/`, generated by `scripts/generate_icons.sh` |
| Microsoft Store listing texts | `store/microsoft/*.txt` |
| Microsoft Store screenshots | `store/microsoft/screenshots/*.png` |
| Screenshot capture and compose tooling | `store/screenshots/` |
| Review demo host | `store/review-demo/` |
| Console answers | `store/app-store.md`, `store/google-play.md` |
| Privacy policy | `website/src/routes/privacy/+page.svelte`, served at <https://ompanion.app/privacy> |
| fastlane lanes | `store/fastlane/Fastfile` (run from `store/`: `fastlane ios deploy_appstore`, `fastlane android release`) |
| Release pipeline | `scripts/release/deploy.py` |

## Length check

Throwaway script, re-run after any edit to a listing text. It measures the stripped value the way `deliver`
and `supply` do: characters everywhere, **bytes** for the App Store keyword field and the App Review notes.
The notes file is the exact text of the field. The Microsoft Store's product features and search terms
are one per line and measured per line. The Play changelog it measures is the newest, the one with the highest
build number. The three release-notes limits (Play 500, App Store 4,000, Microsoft Store 1,500) are the ones
`scripts/release/deploy.py` enforces.

```bash
python3 - <<'PY'
from pathlib import Path
changelog = max(Path("store/fastlane/android/metadata/android/en-US/changelogs").glob("*.txt"), key=lambda p: int(p.stem))
LIMITS = [
    ("App Store name",          "store/fastlane/ios/metadata/en-US/name.txt",            30,   "chars"),
    ("App Store subtitle",      "store/fastlane/ios/metadata/en-US/subtitle.txt",        30,   "chars"),
    ("App Store keywords",      "store/fastlane/ios/metadata/en-US/keywords.txt",       100,   "bytes"),
    ("App Store promo text",    "store/fastlane/ios/metadata/en-US/promotional_text.txt",170,  "chars"),
    ("App Store description",   "store/fastlane/ios/metadata/en-US/description.txt",    4000,  "chars"),
    ("App Store release notes", "store/fastlane/ios/metadata/en-US/release_notes.txt",  4000,  "chars"),
    ("Play title",              "store/fastlane/android/metadata/android/en-US/title.txt", 30, "chars"),
    ("Play short description",  "store/fastlane/android/metadata/android/en-US/short_description.txt", 80, "chars"),
    ("Play full description",   "store/fastlane/android/metadata/android/en-US/full_description.txt", 4000, "chars"),
    (f"Play changelog {changelog.stem}", str(changelog),                         500,  "chars"),
    ("App Review notes",        "store/fastlane/ios/metadata/review_information/notes.txt", 4000, "bytes"),
    ("MS Store description",    "store/microsoft/description.txt",               10000,  "chars"),
    ("MS Store what's new",     "store/microsoft/release_notes.txt",              1500,  "chars"),
    ("MS Store short descr.",   "store/microsoft/short_description.txt",          1000,  "chars"),
    ("MS Store copyright",      "store/microsoft/copyright.txt",                   200,  "chars"),
]
for label, path, limit, unit in LIMITS:
    s = open(path, encoding="utf-8").read().strip()
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

Run it from the repository root. Output on this revision (2026-11-02, with the 1.2.1 notes):

```
ok   App Store name              20 chars limit 30
ok   App Store subtitle          21 chars limit 30
ok   App Store keywords          88 bytes limit 100
ok   App Store promo text       139 chars limit 170
ok   App Store description     3932 chars limit 4000
ok   App Store release notes    823 chars limit 4000
ok   Play title                  20 chars limit 30
ok   Play short description      70 chars limit 80
ok   Play full description     3855 chars limit 4000
ok   Play changelog 4           433 chars limit 500
ok   App Review notes          3980 bytes limit 4000
ok   MS Store description      4394 chars limit 10000
ok   MS Store what's new        570 chars limit 1500
ok   MS Store short descr.       85 chars limit 1000
ok   MS Store copyright          19 chars limit 200
ok   MS Store features           17       limit 20
ok   MS Store longest feature   104       limit 200
ok   MS Store search terms        7       limit 7
ok   MS Store longest term       19       limit 30
ok   MS Store term words         12       limit 21
```

The App Store and Play descriptions are inside their limit, the App Store one by 68 characters, and the
review notes by 20 bytes: re-run this after any wording change.

## Licence

- ompanion ships under plain GPLv3 (`LICENSE`), published in both stores by its sole copyright holder. A
  contribution merged under GPLv3 alone needs its author's permission before it ships through a store.
- What ships, per target, with every licence and its evidence: `docs/research/licenses.md` (recorded 2026-11-02,
  `VERSION` 1.2.1+4). In short: the Go core links Go's standard library, `golang.org/x/{crypto,sys,mobile}`,
  `pkg/sftp` and `kr/fs` (BSD), plus `creack/pty` (MIT) on macOS and Linux and `charmbracelet/x/conpty` (MIT) on
  Windows. The page bundles 49 npm packages (MIT, plus Apache-2.0, BSD-2, ISC and the OFL-1.1 JetBrains Mono),
  the KaTeX fonts (OFL-1.1) and 64 syntax grammars (MIT, BSD-3, Apache-2.0, the TextMate bundle licence, and
  `hcl`/`terraform` under MPL-2.0); the terminal is xterm.js 6.0.0 (MIT). The iOS app links Firebase and its
  dependencies (Apache-2.0, MIT, Zlib); the Android app's release classpath is Apache-2.0 and BSD-3 libraries plus
  7 Google Play services/Firebase artifacts under Google's proprietary Android SDK licence; Windows ships the
  WebView2 loader (Microsoft's BSD-style licence), LLVM's runtimes (Apache-2.0 with LLVM exception) and the
  mingw-w64 runtime notices.
- **No GPL, LGPL or AGPL third-party code, and no code without a known licence, ships in a store build.** The
  `nginx` grammar (GPL-3.0) and the `glsl` grammar (no licence) are left out of the bundle (fences in those
  languages show as plain text), and both licence writers fail the build on a GPL-family licence id or an entry
  without a licence text. The two MPL-2.0 grammars ship; MPL-2.0 is per-file copyleft, met because ompanion's
  source, those files included, is public. On Linux (not a store build) WebKitGTK, GTK 4, libsoup, GLib and
  libsecret are LGPL, linked dynamically from the system or the Flatpak runtime, not bundled. The remaining risks
  (Wine-derived GUID data in the Windows link, GCC/glibc start files on Linux) are listed in
  `docs/research/licenses.md`, "Copyleft check".
- Console answers this settles: App Store **Content Rights** Yes, with the necessary rights (open-source
  licences for the bundled libraries and for omp); Play has no licence field, so the GPLv3 line lives in the
  description.
- In-app licence and privacy text: **Settings → About** (`ui/src/app/screens/settings/about_section.tsx`) shows
  the app mark, the version, "A client for omp, the oh-my-pi coding agent" (omp's repository), and rows for the
  privacy policy, the source, "Report an issue", the licence ("GPL-3.0") and "Open-source licenses"
  (`licenses_page.tsx`, from `licenses.json`: `ui/vite.config.ts` writes the page's group and `core/cmd/licenses`,
  run by each shell's build script, the other two). That is the in-app half of App
  Review guideline 5.1.1(i); keep those rows working when the repository URL changes. The "Open-source licenses"
  page shows, with their licence texts, three groups from that file: Interface (the page's packages, grammars,
  fonts and vendored code, every build), Core (the Go modules the build links) and Platform (what the shell links:
  Firebase on iOS, the Android classpath, Sparkle on macOS, the Windows runtimes). What the operating system
  provides (system frameworks, Android System WebView, the WebView2 Runtime) is not bundled and not listed.
- Not legal advice.

## Build-side facts

- **Data safety and App Privacy:** only after the user turns push notifications on, the Firebase SDKs send
  Google the Firebase installation ID (to deliver notifications) and the diagnostics their own disclosures list
  (iOS: firebase-ios-sdk 12.19.2, FirebaseCore, FirebaseInstallations and FirebaseMessaging; Android: firebase-bom
  34.19.0, firebase-messaging 25.1.3 and firebase-installations 19.1.2). No accounts, no analytics SDK, no crash
  reporting, no ads, no tracking. Notification text is end-to-end encrypted between the user's machine and
  phone. Other traffic goes to the user's own machines over SSH, plus two requests the user starts, both made by
  the core (`core/net.go`): the omp release from `github.com` when a machine cannot download it itself, and a web
  image after "Load image". The page itself loads nothing from the network: its content security policy
  (`ui/index.html`) allows only the app's own files, and the shells send any other navigation to the browser.
- **Export compliance:** the Go core implements SSH with `golang.org/x/crypto/ssh` v0.58.0 at its default
  algorithms (`core/ssh_dial.go` sets none): AES-GCM, ChaCha20-Poly1305 and AES-CTR; HMAC-SHA2/SHA1;
  ML-KEM-768+X25519, Curve25519, ECDH and DH key exchange; Ed25519, ECDSA and RSA. Key generation is Go's
  (`core/keys.go`), and HTTPS goes through Go's `crypto/tls`. So the app is **not** limited to encryption Apple's
  OS provides. `shells/apple/project.yml` sets `ITSAppUsesNonExemptEncryption` to `NO` in the iOS Info.plist,
  the answer App Store Connect recorded for builds 1 and 2 and the one Plezy declares, so no build waits on the
  questionnaire; `store/app-store.md` §8 has what that declares. Apple notes that exempt-encryption apps may owe the
  U.S. BIS a year-end self-classification report.
- **iOS purpose strings in `Info.plist`** (`shells/apple/project.yml`): `NSLocalNetworkUsageDescription` (SSH to
  a machine on the same network triggers iOS local-network privacy), `NSPhotoLibraryUsageDescription`, and,
  because WKWebView's file picker offers the camera and choosing it without them ends the app,
  `NSCameraUsageDescription` and `NSMicrophoneUsageDescription`. A photo or video taken goes only into the
  message, over SSH. No contacts, location, Bluetooth, motion, health, calendar or tracking API is used.
- **No tracking manifest:** `shells/apple/Resources/PrivacyInfo.xcprivacy` sets `NSPrivacyTracking` false, no
  tracking domains, no collected data types, and declares `NSPrivacyAccessedAPICategoryFileTimestamp` reason
  `C617.1`, `NSPrivacyAccessedAPICategorySystemBootTime` reason `35F9.1` and
  `NSPrivacyAccessedAPICategoryUserDefaults` reason `CA92.1`. The Firebase products linked for push bring their
  own manifests, which declare the data types in `store/app-store.md` §7.
- **iOS entitlements and linking** (the 1.2.1 (4) archive, 2026-11-02): the app is signed with
  `aps-environment` and `keychain-access-groups` (the app's group and the push group), its Notification Service
  Extension with the push group only; `otool -L` on both lists system frameworks and libraries only, none of
  them `NetworkExtension`.
- **Android API levels:** `shells/android/app/build.gradle.kts` pins compileSdk 36, targetSdk 36 and minSdk 24
  (the Flutter app's), which meets Play's requirement to target API 36 for new apps and updates from 31 August
  2026; `aapt2 dump badging` on the release APK shows the same. The permissions (`aapt2 dump permissions`,
  `store/google-play.md` §3) are `INTERNET`, `POST_NOTIFICATIONS` (asked for when push is turned on) and
  `RECEIVE_BOOT_COMPLETED` (scheduled notifications are set again after a reboot) from the app's manifest, plus
  the normal ones Firebase Messaging and androidx.core add; `android:allowBackup` is false.
- **Uploads start on the Mac, not in CI:** `scripts/release/deploy.py` (Later releases) uploads the IPA it builds
  there, and the Play bundle and the Microsoft Store package the release run built in CI. The fastlane lanes,
  `fastlane ios deploy_appstore` and `fastlane android release` (run from `store/`), upload the whole listing and are
  the manual path. Play's first bundle goes through the console by hand (checklist step 8). A brand-new Play app
  accepts only a draft release, so the Android lane's default is a draft/internal test; the Fastfile's
  `track:production release_status:completed` publishes.
- **iOS screenshots must be a pixel size fastlane knows**; an unknown size aborts that step even when App
  Store Connect would accept it. The sets are 1320×2868 (iPhone 6.9-inch, portrait) and 2048×2732 (iPad
  13-inch, portrait), both on `deliver`'s list.
- **The Microsoft Store package is the GitHub build, packaged:** the `.msixbundle` holds the same files as
  `ompanion-windows-x64.zip` (`ompanion.exe`, `libompcore.dll`, `WebView2Loader.dll`, `app_icon.ico`, `ui/`) plus
  the manifest, `resources.pri` and the tile and taskbar images from `shells/windows/msix/assets/`, for x64 and
  arm64. Capabilities: `runFullTrust`, `internetClient` and `privateNetworkClientServer` (SSH to machines on the
  LAN), and the toast activator extensions (`desktop:ToastNotificationActivation`, `com:ExeServer`). Installed
  with a test signature on CI's Windows runners (runs 41408795484 and 41413982041), the app ran every smoke check
  (exec, PTY and the local terminal included) and imported the Flutter app's data from the package's
  `LocalCache\Roaming`. Not measured for this build: where its own database lands, and whether the processes it
  starts carry no package identity (the Flutter app's did not, so they saw the real AppData). MinVersion is
  Windows 10 1809 (10.0.17763).

## Review demo host

`store/review-demo/` is the server App Review, Play review and Microsoft Store certification sign in to: a
dedicated Ubuntu server at `217.160.119.181`, user `root` on port 22 with a password, omp 18.3.1, and one
real model, GLM 5.3 Flash through OpenRouter, on a key with a $10 spending limit that the owner pays for.
`store/review-demo/provision.sh root@217.160.119.181` sets it up from this Mac and can run again;
`ssh root@217.160.119.181 ompanion-demo-reset` puts root's home back between reviews. The password and the
key are in the gitignored `store/review-demo/.env`. Everything else — security and cost, reviewer steps, the
exact App Store Connect, Play Console and Partner Center answers — is in `store/review-demo/README.md`.
After the review, revoke the key at OpenRouter and destroy the server.

The App Review notes, the Play "App access" answer and the Microsoft Store certification notes are written
out verbatim in `store/review-demo/README.md`, section "Console answers" — copy them from there so the
host, port and password stay in one place (only `<PASSWORD>` needs filling). What is already in this
repository: `store/fastlane/ios/metadata/review_information/notes.txt` (the App Review text plus the guideline
paragraphs, pasted or uploaded whole; it names no password) and `demo_user.txt` / `demo_password.txt` (user
`root` and a fill-in line for the password).

Caveats to keep honest in the listings: the demo server has omp **preinstalled** and one model that we pay
for, so a reviewer sees a real provider on our key. The app itself comes with no model and no subscription:
users bring their own providers, and the listings must not imply otherwise. The omp install the listings
claim is real (`ui/src/core/host/install.ts` and `ui/src/app/screens/sessions/install_omp_dialog.tsx`: the newest
release the app pins, omp 18.16.0 at this revision, from its GitHub release, SHA-256 checked on the
machine) but is not what the demo shows.

## Screenshots and graphics

Paths and sizes, all PNG; no alpha except the Play icon, which Play takes as a 32-bit PNG with alpha:

| Asset | Path | Size |
|---|---|---|
| App Store iPhone | `store/fastlane/ios/screenshots/en-US/<NN>-<slug>-iphone69.png` | 1320×2868 (iPhone 17 Pro Max, portrait) |
| App Store iPad | `store/fastlane/ios/screenshots/en-US/<NN>-<slug>-ipad13.png` | 2048×2732 (iPad Pro 13-inch, portrait) |
| Play icon | `store/fastlane/android/metadata/android/en-US/images/icon.png` | 512×512, full-bleed from `assets/ompanion.svg` |
| Play feature graphic | `images/featureGraphic.png` | 1024×500 |
| Play phone | `images/phoneScreenshots/<NN>-<slug>.png` | 1080×1920 |
| Play 7-inch | `images/sevenInchScreenshots/` | 1920×1080 |
| Play 10-inch | `images/tenInchScreenshots/` | 2560×1440 |

`store/screenshots/capture.sh <ios-phone|ios-ipad|play-phone|macos>` runs the app in its shell on studio.local
through devpool (iOS simulators, the Pixel 7, the macOS window), seeds the SSH demo host, injects the scenario
(`store/screenshots/scenario/main.ts`) into the page and photographs the screen from the host so the real status
bar is in the picture, then
`store/screenshots/compose.py` composes the store images from `store/screenshots/captions.json`. The app's own SSH
session goes to a user-level OpenSSH host on studio with the tested omp and the fake provider; the model list is
neutral ("Fast", "Reasoning"), no vendor names. At this revision every committed set is still the Flutter app's
captures: `capture.sh ios-phone ios-ipad play-phone` (without `--out`) replaces the iPhone, iPad and Play phone
sets with the web app's, and the Play tablet sets and the Microsoft Store set stay the Flutter app's until devpool
has a tablet and a Windows desktop (`store/screenshots/README.md`).

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
