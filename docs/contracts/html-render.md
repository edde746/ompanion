# Agent HTML pages

`html_render` shows an agent's HTML page in the chat where the call sits, above the reply. The companion supplies the
tool; `PageFrame` runs the result in an opaque-origin sandbox, not in the app page. The tool, transcript and frame are
in `companion/src/html-render.ts`, `ui/src/app/screens/chat/transcript/` and `ui/src/app/screens/page_frame/`.

## Tool

`companion/src/index.ts` registers `html_render` in sessions and subagents. Its label is `Page`, its `loadMode` is
`essential`, and its approval is `read`. Its required parameters are ordered so the title streams first:

| Parameter | Contract |
|---|---|
| `title` | String, 1–200 characters; trimmed on execution and rejected if blank. It is shown above the page and used for the saved file name. |
| `html` | String, 1–100,000 characters; a complete HTML document. |

The 100,000-character limit bounds both the cost of streaming full accumulated messages and the page's cost in model
context. The description sent to the model is (`companion/src/html-render.ts`, `HTML_RENDER_DESCRIPTION`):

> Shows an HTML page to the reader, in the chat where you call this, above your reply. Use it when a chart, diagram, mockup or visual comparison says more than text.
>
> Send a complete, self-contained document: scripts, styles and fonts inline or from https URLs (CDN libraries work). Local images given by absolute path are inlined.
>
> The frame is as wide as your reply (about 360 px on phones, up to about 800 px on desktops) and its height follows the page, up to 20000 px: no vh units, no height:100% on html or body, fixed pixel heights for charts.
>
> Leave html and body without background, border or padding: the page sits on the chat's background. A box that needs a background uses var(--card) and var(--radius).
>
> Use the theme's CSS variables for colours, corners and fonts: --background --foreground --muted --muted-foreground --card --card-foreground --border --accent --accent-foreground --error --warning --success --chart-1 --chart-2 --chart-3 --chart-4 --chart-5 --chart-6 --radius --font-sans --font-mono.
>
> Links ask the reader before they open.

The tool rejects `vh`, `svh`, `lvh` and `dvh` lengths in CSS style elements and style attributes, not in scripts,
text or comments: a height that follows the frame can make the frame grow repeatedly. It finds absolute local image
paths in quoted attribute values and CSS `url(...)`, and inlines them as data URLs. It accepts PNG, JPEG, GIF, WebP,
AVIF, SVG, BMP and ICO extensions only when the file's signature matches the extension. Each image is limited to
5 MiB; after inlining, the UTF-8 page is limited to 10 MiB, including repeated uses of an image. Remote, relative and
data URLs stay unchanged. These checks prevent a renamed non-image file from being sent and bound the payload.

A successful result has one text item:

> Shown to the reader where you called this, above your reply. Don't mention or describe the page; reply with only what it doesn't already say.

Its details are `{title, html?}`: `title` is trimmed, and `html` is present only when inlining changed the page. The
app displays `details.html ?? args.html`. A blank title, viewport-height unit, unreadable or non-image local file, or
size limit throws an actionable error; omp returns an error result. Abort is also propagated. Schema limits are
checked by omp's tool parameters.

## Frame and messages

`PageFrame` loads `ui/public/frame.html` in `<iframe sandbox="allow-scripts">`, without same-origin, popups, forms
or top navigation. The frame has an opaque origin and cannot access the app, its bridge, cookies or storage. The app's
own CSP keeps `frame-src 'self'`; the frame has its own CSP, retained across `document.open()`:

```text
default-src 'none'; script-src 'unsafe-inline' 'unsafe-eval' https: data: blob:; style-src 'unsafe-inline' https: data:; img-src https: data: blob:; font-src https: data:; media-src https: data: blob:; connect-src https: wss: data: blob:; worker-src https: data: blob:; frame-src https: data: blob:; form-action 'none'; base-uri 'none'
```

The policy blocks `http:` resources, including LAN HTTP services. It permits HTTPS resources and WSS connections,
subject to the directive for their type: pages may reach the network by decision (`docs/PLAN.md`, D27). On Windows
and Android the app's own origin is https (`https://app.ompanion`, `https://appassets.androidplatform.net`), so a
page can load the app's files too, but cannot read them (opaque origin, no CORS headers; cache files also carry
`nosniff`), and a frame's `postMessage` never reaches the core (the smoke `html` check). The smoke `html` check
exercises the policy without a real network connection (`docs/contracts/bridge.md`, Smoke runs).

On its first page message, the frame writes the doctype, UTF-8 charset, viewport, `<style id="ompanion-theme">`,
helper script and then the supplied HTML, in that order, before `document.close()`. The helper and theme therefore
exist before page scripts run. The app checks that incoming messages came from that frame's window; the frame checks
that page and theme messages came from its parent. The app validates message fields, because scripts in the page can
post messages from the same window (`page_frame_protocol.ts`). Messages use `postMessage`:

| Direction | Message | Meaning |
|---|---|---|
| Frame → app | `{type: "ompanion-frame-ready"}` | The frame loaded and is ready for the page. |
| Frame → app | `{type: "ompanion-frame-loaded"}` | The page's window fired `load`: its scripts have run. |
| App → frame | `{type: "ompanion-frame-page", html: string, theme: PageTheme}` | The page and initial theme; accepted once per frame load. |
| Frame → app | `{type: "ompanion-frame-height", height: number}` | Root border-box height in CSS pixels, rounded up and reported on change. The app accepts finite nonnegative values, clamped to 20,000. |
| Frame → app | `{type: "ompanion-frame-link", url: string}` | An absolute link URL; the app accepts only `http:`, `https:` and `mailto:`. |
| App → frame | `{type: "ompanion-frame-theme", theme: PageTheme}` | Replace the theme sheet when the app palette changes. |
| Frame → app | `{type: "ompanion-frame-touch", touching: boolean}` | A trusted touch starts or the last touch ends or is cancelled. |
| Frame → app | `{type: "ompanion-frame-scroll", up: boolean}` | A trusted vertical wheel or scroll key moves toward the top (`true`) or bottom (`false`). |

The app relays touch and scroll as bubbling `pagetouch` and `pagescroll` events on the iframe, with the boolean in
`detail`: the transcript's document does not see the frame's touch, wheel or key events. Scroll keys in editable
fields and Space are not relayed. In the inline view the frame follows the reported height, retaining its initial
height until the first report; in full screen it fills its box and the page scrolls inside.

The helper intercepts links in the capture phase. Same-document fragments and `javascript:` links work within the
frame; other links are cancelled. Only trusted clicks to a URL outside the app's origin are relayed. For every
accepted page link, `openPageLink` (`ui/src/app/screens/external_links.tsx`) shows the full URL and the body “A page in
the chat wants to open this link.”; only confirmation calls `shell.openUrl`. A frame drops further link messages while
its confirmation is open. Shell navigation and new-window handlers do not open the system browser.

`PageTheme` is `{appearance: "light" | "dark", variables: Record<string, string>}`. The app resolves its custom
properties where the frame sits, including Custom theme choices; bundled web-font families are removed because the
opaque frame cannot reach them. `page_frame_protocol.ts` maps these page variables to the app's theme:

| Page variables | App source |
|---|---|
| `--background`, `--foreground`, `--muted`, `--muted-foreground` | `--surface`, `--on-surface`, `--surface-container-high`, `--on-surface-variant` |
| `--card`, `--card-foreground`, `--border`, `--accent`, `--accent-foreground` | `--surface-container`, `--on-surface`, `--outline-variant`, `--primary`, `--on-primary` |
| `--error`, `--warning`, `--success` | The app properties of the same names |
| `--chart-1` … `--chart-6` | ANSI blue, green, yellow, red, magenta and cyan text colours (`transcript/ansi.ts`) |
| `--radius`, `--font-sans`, `--font-mono` | `--card-radius`, `--font-sans`, `--font-mono` |

The base sheet makes HTML transparent, sets foreground and `14px/1.5 var(--font-sans)`, removes body margin and uses
`--font-mono` for code. Theme variable names and values that could break out of their CSS declarations are omitted.

## Transcript and recovery

A pending or running call shows its streamed title and “Writing page · N KB”. A successful call shows its title bar,
full-screen and save actions, and the frame; a shown page stays visible in a folded turn. Failed or interrupted calls
fold like other failed tools (`transcript_rows.ts`, `page_view.tsx`, `tool_data.ts`). The last height is kept in
`TranscriptStorage` under `transcript-page-height:<row key>`, so a row rebuilt after scrolling out retains its size
while the frame reloads. Full screen is a pushed page with back and save; saving uses the shared
`ui/src/app/files/save_file.ts` path and a sanitized `<title>.html` file name.

A frame is recorded before it runs under the localStorage key `ompanion.page-running.<hex>`, where the suffix is the
cyrb53 hash of the HTML (`page_runs.ts`). A frame's run ends one second after its page reports `ompanion-frame-loaded`,
on the app's own timer, or when the frame goes first; all frames of the same page share a record, and the last run
ending removes it. A page that stops the app while it loads or within that second keeps its record; one that stops it
later does not, and runs again when its session opens. If a record remains from a stopped app and no frame in this app
runs that page, its row and full-screen view show “This page stopped the app the last time it ran.” and “Run page”
instead of running it. An app that quits or is killed for any reason while a page loads leaves the same record. The
page's own scripts can post `ompanion-frame-loaded` early: the record guards against accidents, not against a page.

A busy page freezes the app page wherever the frame shares the app's renderer: measured on WKWebView (macOS and iOS),
Android WebView and WebKitGTK 2.52, and on WebView2 155 on some launches (others gave the frame its own process); not
in Chrome. The shells end a hung renderer where the platform has a public API, and their crash path brings the app
back: Android 10 and later ends the renderer on `onRenderProcessUnresponsive` (Android 7-9 have no recovery), Linux
terminates the web process when `is-web-process-responsive` goes false, and Windows recreates the webview on
WebView2's render-process-unresponsive kind (a `Reload()` did not recover a hung page; recreating took 16-18 s). Each
notices only once an input goes unanswered (Linux after about 3 s, Android after about 8 s)
(`shells/android/app/src/main/kotlin/com/edde746/ompanion/MainActivity.kt`, `shells/linux/main.cpp`,
`shells/windows/src/main.cpp`). Apple exposes no public equivalent; force quit is the recovery. The record keeps the
same page from running again by itself after an abnormal stop; it does not prove which page caused it.

## Measured costs and open risks

With omp 18.12.6 streaming 1,000 characters per second, each delta resends the accumulated message. A 25 KB page wrote
29.0 MB of run log without coalescing and 12.7 MB with it; a 100 KB page wrote 504 MB and 96 MB respectively. A
100 KB page costs about 35,000 tokens in context (`companion/src/html-render.ts`, `ui/src/core/channel/log_script.ts`).
The pump coalesces updates, not the model's context. In Chromium/WebView2, the first large wheel notch over a page at
the transcript's very bottom can still snap back. A real HTTPS load from the frame and a real file save have not been
run; the smoke frame check requests a non-resolving HTTPS host and checks for CSP violations, not a successful load.
