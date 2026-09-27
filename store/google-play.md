# Google Play submission: ompanion (phone + tablets)

Every Play Console form, field by field, with the URL each limit or rule came from, checked 2026-09-26 and re-checked 2026-09-27.
Nothing here is invented: where a value is the user's personal data it says **field for the user**.

## 1. Limits and policy this listing is written to

| Field | Limit | Source |
|---|---|---|
| App name (title) | 30 characters | [Create and set up your app](https://support.google.com/googleplay/android-developer/answer/9859152) |
| Short description | 80 characters | same |
| Full description | 4,000 characters | same |
| "What's new" / release notes | 500 characters per language | same |
| Tags | at most 5, from the console's own list | [Choose a category and tags](https://support.google.com/googleplay/android-developer/answer/9859673) |

Metadata policy: no emoji, emoticon or decorative character sequences in the title, icon or developer name;
no ALL CAPS unless it is part of the brand; no repeated or irrelevant keywords, no "#1"/"best" claims, no
pricing in the description ([Metadata policy](https://support.google.com/googleplay/android-developer/answer/9898842)).
Our texts use sentence-case headings, no emoji anywhere, and no superlatives.

## 2. Store listing (Grow users → Store presence → Main store listing)

| Field | Value | File |
|---|---|---|
| App name | `ompanion: omp client` | `android/fastlane/metadata/android/en-US/title.txt` |
| Short description | `Chat with your own omp coding agent over SSH. No account, no tracking.` | `short_description.txt` |
| Full description | see file | `full_description.txt` |
| App icon | 512×512 PNG | `android/fastlane/metadata/android/en-US/images/icon.png` |
| Feature graphic | 1024×500 PNG | `images/featureGraphic.png` |
| Phone screenshots | 2–8, 16:9 or 9:16, min 320 px, max 3840 px a side | `images/phoneScreenshots/` |
| 7-inch tablet screenshots | up to 8 | `images/sevenInchScreenshots/` |
| 10-inch tablet screenshots | up to 8 | `images/tenInchScreenshots/` |
| App category | **Tools** (Application) | — |
| Tags | pick up to 5 from the console's own list; suggested: "Tools", "Productivity", "Utilities", "Developer" if offered. Do not force a tag the list does not offer | — |
| Contact details — email | **field for the user** | — |
| Contact details — website | `https://ompanion.app` | — |
| Contact details — phone | optional; **field for the user** | — |
| Privacy policy | `https://ompanion.app/privacy` | — |
| Store listing language | English (United States), default | — |
| Store settings → App type | Application; free; no in-app purchases | — |

Release notes for versionCode 1 are in `changelogs/1.txt`.

## 3. App content declarations (Policy → App content)

Every one of these must be completed, including the ones answered "none"; leaving a declaration unanswered
blocks publication ([Prepare your app for review](https://support.google.com/googleplay/android-developer/answer/9859455)).

| Declaration | Answer |
|---|---|
| Privacy policy | URL above. The app collects nothing and has no account, so this is the only link Play requires. It is reachable from the listing **and** inside the app: **Settings → About → Privacy policy**. |
| Ads | **No.** No ads, no ad SDK, no house ads. |
| App access (Sign-in details) | **"All or some functionality is restricted"**: the app is useless without an SSH machine. Paste the text in section 4 (canonical version in `store/review-demo/README.md` §"Console answers"). |
| Target audience and content | **18 and over only.** Reasoning in section 5. Also complete the follow-up questions ("is your app designed for children" → No; do not join the Designed for Families programme). |
| Content rating | Questionnaire in section 6; category "Utility, Productivity, Communication, or Other". The app has no violent, sexual or gambling content; the one "yes" is mild language, because it shows the user's own agent output unfiltered (the same fact behind the App Store's "Infrequent" profanity answer). |
| Data safety | **No data collected or shared** — section 7. |
| News and magazine apps | **No.** Not a news app, not in the News category, no news in the title or description. |
| COVID-19 contact tracing and status apps | **No.** |
| Government apps | **No.** Not developed by or for a government. |
| Financial features | **No financial features.** |
| Health apps | **No health features.** |
| Advertising ID | **No.** The app declares no `AD_ID` permission and has no advertising or attribution SDK; its only user-facing permission is `android.permission.INTERNET` (`android/app/src/main/AndroidManifest.xml`; no plugin in `pubspec.lock` adds one). |
| Permissions declaration form | Not triggered: no SMS/call log, no location, no background location, no foreground-service type, no `QUERY_ALL_PACKAGES`, no restricted permission. `INTERNET` is not a restricted permission. |
| DSA / trader status (EEA) | **field for the user** — Play asks each developer account whether it is a trader. A free, open-source app published by an individual with no commercial activity can be a non-trader, but that is a legal statement about you, not about the app. Answer it in the account's compliance section. |
| AI-generated content | There is no dedicated App content form for this. The in-app AI-Generated Content policy is the likeliest policy question for this app, and the app has no in-app report control (section 8). The per-asset "AI-generated" declaration lives with each store-listing image, and our answer there is **No**. |

## 4. App access — what to select, and the text to paste

Play calls this "Sign-in details" now, and it is where reviewers are told how to reach restricted parts of
the app ([Requirements for providing sign in details](https://support.google.com/googleplay/android-developer/answer/15748846)).

- **Select: "All or some functionality is restricted."** The app has no account of its own, but it is useless
  without an SSH machine, so the reviewer needs credentials.
- **Instructions**: use the canonical text in `store/review-demo/README.md`, section "Console answers" →
  "Google Play Console → App access", which is written against the verified host. Fill `<HOST>` (the demo
  VPS's public address) and `<PASSWORD>` (`REVIEW_PASSWORD` in `store/review-demo/.env`); the user is
  `review`, the port 22222, and the session directory `/data/review/work/notes-api`.
- The equivalent short form, if you prefer to paste it here:

```
ompanion has no sign-in of its own, but it is a client: it needs a machine to connect to. We provide a
throwaway Linux demo host for review, which is destroyed after the review and holds no personal data.

1. Open the app and tap Add machine. Name: Demo. Host: <HOST>. Port: 22222. User: review.
   Authentication: Password. Password: <PASSWORD>. Tap Save.
2. The machine's page opens. Under System, tap Connect. The first connection asks about a host key it has
   never seen: "Trust this host?" → Trust (we cannot pre-seed the key; it is generated when the host
   starts).
3. The same System section then shows the OS, the architecture, Home, omp at /data/review/.local/bin/omp,
   omp version 18.3.1 and Companion: Uploaded.
4. Go back to the list of machines and on the machine's row tap ⋮ (More) → New session. Working directory
   ~/work/notes-api (the same directory as /data/review/work/notes-api); leave Model empty. Tap Start.
5. Type any message in the composer and send it. The demo host's model is an offline demo model that answers
   with canned replies (markdown, a shell command, a file read and edit, a todo list, reasoning, a question,
   then a long streamed answer). It makes no request to any AI provider and costs nothing.

Everything else works on the same machine: Files edits files and shows git diffs, Terminal opens a shell,
and Configure browses omp's settings, model roles, MCP servers, plugins and skills. Usage has no limits to
show on the demo machine. The access details work from any location and stay valid while the app is under
review.
```

## 5. Target audience and content

**Answer: 18 and over only.** Play asks which age groups the app is *designed* for, not which may install it
([Manage target audience and app content settings](https://support.google.com/googleplay/android-developer/answer/9867159)).

Reasons:

- The app is a developer tool: it needs an SSH host, credentials and a project on a machine you administer.
- It shows the unmoderated output of the user's own coding agent, with no filter of ours, and it can display
  arbitrary text and code from the user's own files.
- Choosing 13–15 or 16–17 can pull the app into the Families policy (Play: those groups "may be considered to
  include children in some locales"), which cannot be met honestly here (no content filtering of AI output,
  no parental controls, credential handling).
- 18 and over also makes Play offer **Restrict Minor Access**, which keeps the app away from accounts known
  to belong to minors. That is the closest thing Play has to "adults only" for a non-mature-content app.

If you prefer reach over caution, 16–17 plus 18 and over is the alternative, but it can bring Families
compliance with it, which this app does not implement. The Play-side answer does not have to match the App
Store's computed 9+ rating: Play's target audience is who the app is *for*, Apple's rating is how mature its
*content* is, and the two are declared separately in each console.

## 6. Content rating (IARC questionnaire)

[Content rating requirements](https://support.google.com/googleplay/android-developer/answer/9859655),
[Content ratings](https://support.google.com/googleplay/android-developer/answer/9898843).

- Category: **Utility, Productivity, Communication, or Other**.
- Contact email for IARC correspondence: **field for the user** (the certificate and any appeal go there).
- Violence: **No** to each question (no violence, weapons, blood, injury or violent threats in the app).
- Sexuality: **No** (nothing sexual in the app; this matches the App Store's "Sexual Content or Nudity: None").
- Language: **Yes, mild.** The app's own strings are plain UI text, but it shows the output of the user's own
  agent without a filter, and a coding agent's transcript occasionally contains swearing. That is the same
  fact behind the App Store's "Profanity or Crude Humor: Infrequent", and the two consoles should not tell
  different stories about one app.
- Controlled substances: **No**.
- Gambling and simulated gambling: **No**.
- Horror, discrimination, drugs, alcohol, tobacco: **No**.
- Interactive elements: **Unrestricted Internet — No** (no browser, no WebView; links open in the user's
  browser outside the app). **Users Interact — No** (no messaging, no UGC, no social features between
  users). **Shares Location — No** (the app never reads location). **Digital Purchases — No** (free, no IAP).

The Summary page shows the calculated ratings before you submit; because of the language answer, expect
them above the lowest tier. Misrepresenting an app's content is itself a policy violation, so answer what the
app can show rather than aiming for a number; the target audience (18 and over) is the separate lever for
who the app is for.

## 7. Data safety

**First question — "Does your app collect or share any of the required user data types?" → No.**

With No, the form asks nothing about encryption in transit or deletion requests (Play asks those only after
a Yes); it goes on to the store listing preview, which shows "No data collected" and "No data shared with
third parties".

Why "No" is the correct answer, checked against the code
([Data safety guidance](https://support.google.com/googleplay/android-developer/answer/10787469)):

- Play's "collection" means user data transmitted off the device by the app or its SDKs, whatever server it
  goes to. There is no server of ours: the app has no backend, and `pubspec.lock` holds no analytics,
  crash-reporting, advertising or push package.
- **End-to-end encrypted data is out of scope**: "User data that is sent off device, but that is unreadable
  by you or anyone other than the sender and recipient as a result of end-to-end encryption does not need to
  be disclosed." Everything the user types, opens or attaches travels over SSH between the device and the
  user's own machine, and only those two ends hold the session keys.
- Two requests leave SSH, and neither carries a user data type from Play's list: the omp release download
  from `github.com` (only when the target machine has no curl or wget, so the app fetches the public file and
  uploads it), and a web image named in a reply, fetched from its own URL only after the user taps "Load
  image". The developer receives neither. (Play's "user-initiated action" exemption is about *sharing*, not
  collection, so it is not the argument here.)
- No account, no email, no phone number, no device or advertising ID, no precise or approximate location, no
  contacts, no calendar, no health data, no crash logs, no diagnostics, no browsing history, no app
  interactions. The random per-install id the app generates goes only to the user's own machines, inside its
  SSH requests to omp.
- **Judgement call to keep in mind:** photos and files the user attaches do leave the device (over SSH, to
  their own machine), and the file picker is why the iOS build needs `NSPhotoLibraryUsageDescription`. The
  exemption above covers them: the recipient is the user's own machine, and we cannot read them. If a
  reviewer challenges it, the privacy policy says the same thing in plain words.

## 8. AI-generated content on Play

Two separate things
([AI-Generated Content policy](https://support.google.com/googleplay/android-developer/answer/13985936),
[policy guide](https://support.google.com/googleplay/android-developer/answer/14094294),
[declaring AI-generated content](https://support.google.com/googleplay/android-developer/answer/17262077)):

1. **The in-app policy.** It covers "apps that generate content using AI" and names "text–to-text
   conversational generative AI chatbots, in which interacting with the chatbot is a central feature of the
   app". Such apps must prevent restricted content and "must contain in-app user reporting or flagging
   features that allow users to report or flag offensive content to developers without needing to exit the
   app". Chatting with an agent is ompanion's central feature, so a reviewer can reasonably put it in scope,
   and the app has **no in-app report or flag control** (Settings → About → "Report an issue" opens the
   GitHub tracker in the browser, which leaves the app). Our position: ompanion hosts no model and generates
   nothing; it drives an open-source agent that the user installed and configured on their own machine, with
   the user's own provider accounts, and nothing it shows reaches anyone else. The policy text has no
   exemption for such a client, so this is **the most likely policy question on Play** for this app. The
   review demo host uses an offline demo model, so no real provider is involved in review.
2. **The store-asset declaration** (a checkbox per image or video in the store listing) asks whether a
   *listing asset* was AI-generated. Our screenshots are real captures of the app; do **not** tick it. If
   an asset is ever composited with a generative tool, tick it for that asset.

If Play applies the in-app policy, the remedy its own wording asks for is an in-app report control that
reaches the developer; arguing scope is the alternative. Decide which before the first submission.

## 9. Release mechanics that affect the listing

- A brand-new Play app can only be published as a **draft** release first: upload the bundle, complete every
  declaration above, then roll out. `android/fastlane/Fastfile` defaults to internal testing and
  a draft; `track:production release_status:completed` publishes.
- **New personal developer account:** Play requires a closed test with **at least 12 testers opted in for 14
  continuous days** before you can apply for production access, and internal testing does not count
  ([App testing requirements](https://support.google.com/googleplay/android-developer/answer/14151465)).
  Plan for that: recruit 15–20 testers, and see the checklist in `store/README.md`.
- Play requires new apps and updates to target API level 36 from 31 August 2026
  ([Target API level requirements](https://developer.android.com/google/play/requirements/target-sdk));
  the Flutter 3.47 defaults already do (compileSdk 36, targetSdk 36, minSdk 24), so nothing is pinned.
- Uploads run from the Mac with `(cd android && fastlane release)`, not from CI.

## 10. Counts (evidence)

See `store/README.md`, section "Length check".
