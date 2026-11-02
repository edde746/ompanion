// The last launch's first frame, painted while this launch's code loads (src/app/first_frame.ts keeps it). A classic
// script inline right after #root (vite.config.ts puts it there): it runs before the parser goes on, so the frame is in
// the document's first paint. It is shown only when everything the app's first render reads is as it was then, so the
// render that replaces it looks the same. Not on iOS: its WebKit paints nothing between the end of parsing and the
// entry's first render, so the kept frame never showed there (docs/research/web-ui/startup.md).
"use strict";
if (!/iPhone|iPad/.test(navigator.userAgent) && !(/Macintosh/.test(navigator.userAgent) && navigator.maxTouchPoints > 1)) {
  const first = (window.ompFirstFrame = {
    key: "ompanion.firstFrame",
    // What the first render reads: the settings and platform snapshots (src/app/providers/settings_provider.ts,
    // src/app/platform.ts), the system's dark mode and languages, the window's size.
    inputs: () =>
      JSON.stringify([
        localStorage.getItem("ompanion.settings"),
        localStorage.getItem("ompanion.platform"),
        matchMedia("(prefers-color-scheme: dark)").matches,
        navigator.languages,
        innerWidth,
        innerHeight,
      ]),
    saved: localStorage.getItem("ompanion.firstFrame"),
    shown: false,
    // The kept frame's first animation frame callback, and the task right after that frame painted (performance.now()).
    frameAt: undefined,
    paintedAt: undefined,
  });
  const frame = first.saved === null ? null : JSON.parse(first.saved);
  if (frame !== null && frame.inputs === first.inputs()) {
    for (const [name, value] of frame.attributes) document.documentElement.setAttribute(name, value);
    document.getElementById("root").innerHTML = frame.html;
    first.shown = true;
    requestAnimationFrame(() => {
      first.frameAt = performance.now();
      setTimeout(() => (first.paintedAt = performance.now()));
    });
  }
}
