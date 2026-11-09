// The image viewer (ZoomedImage of lib/screens/chat/transcript/images.dart): an image alone on the dialog scrim,
// zoomable across the window. The chat's images, the composer's attachments and the images of an agent's page open in
// it.
import { createSignal, onSettled, Show } from "solid-js";
import { t } from "../i18n/i18n";
import { play } from "../motion";
import { IconButton } from "./button";
import { showDialog } from "./dialog";
import * as Symbols from "./symbols";
import "./image_viewer.css";

interface Point {
  readonly x: number;
  readonly y: number;
}

/** The most the fitted image magnifies; more where 2× its own pixels needs more. */
const maxScale = 8;

/** What a zoom button or key multiplies the scale by. */
const zoomStep = 1.5;

/** How far a pointer may move and still tap (Flutter's kTouchSlop). */
const tapSlop = 18;

/** How soon and how near a second tap makes a double tap (Flutter's kDoubleTapTimeout and kDoubleTapSlop). */
const doubleTapMs = 300;
const doubleTapSlop = 100;

/** How long the zoom of a button, key or double tap takes (Durations.medium1), on Easing.standard. */
const zoomMs = 250;
const zoomEasing = "cubic-bezier(0.2, 0, 0, 1)";

/**
 * The image at `url` on the dialog scrim with no surface, zoomable across the window, a close button in the top right
 * and the zoom bar at the bottom: out, the image's size against its own pixels, in, fit. A pinch, a scroll, the bar or
 * the keys +, - and 0 zoom it; a double tap zooms to its own pixels (at least 2×) and back; a drag pans it. A tap
 * beside the image, Escape or back close it.
 */
function ImageViewer(props: { url: string; onClose: () => void }) {
  let area!: HTMLDivElement;
  let content!: HTMLDivElement;
  let image!: HTMLImageElement;
  // Applied straight to the content's style: every pointer move changes it.
  let view = { x: 0, y: 0, scale: 1 };
  let motion: Animation | undefined;
  const pointers = new Map<number, Point>();
  let tap: { id: number; x: number; y: number; onImage: boolean } | undefined;
  let lastTap: { atMs: number; x: number; y: number } | undefined;
  // The view's scale for the zoom bar, which reads it; the gestures read `view`.
  const [scale, setScale] = createSignal(1);
  // The fitted image's width over its own: under 1 while the window shows it smaller than its pixels. Undefined until
  // it decodes, and for an image without a size of its own.
  const [fitted, setFitted] = createSignal<number | undefined>(undefined);
  const limit = () => Math.max(maxScale, 2 / (fitted() ?? 1));

  /**
   * Shows the content at `scale` (1 to `limit()`) with its point under `from` moved to `to`, the window always covered,
   * as Flutter's InteractiveViewer keeps it; `animate` moves it there over `zoomMs` from where it shows now.
   */
  function place(scale: number, from: Point, to: Point, animate = false): void {
    const next = Math.min(Math.max(scale, 1), limit());
    const applied = next / view.scale;
    const width = area.clientWidth;
    const height = area.clientHeight;
    view = {
      scale: next,
      x: Math.min(Math.max(to.x - (from.x - view.x) * applied, width - width * next), 0),
      y: Math.min(Math.max(to.y - (from.y - view.y) * applied, height - height * next), 0),
    };
    const transform = `translate(${view.x}px, ${view.y}px) scale(${view.scale})`;
    // A zoom still moving starts the next one from where it is; a gesture takes over from it.
    const shown = animate ? getComputedStyle(content).transform : undefined;
    motion?.cancel();
    motion = undefined;
    content.style.transform = transform;
    if (shown !== undefined) motion = play(content, [{ transform: shown, easing: zoomEasing }, { transform }], zoomMs);
    setScale(next);
  }

  /** Zooms to `scale` about the window's centre, as the zoom bar and keys do. */
  function zoomAtCentre(scale: number): void {
    const at = { x: area.clientWidth / 2, y: area.clientHeight / 2 };
    place(scale, at, at, true);
  }

  function measure(): void {
    const width = image.naturalWidth;
    setFitted(width > 0 && image.clientWidth > 0 ? image.clientWidth / width : undefined);
  }

  function local(event: { clientX: number; clientY: number }): Point {
    const rect = area.getBoundingClientRect();
    return { x: event.clientX - rect.left, y: event.clientY - rect.top };
  }

  function onPointerDown(event: PointerEvent): void {
    area.setPointerCapture(event.pointerId);
    pointers.set(event.pointerId, local(event));
    tap = pointers.size === 1 ? { id: event.pointerId, ...local(event), onImage: event.target === image } : undefined;
  }

  function onPointerMove(event: PointerEvent): void {
    const before = pointers.get(event.pointerId);
    if (!before) return;
    const after = local(event);
    pointers.set(event.pointerId, after);
    if (tap && Math.hypot(after.x - tap.x, after.y - tap.y) > tapSlop) tap = undefined;
    const other = [...pointers].find(([id]) => id !== event.pointerId)?.[1];
    if (!other) {
      place(view.scale, before, after);
      return;
    }
    const centre = (a: Point) => ({ x: (a.x + other.x) / 2, y: (a.y + other.y) / 2 });
    const spread = (a: Point) => Math.hypot(a.x - other.x, a.y - other.y);
    if (spread(before) > 0) place((view.scale * spread(after)) / spread(before), centre(before), centre(after));
  }

  function onPointerUp(event: PointerEvent): void {
    const tapped = tap?.id === event.pointerId && pointers.size === 1 ? tap : undefined;
    pointers.delete(event.pointerId);
    tap = undefined;
    if (!tapped) return;
    if (!tapped.onImage) {
      props.onClose();
      return;
    }
    const near = lastTap && Math.hypot(tapped.x - lastTap.x, tapped.y - lastTap.y) <= doubleTapSlop;
    if (!lastTap || !near || event.timeStamp - lastTap.atMs > doubleTapMs) {
      lastTap = { atMs: event.timeStamp, x: tapped.x, y: tapped.y };
      return;
    }
    // A double tap: fitted, to the image's own pixels, at least 2×; zoomed, back to fitted.
    lastTap = undefined;
    place(view.scale > 1 ? 1 : Math.max(2, 1 / (fitted() ?? 1)), tapped, tapped, true);
  }

  function onPointerCancel(event: PointerEvent): void {
    pointers.delete(event.pointerId);
    tap = undefined;
  }

  onSettled(() => {
    const wheel = (event: WheelEvent) => {
      event.preventDefault();
      const pixels = event.deltaY * (event.deltaMode === WheelEvent.DOM_DELTA_LINE ? 16 : 1);
      // A trackpad pinch arrives as a wheel with Ctrl and small deltas; a scroll scales as Flutter's viewer does.
      const at = local(event);
      place(view.scale * Math.exp(-pixels / (event.ctrlKey ? 50 : 200)), at, at);
    };
    // Safari's trackpad pinch: WebKit's GestureEvent (not in the DOM types), its scale relative to the gesture's start.
    let gestureScale = 1;
    const gestureStart = (event: Event) => {
      event.preventDefault();
      gestureScale = 1;
    };
    const gestureChange = (event: Event) => {
      event.preventDefault();
      // A touch pinch is two pointers, handled above.
      if (pointers.size >= 2) return;
      const gesture = event as Event & { scale: number; clientX: number; clientY: number };
      const at = local(gesture);
      place((view.scale * gesture.scale) / gestureScale, at, at);
      gestureScale = gesture.scale;
    };
    // The zoom keys, with or without Cmd or Ctrl. Escape too: a bar button that turned disabled under the focus leaves
    // the focus outside the dialog's layer, which then hears no keys.
    const key = (event: KeyboardEvent) => {
      if (event.defaultPrevented || event.altKey) return;
      if (event.key === "Escape") props.onClose();
      else if (event.key === "+" || event.key === "=") zoomAtCentre(view.scale * zoomStep);
      else if (event.key === "-") zoomAtCentre(view.scale / zoomStep);
      else if (event.key === "0") zoomAtCentre(1);
      else return;
      event.preventDefault();
    };
    // A window of another size fits the image anew and moves a zoomed view back over the whole window.
    const resized = new ResizeObserver(() => {
      measure();
      place(view.scale, { x: 0, y: 0 }, { x: 0, y: 0 });
    });
    area.addEventListener("wheel", wheel, { passive: false });
    area.addEventListener("gesturestart", gestureStart);
    area.addEventListener("gesturechange", gestureChange);
    window.addEventListener("keydown", key);
    resized.observe(area);
    return () => {
      area.removeEventListener("wheel", wheel);
      area.removeEventListener("gesturestart", gestureStart);
      area.removeEventListener("gesturechange", gestureChange);
      window.removeEventListener("keydown", key);
      resized.disconnect();
    };
  });

  const percent = () => {
    const ratio = fitted();
    return ratio === undefined ? undefined : t.units.percent({ value: Math.round(scale() * ratio * 100) });
  };

  return (
    <div class="image-viewer">
      <div
        class={["image-viewer-area", scale() > 1 ? "image-viewer-zoomed" : undefined]}
        ref={area}
        onPointerDown={onPointerDown}
        onPointerMove={onPointerMove}
        onPointerUp={onPointerUp}
        onPointerCancel={onPointerCancel}
      >
        <div class="image-viewer-content" ref={content}>
          <img
            class="image-viewer-image"
            ref={image}
            src={props.url}
            alt={t.transcript.image}
            draggable="false"
            onLoad={measure}
          />
        </div>
      </div>
      <IconButton
        class="image-viewer-close"
        variant="tonal"
        icon={Symbols.close}
        tooltip={t.common.close}
        onClick={() => props.onClose()}
      />
      <div class="image-viewer-bar">
        <IconButton
          icon={Symbols.zoom_out}
          tooltip={t.imageViewer.zoomOut}
          disabled={scale() <= 1}
          onClick={() => zoomAtCentre(view.scale / zoomStep)}
        />
        <Show when={percent()}>{(text) => <span class="image-viewer-percent">{text()}</span>}</Show>
        <IconButton
          icon={Symbols.zoom_in}
          tooltip={t.imageViewer.zoomIn}
          disabled={scale() >= limit()}
          onClick={() => zoomAtCentre(view.scale * zoomStep)}
        />
        <IconButton
          icon={Symbols.fit_screen}
          tooltip={t.imageViewer.fit}
          disabled={scale() <= 1}
          onClick={() => zoomAtCentre(1)}
        />
      </div>
    </div>
  );
}

/** Opens {@link ImageViewer} on `image` over the app; resolves once it closed. */
export function showImageViewer(image: Blob | Uint8Array): Promise<void> {
  // Image bytes never live on a SharedArrayBuffer, which Blob refuses.
  const url = URL.createObjectURL(image instanceof Blob ? image : new Blob([image as Uint8Array<ArrayBuffer>]));
  return showDialog<void>((close) => <ImageViewer url={url} onClose={() => close()} />).then(() =>
    URL.revokeObjectURL(url),
  );
}
