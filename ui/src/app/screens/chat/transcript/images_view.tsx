// The widgets of lib/screens/chat/transcript/images.dart: thumbnails, fitted images and images loaded from the
// session's machine, which open in the image viewer (widgets/image_viewer.tsx). Their logic is images.ts.
import {
  type Accessor,
  createEffect,
  createMemo,
  createSignal,
  For,
  Match,
  onCleanup,
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
import { TextButton } from "../../../widgets/button";
import { Icon } from "../../../widgets/icon";
import { showImageViewer } from "../../../widgets/image_viewer";
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
 * opens the image viewer. An image in omp's blob store loads from the session's machine ({@link MachineImage}).
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
      onClick={() => void showImageViewer(props.bytes)}
    >
      <Show when={!broken()} fallback={<BrokenImage />}>
        <img class="images-view-picture" src={url()} alt={t.transcript.image} onError={() => setBroken(true)} />
      </Show>
    </button>
  );
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
 * sized from its header before it decodes; tapping it opens the image viewer.
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
      onClick={() => void showImageViewer(props.bytes)}
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
      // The notice of what is wrong with the image would hide this failure, which is newer (a failed Load Original).
      if (problem() !== undefined) setImage(undefined);
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
