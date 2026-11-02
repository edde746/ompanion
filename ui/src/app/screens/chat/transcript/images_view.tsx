// The widgets of lib/screens/chat/transcript/images.dart: thumbnails, the zoomable viewer, fitted images and images
// loaded from the session's machine. Their logic is images.ts.
import {
  type Accessor,
  createEffect,
  createMemo,
  createSignal,
  For,
  Match,
  onCleanup,
  onSettled,
  Show,
  Switch,
  untrack,
  useContext,
} from "solid-js";
import type { JSX } from "@solidjs/web";
import { type HostImage, hostImageProblemCanLoadOriginal } from "../../../../core/host/host_image";
import type { ImageBlock } from "../../../../core/store/content";
import { t } from "../../../i18n/i18n";
import { ImageLoadAbandoned } from "../../../sessions/machine_images";
import { appLogger } from "../../../utils/app_logger";
import { formatBytes } from "../../../utils/byte_size";
import { ActivityMark } from "../../../widgets/activity_mark";
import { IconButton, TextButton } from "../../../widgets/button";
import { showDialog } from "../../../widgets/dialog";
import { Icon } from "../../../widgets/icon";
import * as Symbols from "../../../widgets/symbols";
import { bytesSize, imageBytes, imageCaption, imageName, imageProblemText } from "./images";
import "./images_view.css";
import { TranscriptScope } from "./transcript_actions";

/** An object URL of `bytes()` for an `<img>`, revoked when the bytes change or the component goes. */
function objectUrl(bytes: Accessor<Uint8Array>): Accessor<string> {
  return createMemo(() => {
    // Image bytes never live on a SharedArrayBuffer, which Blob refuses.
    const url = URL.createObjectURL(new Blob([bytes() as Uint8Array<ArrayBuffer>]));
    onCleanup(() => URL.revokeObjectURL(url));
    return url;
  });
}

/** In place of an image the browser cannot decode. */
function BrokenImage() {
  return (
    <span class="images-view-broken">
      <Icon icon={Symbols.broken_image} />
    </span>
  );
}

/**
 * A thumbnail of `image` at most 240 px tall and 480 px wide, sized from its header before it decodes; tapping it
 * opens a zoomable view. An image in omp's blob store loads from the session's machine ({@link MachineImage}).
 */
export function TranscriptImage(props: { image: ImageBlock }) {
  return (
    <Switch>
      <Match when={props.image.kind === "InlineImageBlock" ? props.image : undefined}>
        {(image) => <Thumbnail bytes={imageBytes(image())} />}
      </Match>
      <Match when={props.image.kind === "BlobImageBlock" ? props.image : undefined}>
        {(image) => <MachineImage blob={image().hash} thumbnail />}
      </Match>
    </Switch>
  );
}

const thumbnailWidth = 480;
const thumbnailHeight = 240;

/** Image `bytes` as a {@link TranscriptImage}. */
function Thumbnail(props: { bytes: Uint8Array }) {
  const url = objectUrl(() => props.bytes);
  const [broken, setBroken] = createSignal(false);
  const box = createMemo(() => {
    const size = bytesSize(props.bytes);
    if (!size || size.width <= 0 || size.height <= 0) return { width: thumbnailWidth, height: thumbnailHeight };
    const scale = Math.min(thumbnailWidth / size.width, thumbnailHeight / size.height, 1);
    return { width: size.width * scale, height: size.height * scale };
  });
  return (
    <button
      type="button"
      class="images-view-thumbnail"
      style={{ width: `${box().width}px`, "aspect-ratio": `${box().width} / ${box().height}` }}
      onClick={() => void showZoomedImage(props.bytes)}
    >
      <Show when={!broken()} fallback={<BrokenImage />}>
        <img class="images-view-picture" src={url()} alt={t.transcript.image} onError={() => setBroken(true)} />
      </Show>
    </button>
  );
}

/** The most a pinch or a scroll magnifies the zoomed image. */
const maxScale = 8;

/** How far a pointer may move and still tap (Flutter's touch slop). */
const tapSlop = 18;

/**
 * `bytes` on the dialog scrim with no surface, zoomable across the window, a close button in the top right; the viewer
 * for images in the chat and the composer. A pinch or a scroll zooms, a drag pans, a tap beside the image closes it
 * (Escape and back close it through the dialog).
 */
export function ZoomedImage(props: { bytes: Uint8Array; onClose: () => void }) {
  const url = objectUrl(() => props.bytes);
  let area!: HTMLDivElement;
  let content!: HTMLDivElement;
  let image: HTMLImageElement | undefined;
  // Applied straight to the content's style: every pointer move changes it.
  let view = { x: 0, y: 0, scale: 1 };
  const pointers = new Map<number, { x: number; y: number }>();
  let tap: { id: number; x: number; y: number } | undefined;

  /**
   * Shows the content at `scale` (1 to `maxScale`) with its point under `from` moved to `to`, the window always
   * covered, as Flutter's InteractiveViewer keeps it.
   */
  function place(scale: number, from: { x: number; y: number }, to: { x: number; y: number }): void {
    const next = Math.min(Math.max(scale, 1), maxScale);
    const applied = next / view.scale;
    const width = area.clientWidth;
    const height = area.clientHeight;
    view = {
      scale: next,
      x: Math.min(Math.max(to.x - (from.x - view.x) * applied, width - width * next), 0),
      y: Math.min(Math.max(to.y - (from.y - view.y) * applied, height - height * next), 0),
    };
    content.style.transform = `translate(${view.x}px, ${view.y}px) scale(${view.scale})`;
  }

  function local(event: { clientX: number; clientY: number }): { x: number; y: number } {
    const rect = area.getBoundingClientRect();
    return { x: event.clientX - rect.left, y: event.clientY - rect.top };
  }

  function onPointerDown(event: PointerEvent): void {
    area.setPointerCapture(event.pointerId);
    pointers.set(event.pointerId, local(event));
    // A tap on the image does nothing; beside it, it closes the viewer.
    tap = pointers.size === 1 && event.target !== image ? { id: event.pointerId, ...local(event) } : undefined;
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
    const centre = (a: { x: number; y: number }) => ({ x: (a.x + other.x) / 2, y: (a.y + other.y) / 2 });
    const spread = (a: { x: number; y: number }) => Math.hypot(a.x - other.x, a.y - other.y);
    if (spread(before) > 0) place((view.scale * spread(after)) / spread(before), centre(before), centre(after));
  }

  function onPointerUp(event: PointerEvent): void {
    const tapped = tap?.id === event.pointerId && pointers.size === 1;
    pointers.delete(event.pointerId);
    tap = undefined;
    if (tapped) props.onClose();
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
    area.addEventListener("wheel", wheel, { passive: false });
    area.addEventListener("gesturestart", gestureStart);
    area.addEventListener("gesturechange", gestureChange);
    return () => {
      area.removeEventListener("wheel", wheel);
      area.removeEventListener("gesturestart", gestureStart);
      area.removeEventListener("gesturechange", gestureChange);
    };
  });

  return (
    <div class="images-view-zoom">
      <div
        class="images-view-zoom-area"
        ref={area}
        onPointerDown={onPointerDown}
        onPointerMove={onPointerMove}
        onPointerUp={onPointerUp}
        onPointerCancel={onPointerCancel}
      >
        <div class="images-view-zoom-content" ref={content}>
          <img
            class="images-view-zoom-image"
            ref={(element) => (image = element)}
            src={url()}
            alt={t.transcript.image}
            draggable={false}
          />
        </div>
      </div>
      <IconButton
        class="images-view-zoom-close"
        variant="tonal"
        icon={Symbols.close}
        tooltip={t.common.close}
        onClick={() => props.onClose()}
      />
    </div>
  );
}

/** Opens {@link ZoomedImage} over the app. */
export function showZoomedImage(bytes: Uint8Array): Promise<void> {
  return showDialog<void>((close) => <ZoomedImage bytes={bytes} onClose={() => close()} />).then(() => undefined);
}

/** `images` as a wrapping row of thumbnails. */
export function ImageStrip(props: { images: readonly ImageBlock[] }) {
  return (
    <div class="images-view-strip">
      <For each={props.images}>{(image) => <TranscriptImage image={image} />}</For>
    </div>
  );
}

/**
 * Image `bytes` as wide as the space it gets and at most `maxHeight` (360) tall, never larger than its own pixels,
 * sized from its header before it decodes; tapping it opens a zoomable view.
 */
export function FittedImage(props: { bytes: Uint8Array; maxHeight?: number }) {
  const url = objectUrl(() => props.bytes);
  const [broken, setBroken] = createSignal(false);
  const style = createMemo((): JSX.CSSProperties => {
    const size = bytesSize(props.bytes);
    const known = size !== undefined && size.width > 0 && size.height > 0;
    const width = known ? size.width : 16;
    const height = known ? size.height : 9;
    const maxHeight = Math.min(known ? size.height : Infinity, props.maxHeight ?? 360);
    const limits = known ? `${width}px, ${(maxHeight * width) / height}px` : `${(maxHeight * width) / height}px`;
    return { width: `min(100%, ${limits})`, "aspect-ratio": `${width} / ${height}` };
  });
  return (
    <button
      type="button"
      class="images-view-fitted"
      style={style()}
      onClick={() => void showZoomedImage(props.bytes)}
    >
      <Show when={!broken()} fallback={<BrokenImage />}>
        <img class="images-view-picture" src={url()} alt={t.transcript.image} onError={() => setBroken(true)} />
      </Show>
    </button>
  );
}

export type MachineImageProps =
  | {
      /** Host-native, `~/…` or relative to the session's directory. */
      readonly path: string;
      /** The image's name, pixel size and an "Open in Files" action under it (default true). */
      readonly caption?: boolean;
      readonly blob?: undefined;
      readonly thumbnail?: undefined;
    }
  | {
      /**
       * The image omp keeps as blob `blob` (BlobImageBlock), which has no name to show or place in Files to open: as a
       * `thumbnail` like {@link TranscriptImage}'s, else as a {@link FittedImage}.
       */
      readonly blob: string;
      readonly thumbnail?: boolean;
      readonly path?: undefined;
      readonly caption?: undefined;
    };

/**
 * An image file of the session's machine, named by `path`, or kept in omp's blob store (`blob`). It loads on its own:
 * it comes from the user's own machine over the session's link and cannot reach the network. It does not load while
 * its list scrolls too fast for it to be looked at, nor once it left the list. A notice shows while it loads, then the
 * image with its name and an "Open in Files" action (`caption`), or a notice of what is wrong; a file too large to send
 * on its own offers its original. Without a machine to load from (no `TranscriptActions.images`) the path shows as
 * text.
 */
export function MachineImage(props: MachineImageProps) {
  const scope = useContext(TranscriptScope);
  // Read once, as the Dart does: the screen hands down new actions on every change.
  const images = untrack(scope).images;
  let element: HTMLElement | undefined;
  /** What the notices name: the path, or omp's reference to the blob. */
  const label = () => props.path ?? `blob:sha256:${props.blob}`;
  const peek = (): HostImage | undefined =>
    props.blob !== undefined ? images?.peekBlob(props.blob) : images?.peek(props.path);
  const [image, setImage] = createSignal<HostImage | undefined>(untrack(peek));
  const [failure, setFailure] = createSignal<{ readonly error: unknown }>();
  const [loadingOriginal, setLoadingOriginal] = createSignal(false);
  // Whether the current path or blob is still the one shown; false once it changed or the image left the list.
  let wanted = () => false;

  async function load(original: boolean): Promise<void> {
    if (!images) return;
    const isWanted = wanted;
    const shown = label();
    try {
      const loaded =
        props.blob !== undefined
          ? await images.loadBlob(props.blob, { original, wanted: isWanted })
          : await images.load(props.path, { original, wanted: isWanted });
      if (!isWanted()) return;
      setImage(loaded);
      setFailure(undefined);
      setLoadingOriginal(false);
    } catch (error) {
      // The load this one joined was dropped just before: ask again.
      if (error instanceof ImageLoadAbandoned) {
        if (isWanted()) await load(original);
        return;
      }
      appLogger.w(`loading the image ${shown} failed`, { error });
      if (!isWanted()) return;
      setFailure({ error });
      setLoadingOriginal(false);
    }
  }

  /**
   * Loads the image unless its list scrolls too fast for it to be looked at (faster than the window's longer side in
   * physical pixels a second, Flutter's `recommendDeferredLoading`); then asks again next frame, so an image a fling
   * carries past never loads.
   */
  function request(isWanted: () => boolean): void {
    const scroller = element ? scrollParent(element) : undefined;
    if (!scroller) {
      void load(false);
      return;
    }
    const top = scroller.scrollTop;
    const time = performance.now();
    requestAnimationFrame(() => {
      if (!isWanted()) return;
      const seconds = Math.max(performance.now() - time, 1) / 1000;
      const limit = Math.max(window.innerWidth, window.innerHeight) * window.devicePixelRatio;
      if (Math.abs(scroller.scrollTop - top) / seconds > limit) request(isWanted);
      else void load(false);
    });
  }

  createEffect(label, () => {
    let live = true;
    const isWanted = () => live;
    wanted = isWanted;
    setImage(peek());
    setFailure(undefined);
    if (images) request(isWanted);
    return () => {
      live = false;
    };
  });

  const bytes = () => {
    const current = image();
    return current?.kind === "HostImageBytes" ? current : undefined;
  };
  const problem = () => {
    const current = image();
    return current?.kind === "HostImageProblem" ? current : undefined;
  };

  return (
    <Show when={images} fallback={<span>{label()}</span>}>
      <div class="images-view-machine" ref={(el) => (element = el)}>
        <Switch
          fallback={
            <Show
              when={failure()}
              fallback={
                <ImageNotice icon={Symbols.image} text={t.transcript.imageLoading({ name: imageName(label()) })}>
                  <ActivityMark size={16} />
                </ImageNotice>
              }
            >
              {(failed) => (
                <ImageNotice
                  icon={Symbols.error}
                  text={t.transcript.imageFailed({ path: label(), error: String(failed().error) })}
                >
                  <TextButton
                    onClick={() => {
                      setFailure(undefined);
                      setImage(peek());
                      request(wanted);
                    }}
                  >
                    {t.transcript.retryImage}
                  </TextButton>
                </ImageNotice>
              )}
            </Show>
          }
        >
          <Match when={bytes()}>
            {(loaded) => (
              <Show
                when={props.thumbnail}
                fallback={
                  <>
                    <FittedImage bytes={loaded().bytes} />
                    <Show when={props.path !== undefined && props.caption !== false ? props.path : undefined}>
                      {(path) => (
                        <div class="images-view-caption">
                          <span class="images-view-caption-facts">{imageCaption(path(), loaded())}</span>
                          <TextButton icon={Symbols.folder_open} onClick={() => scope().onOpenFile(path())}>
                            {t.transcript.openInFiles}
                          </TextButton>
                        </div>
                      )}
                    </Show>
                  </>
                }
              >
                <Thumbnail bytes={loaded().bytes} />
              </Show>
            )}
          </Match>
          <Match when={problem()}>
            {(found) => (
              <ImageNotice
                icon={
                  found().issue === "denied"
                    ? Symbols.lock
                    : found().issue === "tooLarge"
                      ? Symbols.photo_size_select_large
                      : Symbols.broken_image
                }
                text={imageProblemText(label(), found())}
              >
                <Show when={hostImageProblemCanLoadOriginal(found())}>
                  <Show when={!loadingOriginal()} fallback={<ActivityMark size={16} />}>
                    <TextButton
                      onClick={() => {
                        setLoadingOriginal(true);
                        void load(true);
                      }}
                    >
                      {t.transcript.loadOriginal({ size: formatBytes(found().size ?? 0) })}
                    </TextButton>
                  </Show>
                </Show>
              </ImageNotice>
            )}
          </Match>
        </Switch>
      </div>
    </Show>
  );
}

/** The nearest ancestor of `element` that scrolls vertically. */
function scrollParent(element: HTMLElement): HTMLElement | undefined {
  for (let parent = element.parentElement; parent; parent = parent.parentElement) {
    const overflow = getComputedStyle(parent).overflowY;
    if (overflow === "auto" || overflow === "scroll") return parent;
  }
  return undefined;
}

/** A compact line in place of a machine image: what is wrong, or that it loads, and an optional action. */
function ImageNotice(props: { icon: string; text: string; children?: JSX.Element }) {
  return (
    <div class="images-view-notice">
      <Icon icon={props.icon} size={18} />
      <span class="images-view-notice-text">{props.text}</span>
      {props.children}
    </div>
  );
}
