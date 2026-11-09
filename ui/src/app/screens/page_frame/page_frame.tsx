// The frame an agent's page (the companion's html_render tool) shows in: <iframe sandbox="allow-scripts"> without
// allow-same-origin, an opaque origin with no access to the app, the bridge, storage or cookies, and no popups, forms
// or top navigation.
//
// The frame loads public/frame.html, not srcdoc or a blob: URL. Those two inherit the embedding page's CSP, so the
// page's inline scripts would need 'unsafe-inline' in the app's own policy. frame.html comes over the app's own scheme
// like any other document and carries only its own policy (a meta tag): https:, wss:, data: and blob: sources, never
// http:. Once it reports ready, the app posts the page and its theme; frame.html document.write()s a helper and then
// the page into itself, so the document, and with it the policy, stays the same. The helper reports the page's height,
// the links and images the reader clicks, whether the reader's finger is on the page and the reader's wheels and scroll
// keys, and takes theme changes.
//
// The app page's policy (index.html) stays strict: scripts only from the bundle, frame-src 'self'. frame-src also
// covers the frame's own navigations, so a page cannot move its frame to an outside URL that has no policy. Not
// covered by any CSP directive: WebRTC (RTCPeerConnection) from inside the frame.
import { createEffect, createMemo, createSignal, onSettled } from "solid-js";
import { showImageViewer } from "../../widgets/image_viewer";
import { openPageLink } from "../external_links";
import "./page_frame.css";
import { type PageTheme, pageTheme, readFrameMessage, unquoted } from "./page_frame_protocol";

/**
 * Dispatched on a frame, bubbling, when the reader's finger lands on its page (`detail` true) or the last one leaves it
 * (false). The page's touch events stay in its own document, yet a drag that starts on the page scrolls what scrolls
 * around the frame.
 */
export const pageTouchEvent = "pagetouch";

/**
 * Dispatched on a frame, bubbling, when the reader turns a wheel or presses a scroll key on its page: towards the top
 * (`detail` true) or the bottom. What the page does not scroll itself scrolls what scrolls around the frame, which
 * never sees those events either.
 */
export const pageScrollEvent = "pagescroll";

export interface PageFrameProps {
  html: string;
  title: string;
  /** The height until the page reports its own, e.g. the last one this page had. */
  initialHeight?: number;
  onHeight?: (height: number) => void;
  /** The page loaded: its scripts have run (the page can also post this itself). */
  onLoaded?: () => void;
  /** The frame fills its box and the page scrolls inside it (the full-screen view). */
  fill?: boolean;
}

export function PageFrame(props: PageFrameProps) {
  let frame!: HTMLIFrameElement;
  const [reported, setReported] = createSignal<number | undefined>(undefined);
  // Only a change of the page reloads the frame: an effect's callback runs on every run of its compute.
  const html = createMemo(() => props.html);

  onSettled(() => {
    // One link confirmation and one image viewer at a time per frame: a page that keeps posting links or images while
    // one is shown is not heard.
    let linkOpen = false;
    let imageOpen = false;
    let postedTheme = "";
    const onMessage = (event: MessageEvent<unknown>) => {
      // Only this frame's window speaks for it; every other window's messages are not ours.
      if (event.source === null || event.source !== frame.contentWindow) return;
      const message = readFrameMessage(event.data);
      switch (message?.kind) {
        case "FrameReady": {
          const theme = currentTheme(frame);
          postedTheme = JSON.stringify(theme);
          frame.contentWindow.postMessage({ type: "ompanion-frame-page", html: props.html, theme }, "*");
          break;
        }
        case "FrameLoaded":
          props.onLoaded?.();
          break;
        case "FrameHeight":
          setReported(message.height);
          props.onHeight?.(message.height);
          break;
        case "FrameLink":
          if (linkOpen) break;
          linkOpen = true;
          void openPageLink(message.url).finally(() => (linkOpen = false));
          break;
        case "FrameImage":
          if (imageOpen) break;
          imageOpen = true;
          void showImageViewer(message.image).finally(() => (imageOpen = false));
          break;
        case "FrameTouch":
          frame.dispatchEvent(new CustomEvent(pageTouchEvent, { bubbles: true, detail: message.touching }));
          break;
        case "FrameScroll":
          frame.dispatchEvent(new CustomEvent(pageScrollEvent, { bubbles: true, detail: message.up }));
          break;
      }
    };
    window.addEventListener("message", onMessage);
    // The palette on <html> changes (Light, Dark, a Custom pick): the page takes the new colours.
    const themes = new MutationObserver(() => {
      const theme = currentTheme(frame);
      const text = JSON.stringify(theme);
      if (text === postedTheme) return;
      postedTheme = text;
      frame.contentWindow?.postMessage({ type: "ompanion-frame-theme", theme }, "*");
    });
    themes.observe(document.documentElement, { attributes: true, attributeFilter: ["data-base", "style"] });
    return () => {
      window.removeEventListener("message", onMessage);
      themes.disconnect();
    };
  });

  // Another page: frame.html loads again, and its ready message fetches the page.
  createEffect(
    html,
    () => {
      frame.src = "frame.html";
    },
    { defer: true },
  );

  return (
    <iframe
      ref={frame}
      class={props.fill ? "page-frame page-frame-fill" : "page-frame"}
      sandbox="allow-scripts"
      src="frame.html"
      title={props.title}
      style={props.fill ? undefined : { height: `${reported() ?? props.initialHeight ?? 0}px` }}
    />
  );
}

/** The theme where `element` sits, from the app's resolved custom properties. */
function currentTheme(element: HTMLElement): PageTheme {
  const style = getComputedStyle(element);
  const webFonts = new Set<string>();
  document.fonts.forEach((face) => webFonts.add(unquoted(face.family)));
  return pageTheme((property) => style.getPropertyValue(property), webFonts);
}
