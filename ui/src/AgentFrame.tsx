import { createEffect, createSignal, onSettled } from "solid-js";

// Agent HTML runs in <iframe sandbox="allow-scripts"> without allow-same-origin: an opaque origin with no access to
// the page, the bridge, storage or cookies, and no popups, forms or top navigation.
//
// The frame loads public/frame.html, not srcdoc or a blob: URL. Those two inherit the embedding page's CSP, so the
// agent's inline scripts would need 'unsafe-inline' in the app page's own policy, and the frame could never be
// stricter than the page in connect-src and img-src. frame.html comes over the app's own scheme like any other
// document, so it carries only its own policy (a meta tag): inline scripts and styles, data:/blob: images, fonts and
// media, and no network at all. The page then document.write()s the agent HTML into it; the document, and with it
// the policy, stays the same.
//
// The app page's policy (index.html) stays strict: scripts only from the bundle, frame-src 'self'. frame-src also
// covers the frame's own navigations, so agent code cannot move its frame to an outside URL that has no policy.
// Not covered by any CSP directive: WebRTC (RTCPeerConnection) from inside the frame.

export interface AgentFrameProps {
  html: string;
  /** Messages the agent HTML posts to its parent, other than the frame's own. */
  onMessage?: (data: unknown) => void;
  onHeight?: (height: number) => void;
}

export function AgentFrame(props: AgentFrameProps) {
  let frame!: HTMLIFrameElement;
  const [height, setHeight] = createSignal(0);

  onSettled(() => {
    const onMessage = (event: MessageEvent<unknown>) => {
      // Only this frame's window speaks for it; every other window's messages are not ours.
      if (event.source === null || event.source !== frame.contentWindow) return;
      const data = event.data;
      const type = typeof data === "object" && data !== null && "type" in data ? data.type : undefined;
      if (type === "ompanion-frame-ready") {
        frame.contentWindow.postMessage({ html: props.html }, "*");
      } else if (type === "ompanion-frame-height" && typeof data === "object" && data !== null && "height" in data) {
        const reported = Number(data.height);
        if (!Number.isFinite(reported) || reported < 0) throw new Error(`agent frame reported height ${String(data.height)}`);
        const clamped = Math.min(reported, 20000);
        setHeight(clamped);
        props.onHeight?.(clamped);
      } else {
        props.onMessage?.(data);
      }
    };
    window.addEventListener("message", onMessage);
    return () => window.removeEventListener("message", onMessage);
  });

  // New HTML: load frame.html again; its ready message fetches the current HTML.
  createEffect(
    () => props.html,
    () => {
      frame.src = "frame.html";
    },
    { defer: true },
  );

  return (
    <iframe
      ref={frame}
      class="agent-frame"
      sandbox="allow-scripts"
      src="frame.html"
      title="Agent HTML"
      style={{ height: `${height()}px` }}
    />
  );
}
