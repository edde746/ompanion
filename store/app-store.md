# App Store submission: ompanion (iPhone + iPad)

Everything to paste into App Store Connect, field by field, plus the guideline reasoning a reviewer will
check. Apple's help pages move; every claim below carries the URL it came from, checked 2026-09-26.

The Mac App Store is **out of scope**: it needs a sandboxed build without "this computer" and without the
`ssh` command's config and agent reading, which this build does not have.

## 1. Limits this listing is written to

| Field | Limit | Source |
|---|---|---|
| App name | 30 characters | [App information](https://developer.apple.com/help/app-store-connect/reference/app-information/app-information) |
| Subtitle | 30 characters | same |
| Keywords | 100 **bytes**, comma separated | same |
| Promotional text | 170 characters | [Platform version information](https://developer.apple.com/help/app-store-connect/reference/app-information/platform-version-information) |
| Description | 4,000 characters | same |
| What's New (release notes) | 4,000 characters | same |

Evidence for each of our files is in section 9 (byte and character counts).

## 2. App information (App Store Connect → General → App Information)

| Field | Value |
|---|---|
| Name | `ompanion: omp client` — `ios/fastlane/metadata/en-US/name.txt` |
| Subtitle | `Coding agent over SSH` — `subtitle.txt` |
| Bundle ID | `com.edde746.ompanion` |
| SKU | your choice; suggest `ompanion-ios-001`. Must be unique in your account and is never shown to users. |
| Primary language | English (U.S.) |
| Primary category | Developer Tools (`DEVELOPER_TOOLS`) — `ios/fastlane/metadata/primary_category.txt` |
| Secondary category | Productivity (`PRODUCTIVITY`) — `secondary_category.txt` |
| Content rights | **No, it does not contain, show or access third-party content** (see section 6) |
| Age rating | see section 5; computed 9+, and you may override higher |
| Price | Free (no in-app purchases, no subscriptions) |
| Copyright | `2026 Edvard Wikhall` — `ios/fastlane/metadata/copyright.txt` |
| License agreement | Apple's standard EULA. The app is GPLv3; a custom EULA is **not** needed and would conflict with it. |
| Routing app coverage file | none |
| Mac support | not applicable (no Mac App Store submission; do not select "Mac" as a platform) |

The name is the brand plus a descriptor, which is ordinary App Store practice; "client" is not a third-party
mark. "omp" is used nominatively, to say what the app is a client of. No other product or vendor name appears
anywhere in the name, subtitle, keywords or description. The keyword field repeats no word from the name or
the subtitle (Apple indexes those anyway), contains no trademark, no category name and no "app": it is
`terminal,remote,server,shell,jump,host,vpn,mesh,session,diff,git,ai,self-hosted,mac,linux,windows`.

**Copyright name.** `2026 edde746` also works, but the App Store already shows your real name as the seller
of Plezy ("Edvard Wikhall", [Plezy listing](https://apps.apple.com/us/app/plezy-media-server-client/id6754315964)),
so the copyright line uses the same legal name for consistency. Change it if you publish as a company.

## 3. Version information (the 0.1.0 version page)

| Field | File |
|---|---|
| Promotional text | `en-US/promotional_text.txt` |
| Description | `en-US/description.txt` |
| Keywords | `en-US/keywords.txt` |
| Support URL | `en-US/support_url.txt` → `https://github.com/edde746/ompanion/issues` |
| Marketing URL | `en-US/marketing_url.txt` → `https://ompanion.app` |
| Privacy Policy URL | `en-US/privacy_url.txt` → `https://ompanion.app/privacy` |
| What's New | `en-US/release_notes.txt` |
| Build | the 0.1.0 build uploaded from `flutter build ipa` |
| Version release | automatic after approval, or manual — your choice |

Check all three URLs in an incognito window before submitting; a dead privacy-policy URL is an automatic
5.1.1(i) rejection.

## 4. App Review information

`ios/fastlane/metadata/review_information/` holds these files, which `deliver` uploads. The file name is the
**option key** fastlane looks up (not the App Store Connect attribute), so these names matter:

| Field | File | Value |
|---|---|---|
| First name | `first_name.txt` | **field for the user** |
| Last name | `last_name.txt` | **field for the user** |
| Phone | `phone_number.txt` | **field for the user** |
| Email | `email_address.txt` | **field for the user** |
| Notes | `notes.txt` | the canonical text is `store/review-demo/README.md` §"Console answers"; the file here is that text plus the guideline paragraphs (2.1/4.2, 2.5.2, 5.1.2(i), AI output). Replace `<HOST>` and `<PASSWORD>` on line 1 before submitting. |
| Sign-in required | `demo_user.txt`, `demo_password.txt` | **Yes**: user `review`, password from `store/review-demo/.env`. The app has no account of its own, but this is the form an App Review person looks at first, so the demo machine's credentials belong here as well as in the notes. deliver sets "Sign-in required" to Yes only when both files are non-empty. |
| Trade representative contact (EU DSA) | `ios/fastlane/metadata/trade_representative_contact_information/*.txt` | optional and **field for the user** (legal name, address, phone); only needed if you appoint an EU trade representative and want it uploaded with the metadata |

`notes.txt` is the review notes text. Its first line is a fill-in marker, so a submission with the marker
still in place is obvious.

## 5. Age rating questionnaire (General → App Information → Age Ratings)

Apple's 2026 questionnaire (values 4+/9+/13+/16+/18+ on iOS 26 and later; 4+/9+/12+/17+ below that) includes
the social-media questions that became required for new apps and updates in September 2026 — today's
submissions must answer them.
Sources: [Age ratings values and definitions](https://developer.apple.com/help/app-store-connect/reference/app-information/age-ratings-values-and-definitions),
[updated age ratings](https://developer.apple.com/news/?id=ks775ehf),
[social media questions](https://developer.apple.com/news/?id=tlur8uvi),
[Set an app age rating](https://developer.apple.com/help/app-store-connect/manage-app-information/set-an-app-age-rating).

In-app controls: **Parental Controls** No · **Age Assurance** No.

Capabilities:

| Question | Answer | Why |
|---|---|---|
| Unrestricted Web Access | **No** | There is no browser and no WebView. Links open in the system browser (Safari), outside the app. A model reply can name a web image, and the app fetches it only when the user taps "Load image" — that is a single fetch of a named URL, not browsing. |
| User-Generated Content | **No** | Nothing the app shows is broadly distributed. Prompts and replies stay between the user and their own machine; there is no feed, no profile page, no publishing, no sharing with other users. |
| Social Media | **No** | No redistribution, amplification or discovery of anyone's content; no likes, comments, shares or views. |
| Social Media Disabled for Users Under 13 | not asked (Social Media is No) | |
| Messaging and Chat | **No** | The chat is with the user's own agent on the user's own machine. Two devices of the same user can watch one live session of their own agent; users cannot reach each other through the app, and there are no messages between accounts, no contact list and no way to find another person. **Judgement call** — if App Review reads "several of my devices see one session" as messaging, answer Yes; the computed rating does not change (messaging alone is 4+). |
| Advertising | **No** | No ads, no ad SDK, no house ads, no ad identifiers. |

Mature themes: **Profanity or Crude Humor** Infrequent · **Horror or Fear Themes** None · **Alcohol,
Tobacco, or Drug Use or References** None.

Medical or wellness: **Medical or Treatment Information** None · **Health or Wellness Topics** None.

Sexuality or nudity: **Mature or Suggestive Themes** Infrequent · **Sexual Content or Nudity** None ·
**Graphic Sexual Content and Nudity** None.

Violence: **Cartoon or Fantasy Violence** None · **Realistic Violence** None · **Prolonged Graphic or
Sadistic Realistic Violence** None · **Guns or Other Weapons** None.

Chance-based activities: **Gambling** No · **Simulated Gambling** None · **Contests** None · **Loot Boxes**
No.

Age categories and override: **Not Applicable** → computed **9+**.

Why "Infrequent" on profanity and mature themes: Apple's 2025 guidance tells developers to rate an AI
assistant by what it can actually produce, and the app applies no filter of its own — it renders whatever
the user's own agent produces. A coding agent's transcript occasionally contains swearing or an adult
reference. Nothing in the app itself supplies that content, and no part of the app is a chatbot we operate,
which is why the other descriptors are None. Two defensible alternatives, both one click in App Store
Connect:

- **Override to Higher Age Rating → 18+** if you want the stronger barrier. The descriptors stay as
  answered; only the displayed rating changes. This matches Play's target-audience choice in
  `store/google-play.md`.
- **Override to 16+** (unrestricted AI-driven output, but nothing category-18 in the answers).

Do not answer All-None and leave the rating at 4+: guideline 2.3.6 makes an honest questionnaire your
responsibility, and a mis-rated app "could trigger an inquiry from government regulators".

## 6. Content Rights and Advertising Identifier

- **Content Rights** (the question App Store Connect asks when you first publish): **No** — the app contains
  no third-party content. It displays the user's own files and the user's own agent output, and it bundles
  only first-party assets plus MIT-licensed libraries; it downloads omp (an open-source project) onto the
  user's own machine at the user's request, and does not redistribute it.
- **Advertising Identifier (IDFA)**: **No** — the app does not use the Advertising Identifier, has no ad SDK
  and no attribution SDK. Do not tick "uses IDFA".

## 7. App Privacy (General → App Privacy)

**Answer: "No, we do not collect data from this app."** One question, and the data-type questionnaire closes.
Then: Privacy Policy URL = `https://ompanion.app/privacy`.

Reasoning, checked against the code at HEAD c27b114:

- Apple counts data as collected when it leaves the device in a way that you or a partner can access or
  retain it ([App privacy details](https://developer.apple.com/go/?id=info-1)). Nothing leaves the device to
  us, and there is no us: no backend, no SDK that reports, no identifier of ours
  (`pubspec.yaml`: no analytics, crash-reporting or advertising dependency; the only HTTP clients in the app
  are `dart:io HttpClient` for the omp release download and `Image.network` for a tapped web image).
- What does leave the device goes to the user's own machines over SSH (their data, their machines, and
  encrypted in transit), to `github.com` when the user asks the app to install omp on a machine (a public
  file, no user data), and to a URL the user taps in a model reply or a sign-in page they opened.
- No account, no email address, no device identifier, no usage data, no crash logs, no location, no contacts
  and no photos are collected by us. Files the user attaches go to their own machine over SSH.
- If Apple's reviewer asks how the app can show AI output and collect nothing: the AI runs on the user's
  machine, calls the user's own provider account, and the app is a client for it — the same answer as an SSH
  client that ships no server. This is the 5.1.2(i) argument in the review notes.

## 8. Export compliance

Answer per the store build, from
[Export compliance documentation for encryption](https://developer.apple.com/help/app-store-connect/reference/app-information/export-compliance-documentation-for-encryption)
and [Complying with encryption export regulations](https://developer.apple.com/documentation/security/complying-with-encryption-export-regulations):

- **Does your app use encryption?** **Yes.**
- **Is it exempt?** **No — the app implements encryption itself, with industry-standard algorithms, not
  provided by the operating system.** `dartssh2` implements SSH in Dart: AES-CTR/CBC, ChaCha20-Poly1305,
  Curve25519 and Ed25519. `Info.plist` deliberately does **not** set `ITSAppUsesNonExemptEncryption`, so
  App Store Connect asks these questions on each submission, which is the correct behaviour while the
  distribution territories are undecided.
- **Documentation:** none required unless France is in your territories; if it is, upload the French
  encryption declaration for the app when App Store Connect asks.
- **Note for the checklist:** if you later exclude France and want to skip the questions, the matching
  `Info.plist` value is `ITSAppUsesNonExemptEncryption` = `NO` (Apple's own table: "only uses encryption
  provided by Apple's OS" / standard algorithms where "your app is not distributed in France"). Apple also
  warns that makers of apps using exempt encryption may still owe the U.S. BIS a year-end self-classification
  report: <https://www.bis.gov/learn-support/encryption-controls/annual-self-classification>.

## 9. Screenshots, icon and previews

The 1320×2868 iPhone (6.9-inch, portrait) and 2048×2732 iPad (13-inch, portrait) sets are in
`ios/fastlane/screenshots/en-US/`, tooling in `store/screenshots/`, and the paths and caveats in
`store/README.md`. What the guidelines require of them: they show the app in use, not a splash screen (2.3.3);
they may carry text overlays; they must be suitable for all audiences even though the app is older-rated
(2.3.8); and they may not contain prices, other platforms' names, or unverifiable claims (2.3.7, 2.3.10).
Desktop-only features are absent from both the captures and the descriptions.

## 10. Guideline notes a reviewer will care about

| Guideline | What it says | Our position |
|---|---|---|
| [2.1 App Completeness](https://developer.apple.com/app-store/review/guidelines/#performance) | final version, working URLs, demo account info, backend live during review | The app is complete; the three URLs are live once the repo is public; the demo host in `store/review-demo/` is the "backend" and must be **up during review**; the review notes give host, port, user and password. |
| [2.5.2 Software Requirements](https://developer.apple.com/app-store/review/guidelines/#software-requirements) | apps are self-contained and may not download, install or execute code that changes the app's features | The app installs **omp** — someone else's open-source binary — on the **user's own remote machine** over SSH, at the user's request, like an SSH client running commands on a server. It never downloads or runs code **on the device**. The one file it fetches itself is the omp release asset for the target machine, written to that machine over SFTP; the companion extension it uploads runs inside the user's own omp on that machine. Explained in the review notes. |
| [2.5.1, 2.5.5](https://developer.apple.com/app-store/review/guidelines/#software-requirements) | public APIs, works on IPv6-only networks | Flutter and public libraries only. SSH is IPv6-capable; test on an IPv6-only network before submitting if you can. |
| [4.2 Minimum Functionality / 4.2.3](https://developer.apple.com/app-store/review/guidelines/#minimum-functionality) | apps should work on their own without installing another app; disclose first-launch downloads | Nothing is required on the device. What the app needs is a machine of the user's, which is the same position as an SSH client. The demo host means a reviewer does not need one. |
| [4.2.7 Remote Desktop Clients](https://developer.apple.com/app-store/review/guidelines/#minimum-functionality) | mirroring of specific software must be user-owned, executed on the host, no store-like UI | Read it even though its LAN clause does not fit an SSH client: the host is the user's own computer, everything runs on that host, there is no store UI, and account creation happens on the host. |
| [4.7 Mini apps, chatbots, plug-ins](https://developer.apple.com/app-store/review/guidelines/#extensions) | software not embedded in the binary brings extra rules | The companion extension is not offered on the device: it is uploaded into the user's own omp installation on the user's own machine. **Flagged as the most likely guideline to draw a question**; the review notes explain it. |
| [5.1.1(i) Privacy policies](https://developer.apple.com/app-store/review/guidelines/#privacy) | a privacy policy in metadata **and inside the app** | The policy is at the privacy URL, and the app links it in **Settings → About** (`lib/screens/settings/about_section.dart`): privacy policy, source code, issue tracker, licence ("GPL-3.0 with an app-store exception"), Flutter's bundled-package licence list and the version line. Both halves of the guideline are satisfied. |
| [5.1.2(i) Data Use and Sharing](https://developer.apple.com/app-store/review/guidelines/#privacy) | disclose sharing with third parties, including third-party AI, and get permission | The app sends prompts only to the user's own omp, on the user's own machine, which calls the providers the user configured with the user's own credentials. The app never contacts a provider, holds no provider key, and shows nothing to the developer. Explained in the review notes and in the privacy policy. |

## 11. Counts (evidence)

Every file above is inside its limit. The command that measured them, and its output on this revision, are
in `store/README.md`, section "Length check". At the time of writing: name 20 characters, subtitle 21,
keywords 97 bytes, promotional text 161, description 3966, release notes 660.
