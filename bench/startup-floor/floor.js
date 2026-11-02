// The floor page's whole script: after its first frame painted and the core answered core.info, it sends the shell the
// same `shell.timing` marks the app's page sends (ui/src/app/boot_timing.ts), over the shell's own transport.
const scriptStart = performance.now();
const pending = new Map();
let nextId = 1;
let send;
if (window.webkit?.messageHandlers?.core) {
  const handler = window.webkit.messageHandlers.core;
  send = (text) => handler.postMessage(text);
} else if (window.ompCoreNative) {
  const native = window.ompCoreNative;
  native.onmessage = (event) => receive(JSON.parse(event.data));
  send = (text) => native.postMessage(text);
} else if (window.chrome?.webview) {
  window.chrome.webview.addEventListener("message", (event) => receive(event.data));
  send = (text) => window.chrome.webview.postMessage(text);
} else {
  throw new Error("no shell transport");
}
window.ompCore = { receive };

function receive(message) {
  pending.get(message.id)?.(message);
  pending.delete(message.id);
}

function call(method, params) {
  const { promise, resolve } = Promise.withResolvers();
  const id = nextId++;
  pending.set(id, resolve);
  send(JSON.stringify({ id, method, params }));
  return promise;
}

// Chromium queues the first-contentful-paint entry once the frame was presented: wait for it, at most 2 s.
const contentful = Promise.withResolvers();
new PerformanceObserver((list, observer) => {
  const entry = list.getEntriesByName("first-contentful-paint")[0];
  if (entry === undefined) return;
  observer.disconnect();
  contentful.resolve(entry.startTime);
}).observe({ type: "paint", buffered: true });
setTimeout(() => contentful.resolve(undefined), 2000);

const rendered = performance.now();
requestAnimationFrame(() =>
  setTimeout(async () => {
    const firstFrame = performance.now();
    await call("core.info");
    const coreInfo = performance.now();
    const navigation = performance.getEntriesByType("navigation")[0];
    const epoch = (ms) => (ms === undefined ? undefined : Math.round((performance.timeOrigin + ms) * 10) / 10);
    await call("shell.timing", {
      navigationStart: epoch(0),
      responseEnd: epoch(navigation.responseEnd),
      domInteractive: epoch(navigation.domInteractive),
      scriptStart: epoch(scriptStart),
      rendered: epoch(rendered),
      firstFrame: epoch(firstFrame),
      firstContentfulPaint: epoch(await contentful.promise),
      coreInfo: epoch(coreInfo),
    });
  }),
);
