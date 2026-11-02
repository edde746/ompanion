// The logic of lib/screens/chat/transcript/images.dart: image bytes and the pixel size in their header, and what the
// lines beside a machine image say. Its widgets are images_view.tsx.
import type { HostImageBytes, HostImageProblem } from "../../../../core/host/host_image";
import type { InlineImageBlock } from "../../../../core/store/content";
import { base64Decode } from "../../../../core/util/base64";
import { t } from "../../../i18n/i18n";
import { formatBytes } from "../../../utils/byte_size";

export interface ImageSize {
  readonly width: number;
  readonly height: number;
}

const decoded = new WeakMap<InlineImageBlock, Uint8Array>();
const sizes = new WeakMap<Uint8Array, ImageSize>();

/** The decoded bytes of `image`, decoded once per block. */
export function imageBytes(image: InlineImageBlock): Uint8Array {
  let bytes = decoded.get(image);
  if (!bytes) {
    bytes = base64Decode(image.data);
    decoded.set(image, bytes);
  }
  return bytes;
}

/**
 * The pixel size stored in the header of `image` (PNG, JPEG, GIF, WebP), or undefined. Read before decoding so a
 * thumbnail takes its final height at once and the transcript does not shift when the picture arrives.
 */
export function imageSize(image: InlineImageBlock): ImageSize | undefined {
  return bytesSize(imageBytes(image));
}

/** {@link sniffImageSize} of `bytes`, read once per array. */
export function bytesSize(bytes: Uint8Array): ImageSize | undefined {
  const cached = sizes.get(bytes);
  if (cached) return cached;
  const size = sniffImageSize(bytes);
  if (size) sizes.set(bytes, size);
  return size;
}

/** Width and height from an image file header (PNG, GIF, WebP, JPEG, BMP). */
export function sniffImageSize(b: Uint8Array): ImageSize | undefined {
  const at = (i: number) => b[i] ?? 0;
  const be16 = (i: number) => (at(i) << 8) | at(i + 1);
  const le16 = (i: number) => at(i) | (at(i + 1) << 8);
  const be32 = (i: number) => ((at(i) << 24) | (at(i + 1) << 16) | (at(i + 2) << 8) | at(i + 3)) >>> 0;
  const le32 = (i: number) => at(i) | (at(i + 1) << 8) | (at(i + 2) << 16) | (at(i + 3) << 24);
  if (b.length >= 24 && at(0) === 0x89 && at(1) === 0x50 && at(2) === 0x4e && at(3) === 0x47) {
    return { width: be32(16), height: be32(20) };
  }
  if (b.length >= 10 && at(0) === 0x47 && at(1) === 0x49 && at(2) === 0x46) return { width: le16(6), height: le16(8) };
  // A bottom-up BMP stores a negative height.
  if (b.length >= 26 && at(0) === 0x42 && at(1) === 0x4d) return { width: le32(18), height: Math.abs(le32(22)) };
  if (b.length >= 30 && at(0) === 0x52 && at(1) === 0x49 && at(2) === 0x46 && at(3) === 0x46 && at(8) === 0x57) {
    const chunk = String.fromCharCode(at(12), at(13), at(14), at(15));
    if (chunk === "VP8 ") return { width: le16(26) & 0x3fff, height: le16(28) & 0x3fff };
    if (chunk === "VP8L") {
      const bits = (at(21) | (at(22) << 8) | (at(23) << 16) | (at(24) << 24)) >>> 0;
      return { width: (bits & 0x3fff) + 1, height: ((bits >>> 14) & 0x3fff) + 1 };
    }
    if (chunk === "VP8X") {
      return {
        width: (at(24) | (at(25) << 8) | (at(26) << 16)) + 1,
        height: (at(27) | (at(28) << 8) | (at(29) << 16)) + 1,
      };
    }
    return undefined;
  }
  if (b.length >= 4 && at(0) === 0xff && at(1) === 0xd8) {
    let i = 2;
    while (i + 9 < b.length) {
      if (at(i) !== 0xff) return undefined;
      const marker = at(i + 1);
      // Start-of-frame markers carry the size; DHT (C4), JPG (C8) and DAC (CC) share the range but do not.
      if (marker >= 0xc0 && marker <= 0xcf && marker !== 0xc4 && marker !== 0xc8 && marker !== 0xcc) {
        return { width: be16(i + 7), height: be16(i + 5) };
      }
      i += 2 + be16(i + 2);
    }
  }
  return undefined;
}

/** The last segment of `path`: the name a machine image goes by. */
export function imageName(path: string): string {
  return (
    path
      .split(/[/\\]/)
      .reverse()
      .find((part) => part.length > 0) ?? path
  );
}

/** The line under a machine image named by `path`: its name, pixel size, and how much of it a preview sent. */
export function imageCaption(path: string, image: HostImageBytes): string {
  const facts = [imageName(path)];
  if (image.width !== undefined && image.height !== undefined) facts.push(`${image.width}×${image.height}`);
  if (image.preview) {
    facts.push(t.transcript.imagePreview({ sent: formatBytes(image.bytes.length), size: formatBytes(image.size) }));
  }
  return facts.join(" · ");
}

/** What the notice in place of the machine image `path` says about `problem`. */
export function imageProblemText(path: string, problem: HostImageProblem): string {
  const tr = t.transcript;
  switch (problem.issue) {
    case "missing":
      return tr.imageMissing({ path });
    case "notFile":
      return tr.imageNotFile({ path });
    case "denied":
      return tr.imageDenied({ path });
    case "notImage":
      return tr.imageNotImage({ path });
    case "unsupported":
      return tr.imageUnsupported({ path, size: formatBytes(problem.size ?? 0) });
    case "tooLarge":
      return tr.imageTooLarge({ path, size: formatBytes(problem.size ?? 0) });
  }
}
