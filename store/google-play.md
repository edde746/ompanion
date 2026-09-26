# Google Play submission: ompanion (phone + tablets)

Every Play Console form, field by field, with the URL each limit or rule came from, checked 2026-09-26.
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
| Contact details — website | `https://github.com/edde746/ompanion` | — |
| Contact details — phone | optional; **field for the user** | — |
| Privacy policy | `https://github.com/edde746/ompanion/blob/main/store/privacy-policy.md` | — |
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
| Content rating | Questionnaire in section 6; category "Utility, Productivity, Communication, or Other". Expect a low rating (IARC 3+); the app contains no violent, sexual, profane or gambling content of its own. |
| Data safety | **No data collected or shared** — section 7. |
| News and magazine apps | **No.** Not a news app, not in the News category, no news in the title or description. |
| COVID-19 contact tracing and status apps | **No.** |
| Government apps | **No.** Not developed by or for a government. |
| Financial features | **No financial features.** |
| Health apps | **No health features.** |
| Advertising ID | **No.** The app declares no `AD_ID` permission and has no advertising or attribution SDK; the built app requests only `android.permission.INTERNET` (`android/app/src/main/AndroidManifest.xml`). |
| Permissions declaration form | Not triggered: no SMS/call log, no location, no background location, no foreground-service type, no `QUERY_ALL_PACKAGES`, no restricted permission. `INTERNET` is not a restricted permission. |
| DSA / trader status (EEA) | **field for the user** — Play asks each developer account whether it is a trader. A free, open-source app published by an individual with no commercial activity can be a non-trader, but that is a legal statement about you, not about the app. Answer it in the account's compliance section. |
| AI-generated content | There is no dedicated App content form for this. The in-app policy is answered not-applicable in section 8; the per-asset "AI-generated" declaration lives with each store-listing image, and our answer there is **No**. |

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

1. Open the app and tap Add machine. Kind: SSH. Name: Demo. Host: <HOST>. Port: 22222. User: review.
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
- Choosing 13–15 or 16–17 would pull the app into the Families policy, which cannot be met honestly here
  (no content filtering of AI output, no parental controls, credential handling).
- 18 and over also makes Play offer **Restrict Minor Access**, which keeps the app away from accounts known
  to belong to minors. That is the closest thing Play has to "adults only" for a non-mature-content app.

If you prefer reach over caution, 16–17 plus 18 and over is the alternative, but it must come with Families
compliance, which this app does not implement. The Play-side answer does not have to match the App Store's
computed 9+ rating: Play's target audience is who the app is *for*, Apple's rating is how mature its
*content* is, and the two are declared separately in each console.

## 6. Content rating (IARC questionnaire)

[Content rating requirements](https://support.google.com/googleplay/android-developer/answer/9859655),
[Content ratings](https://support.google.com/googleplay/android-developer/answer/9898843).

- Category: **Utility, Productivity, Communication, or Other**.
- Contact email for IARC correspondence: **field for the user** (the certificate and any appeal go there).
- Violence: **No** to each question (no violence, weapons, blood, injury or violent threats in the app).
- Sexuality: **No** (nothing sexual or suggestive in the app itself).
- Language: **No** (the app's own strings are plain UI text; no profanity).
- Controlled substances: **No**.
- Gambling and simulated gambling: **No**.
- Horror, discrimination, drugs, alcohol, tobacco: **No**.
- Interactive elements: **Unrestricted Internet — No** (no browser, no WebView; links open in the user's
  browser outside the app). **Users Interact — No** (no messaging, no UGC, no social features between
  users). **Shares Location — No** (the app never reads location). **Digital Purchases — No** (free, no IAP).

Expected result: the low end of the scale (IARC 3+, ESRB Everyone, PEGI 3, USK 0), with "no interactive
elements" shown. That is what a client app with no content of its own should get; the AI output the app
displays comes from the user's own machine and their own provider account, and is not distributed to anyone,
so it is not "content in the app" for IARC.

If you want to be more conservative, the honest lever is the target audience (18 and over) rather than
over-answering these content questions: misrepresenting an app's content is itself a policy violation.

## 7. Data safety

**First question — "Does your app collect or share any of the required user data types?" → No.**

That closes the form; the listing then shows "No data collected" and "No data shared with third parties".
Also complete: **Security practices** → data encrypted in transit = **not applicable** (nothing collected);
**Deletion request** = not applicable.

Why "No" is the correct answer, checked against the code at HEAD c27b114
([Data safety guidance](https://support.google.com/googleplay/android-developer/answer/10787469)):

- Play's "collection" means data transmitted off the device, including by SDKs, whatever server it goes to.
  We transmit nothing to us and there is no us: the app has no backend, and `pubspec.yaml` has no analytics,
  crash-reporting or advertising dependency.
- **End-to-end encrypted transfers are explicitly out of scope**, and that is what this app does: everything
  the user types, opens or attaches travels over SSH, encrypted between the device and the user's own
  machine, readable only by those two ends — Google's wording is "unreadable by you or anyone other than the
  sender and recipient".
- Transfers **initiated by the user** are also out of scope: a tapped web image is fetched from its own URL,
  and the omp release download from `github.com` fetches a public file. Neither carries user data.
- No account, no email, no phone number, no device or advertising ID, no precise or approximate location, no
  contacts, no calendar, no health data, no crash logs, no diagnostics, no browsing history, no app
  interactions.
- **Judgement call to keep in mind:** photos and files the user attaches do leave the device (over SSH, to
  their own machine), and the file picker is why the iOS build needs `NSPhotoLibraryUsageDescription`. The
  exemption above covers them: the recipient is the user's own machine, and we cannot read them. If a
  reviewer challenges it, the privacy policy says the same thing in the user's own words.

## 8. AI-generated content on Play

Two separate things, and neither applies to this app as shipped
([AI-generated content policy](https://support.google.com/googleplay/android-developer/answer/14094294),
[declaring AI-generated content](https://support.google.com/googleplay/android-developer/answer/17262077)):

1. **The in-app policy** (no prohibited output, an in-app way to report offensive AI output) applies to apps
   that generate content with AI, including AI chatbots. ompanion generates nothing: it renders the output
   of an open-source agent that the user installed and configured on their own machine, using the user's own
   provider account, and nothing it renders is distributed to anyone else. There is no model, no prompt
   engineering and no training on user data in this app. Our store screenshots and builds use an offline
   demo model on a demo host, so no real provider is involved in review either.
2. **The store-asset declaration** (a checkbox per image or video in the store listing) asks whether a
   *listing asset* was AI-generated. Our screenshots are real captures of the app; do **not** tick it. If
   an asset is ever composited with a generative tool, tick it for that asset.

Flagged as **the most likely policy question on Play** for this app, because "coding agent chat" looks like
"AI chatbot" at a glance. The description says plainly that the AI comes from the user's own machine and
their own provider accounts, and that is what the review instructions show. If Play pushes back, add a
"Report" affordance to the message context menu before shipping: it would be the cheaper answer than arguing,
even though the content is the user's own.

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
