# App Store submission: ompanion (iPhone + iPad)

Everything to paste into App Store Connect, field by field, plus the guideline reasoning a reviewer will
check. Apple's help pages move; every claim below carries the URL it came from, checked 2026-09-26 and re-checked 2026-09-27.

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
| App Review notes | 4,000 **bytes** | same |

Evidence for each of our files is in section 11 (byte and character counts).

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
| Content rights | **Yes, it contains, shows or accesses third-party content, and I have the necessary rights** (see section 6) |
| Age rating | see section 5; computed 9+, and you may override higher |
| Price | US$4.99, the owner's choice (the GitHub build is free); no in-app purchases, no subscriptions. The listing texts therefore never say "free". |
| Copyright | `2026 Edvard Wikhall` — `ios/fastlane/metadata/copyright.txt` |
| License agreement | Apple's standard EULA. The app is GPLv3 and published by its sole copyright holder (`store/README.md`, "Licence"). |
| Routing app coverage file | none |
| Mac and Apple Vision Pro | Apple offers an iPhone and iPad app on Apple silicon Macs and on Apple Vision Pro unless you opt out. The Mac App Store is out of scope and the iOS build is not tested on either, so under **Pricing and Availability** deselect "Make this app available" in **iPhone and iPad Apps on Apple Silicon Mac** and "Make this app available on Apple Vision Pro" in **iPhone and iPad Apps on Apple Vision Pro** ([Macs with Apple silicon](https://developer.apple.com/help/app-store-connect/manage-your-apps-availability/manage-availability-of-iphone-and-ipad-apps-on-macs-with-apple-silicon), [Apple Vision Pro](https://developer.apple.com/help/app-store-connect/manage-your-apps-availability/manage-availability-of-iphone-and-ipad-apps-on-apple-vision-pro)). |

The name is the brand plus a descriptor, which is ordinary App Store practice; "client" is not a third-party
mark. "omp" is used nominatively, to say what the app is a client of. Other product names appear only where
they state a fact: the systems the app connects to (macOS, Linux and Windows in the description; `mac`,
`linux`, `windows` in the keywords) and the source address on github.com. Those are trademarks used
descriptively, which guideline 2.3.7 allows; it forbids packing metadata with them "just to game the system".
The keyword field repeats no word from the name or the subtitle (Apple indexes those anyway), and contains no
category name and no "app": it is
`terminal,remote,server,shell,jump,host,session,diff,git,ai,self-hosted,mac,linux,windows`. Keep `vpn` out
of it and "VPN" out of every listing text: with `vpn,mesh` in the keywords and "private mesh VPN" in What's
New, App Review's automated analysis asked about VPN functionality (section 10). Tailscale works on iPhone and
iPad only as the user's own separate app; ompanion just dials the peer's address over SSH.

**Copyright name.** `2026 edde746` also works, but the App Store already shows your real name as the seller
of Plezy ("Edvard Wikhall", [Plezy listing](https://apps.apple.com/us/app/plezy-media-server-client/id6754315964)),
so the copyright line uses the same legal name for consistency. Change it if you publish as a company.

## 3. Version information (the 1.0.0 version page)

| Field | File |
|---|---|
| Promotional text | `en-US/promotional_text.txt` |
| Description | `en-US/description.txt` |
| Keywords | `en-US/keywords.txt` |
| Support URL | `en-US/support_url.txt` → `https://github.com/edde746/ompanion/issues` |
| Marketing URL | `en-US/marketing_url.txt` → `https://ompanion.app` |
| Privacy Policy URL | `en-US/privacy_url.txt` → `https://ompanion.app/privacy` |
| What's New | `en-US/release_notes.txt` |
| Build | the 1.0.0 build uploaded from `flutter build ipa` |
| Version release | automatic after approval, or manual — your choice |

Check all three URLs in an incognito window before submitting; a dead privacy-policy URL is an automatic
5.1.1(i) rejection.

Later versions: `scripts/release/deploy.py` (`store/README.md`, Later releases) uploads the build from
`flutter build ipa`, creates the version, sets What's New from `en-US/release_notes.txt` and attaches the build;
it changes no other field. `(cd ios && fastlane deploy_appstore)` uploads the whole listing when it changes.

## 4. App Review information

`ios/fastlane/metadata/review_information/` holds these files, which `deliver` uploads. The file name is the
**option key** fastlane looks up (not the App Store Connect attribute), so these names matter:

| Field | File | Value |
|---|---|---|
| First name | `first_name.txt` | **field for the user** |
| Last name | `last_name.txt` | **field for the user** |
| Phone | `phone_number.txt` | **field for the user** |
| Email | `email_address.txt` | **field for the user** |
| Notes | `notes.txt` | the canonical text is `store/review-demo/README.md` §"Console answers"; the file here is that text plus the guideline paragraphs (2.1/4.2, 2.5.2, 5.1.2(i), no VPN functionality, AI output). The whole file is the field's text, under the 4,000-byte limit (`store/README.md`, "Length check"). It names the host, `217.160.119.181`, and user `root`, and points to Sign-In Information for the password, which is never committed. |
| Sign-in required | `demo_user.txt`, `demo_password.txt` | **Yes**: user `root`, password `REVIEW_PASSWORD` from `store/review-demo/.env`. The app has no account of its own, but this is the form an App Review person looks at first, and the notes' step 1 sends them here for the password. deliver sets "Sign-in required" to Yes only when both files are non-empty. |
| Trade representative contact (EU DSA) | `ios/fastlane/metadata/trade_representative_contact_information/*.txt` | optional and **field for the user** (legal name, address, phone); only needed if you appoint an EU trade representative and want it uploaded with the metadata |

`notes.txt` is the review notes text, pasted or uploaded whole. The contact and password files start with
`FILL` until filled in, and `deploy_appstore` refuses to upload while any does.

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
| Social Media Disabled for Users Under 13 | **No** | App Store Connect asks it even with Social Media No (seen 2026-09-27). The app has no social media to disable and no age gate (Parental Controls and Age Assurance are No). |
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

- **Content Rights** (the question App Store Connect asks when you first publish): **Yes, it contains, shows
  or accesses third-party content, and I have the necessary rights.** Apple's rule covers apps that "contain,
  show, or access third-party content"
  ([App information](https://developer.apple.com/help/app-store-connect/reference/app-information/app-information)),
  and ompanion does all three: it bundles open-source libraries (BSD, MIT and Apache-2.0, listed under
  Settings → About → Open-source licenses), it fetches omp's MIT-licensed release from its official GitHub
  release when a machine cannot download it itself, and it shows a web image named in a reply after the user
  taps "Load image". The rights come from those licences and from the user's own request; the app
  redistributes nothing. Everything else it displays is the user's own files and agent output.
- **Advertising Identifier (IDFA)**: **No** — the app does not use the Advertising Identifier, has no ad SDK
  and no attribution SDK. Do not tick "uses IDFA".

## 7. App Privacy (General → App Privacy)

**Answer: "Yes, we collect data from this app"**, with the data types the Firebase SDKs' own privacy manifests
declare, every one **not linked** to the user's identity and **not used for tracking**:

| Data type | Purposes |
|---|---|
| Identifiers → Device ID | App Functionality |
| Diagnostics → Other Diagnostic Data | App Functionality, Analytics |
| Other Data → Other Data Types | Analytics |

Then: Privacy Policy URL = `https://ompanion.app/privacy`.

Reasoning, checked against the code:

- Apple counts data as collected when it leaves the device in a way that you or a partner can access or
  retain it ([App privacy details](https://developer.apple.com/go/?id=info-1)). The one such flow is push
  notifications, which stay off until the user turns them on in Settings: then the Firebase Messaging SDK
  records the APNs token with Google and registers the app's Firebase installation ID for messaging
  ([Firebase's App Store disclosure](https://firebase.google.com/docs/ios/app-store-data-collection)).
  Google is a partner in Apple's sense, so that is a device-level identifier collected. It exists only to
  deliver notifications; there is no account to link it to; nothing uses it for tracking. The installation ID
  also passes through our relay with each notification, which keeps nothing. The SDK's device model, language,
  time zone and OS version go to Google only for topic subscriptions, which the app does not use.
- The table is the union of the `PrivacyInfo.xcprivacy` bundles the linked Firebase products ship inside the
  built `Runner.app` (checked 2026-09-27, firebase-ios-sdk 12.19.2): FirebaseMessaging declares Device ID (App
  Functionality), Other Data Types (Analytics) and Other Diagnostic Data (App Functionality);
  FirebaseInstallations and GoogleDataTransport declare Other Diagnostic Data (Analytics). Xcode's privacy
  report for an archive (Product → Archive → Generate Privacy Report) aggregates these manifests; check it
  against this table before answering. None of it happens before push notifications are on: Firebase is not
  started until then. GoogleAppMeasurement resolves in the package graph but is not linked.
- The notification text is encrypted on the user's own machine with a key the phone made and is readable only
  on that phone; the relay, Google and Apple carry ciphertext. Nothing else of ours reports anything: no
  analytics, crash-reporting or advertising SDK; the only other HTTP clients in the app are `dart:io
  HttpClient` for the omp release download and `Image.network` for a tapped web image.
- What else leaves the device goes to the user's own machines over SSH (their data, their machines, and
  encrypted in transit), to `github.com` when the user installs omp on a machine that has no curl or wget (a
  public file, no user data), and to the host of a web image the user tapped "Load image" on. Links and
  sign-in pages open in the user's browser, outside the app.
- No account, no email address, no usage data, no crash logs, no location, no contacts and no photos are
  collected by us. Files the user attaches go to their own machine over SSH. The random per-install id the app
  generates goes only to the user's own machines, inside its requests to omp and in the phone's push
  registration file there.
- If Apple's reviewer asks how the app can show AI output and collect nothing else: the AI runs on the user's
  machine, calls the user's own provider account, and the app is a client for it — the same answer as an SSH
  client that ships no server. This is the 5.1.2(i) argument in the review notes.

## 8. Export compliance

`ios/Runner/Info.plist` sets `ITSAppUsesNonExemptEncryption` to `NO`, so App Store Connect asks nothing about an
uploaded build. It is the answer App Store Connect recorded for builds 1 and 2 and the one Plezy declares. What the
app uses, from
[Export compliance documentation for encryption](https://developer.apple.com/help/app-store-connect/reference/app-information/export-compliance-documentation-for-encryption)
and [Complying with encryption export regulations](https://developer.apple.com/documentation/security/complying-with-encryption-export-regulations):

- **Does your app use encryption?** **Yes.**
- **Which kind?** Apple's table has three rows: encryption limited to what Apple's OS provides; "an industry
  standard algorithm, not provided within the Apple operating system"; and proprietary algorithms.
  ompanion is the **second** row. `dartssh2` implements SSH in Dart: the ciphers
  `packages/omp_core/lib/src/ssh/ssh_link.dart` offers (ChaCha20-Poly1305, AES-GCM, AES-CTR), Curve25519,
  ECDH and Diffie-Hellman key exchange, and Ed25519, RSA and ECDSA signatures; key generation is Ed25519
  (`pinenacl`). The one HTTPS request, the omp download, uses `dart:io`'s TLS, which is BoringSSL inside the
  Dart runtime, not Apple's. Nothing proprietary.
- **What `NO` declares:** the app "only uses forms of encryption that are exempt from export compliance
  documentation requirements", so no documentation is uploaded. Apple asks for the French encryption declaration
  when an app that needs documentation is offered in France, and France is among the app's territories (checked
  2026-10-07). An answer that needs documentation would replace the key with `ITSEncryptionExportComplianceCode`,
  the key Apple returns after approving the declaration.
- Apple also notes that an app using exempt encryption "might alternatively be required to submit a year-end
  self-classification report to the U.S. government":
  <https://www.bis.gov/learn-support/encryption-controls/annual-self-classification>.

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
| [2.1 App Completeness](https://developer.apple.com/app-store/review/guidelines/#performance) | final version, working URLs, demo account info, backend live during review | The app is complete; the three URLs are live once the repo is public; the demo server `217.160.119.181` (`store/review-demo/`) is the "backend" and must be **up during review**, with credit left on its OpenRouter key; the review notes give host, port, user and password. |
| [2.5.2 Software Requirements](https://developer.apple.com/app-store/review/guidelines/#software-requirements) | apps are self-contained and may not download, install or execute code that changes the app's features | The app installs **omp** — someone else's open-source binary — on the **user's own remote machine** over SSH, at the user's request, like an SSH client running commands on a server. It never runs downloaded code **on the device**, and nothing it downloads changes its own features. The machine fetches the omp release itself when it has curl or wget (PowerShell on Windows); otherwise the app streams the release asset from GitHub to the machine over SFTP without storing it. The companion extension it uploads runs inside the user's own omp on that machine. Explained in the review notes. |
| [2.5.1, 2.5.5](https://developer.apple.com/app-store/review/guidelines/#software-requirements) | public APIs, works on IPv6-only networks | Flutter and public libraries only. SSH is IPv6-capable; test on an IPv6-only network before submitting if you can. |
| [4.2 Minimum Functionality / 4.2.3](https://developer.apple.com/app-store/review/guidelines/#minimum-functionality) | apps should work on their own without installing another app; disclose first-launch downloads | Nothing is required on the device. What the app needs is a machine of the user's, which is the same position as an SSH client. The demo server means a reviewer needs neither a machine nor an AI account: it has omp and a model we pay for. |
| [4.2.7 Remote Desktop Clients](https://developer.apple.com/app-store/review/guidelines/#minimum-functionality) | mirroring of specific software must be user-owned, executed on the host, no store-like UI | Read it even though its LAN clause does not fit an SSH client: the host is the user's own computer, everything runs on that host, there is no store UI, and account creation happens on the host. |
| [4.7 Mini apps, chatbots, plug-ins](https://developer.apple.com/app-store/review/guidelines/#extensions) | software not embedded in the binary, including chatbots and plug-ins, brings extra rules; 4.7.1 asks for filtering, a way to report content, and blocking | The companion extension is not offered on the device: it is uploaded into the user's own omp installation on the user's own machine. The agent in the chat is the user's own install with the user's own provider accounts, not a chatbot we offer, and the app has no report or filter control of its own. The one exception is the review demo server, whose model we pay for; it exists only for the review, and the notes say so. **Flagged as the most likely guideline to draw a question**; the review notes' 2.5.2 and AI-content paragraphs make this argument. |
| [5.1.1(i) Privacy policies](https://developer.apple.com/app-store/review/guidelines/#privacy) | a privacy policy in metadata **and inside the app** | The policy is at the privacy URL, and the app links it in **Settings → About** (`lib/screens/settings/about_section.dart`): privacy policy, source code, issue tracker, licence ("GPL-3.0"), Flutter's bundled-package licence list and the version line. Both halves of the guideline are satisfied. |
| [5.1.2(i) Data Use and Sharing](https://developer.apple.com/app-store/review/guidelines/#privacy) | disclose sharing with third parties, including third-party AI, and get permission | The app sends prompts only to the user's own omp, on the user's own machine, which calls the providers the user configured with the user's own credentials. The app never contacts a provider, keeps no provider key (a key typed into the Providers page goes over SSH to omp), and shows nothing to the developer. Explained in the review notes and in the privacy policy. On the review demo server the machine is ours: its omp sends the reviewer's prompts to OpenRouter and Z.ai with our key, which the review notes' 5.1.2(i) paragraph says. |
| VPN (automated analysis) | App Review asks what user data a VPN collects, why, and who it is shared with, or a confirmation that there is no VPN | ompanion has no VPN: no Network Extension framework or entitlement, no tunnel, no routing. No Mach-O in the built `Runner.app` links `NetworkExtension.framework`, the entitlements are push and keychain groups only, and the one app extension is the Notification Service Extension. It opens SSH connections only; a machine may sit on the user's Tailscale network, which Tailscale's own app carries. The review notes' "No VPN functionality" paragraph says so. |

## 11. Counts (evidence)

Every file above is inside its limit. The command that measured them, and its output on this revision, are
in `store/README.md`, section "Length check".
