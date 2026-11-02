// Port of packages/omp_core/test/host/images.dart.
import { deflateSync } from "node:zlib";

/**
 * A valid RGB PNG of [width]×[height]. [noise] fills it with random pixels, which do not compress, so the file is
 * about 3 bytes per pixel; otherwise it is a gradient.
 */
export function pngBytes(width: number, height: number, options: { noise?: boolean } = {}): Uint8Array {
  const noise = options.noise ?? false;
  const random = () => Math.floor(Math.random() * 256);
  const raw = new Uint8Array(height * (1 + width * 3));
  for (let y = 0; y < height; y++) {
    const row = y * (1 + width * 3);
    for (let x = 0; x < width; x++) {
      const i = row + 1 + x * 3;
      raw[i] = noise ? random() : Math.floor((x * 255) / width);
      raw[i + 1] = noise ? random() : Math.floor((y * 255) / height);
      raw[i + 2] = noise ? random() : 128;
    }
  }
  const header = new Uint8Array(13);
  const view = new DataView(header.buffer);
  view.setUint32(0, width);
  view.setUint32(4, height);
  view.setUint8(8, 8);
  view.setUint8(9, 2);
  return Uint8Array.from([
    0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a,
    ...chunk("IHDR", header),
    ...chunk("IDAT", deflateSync(raw, { level: noise ? 0 : 6 })),
    ...chunk("IEND", new Uint8Array(0)),
  ]);
}

function chunk(type: string, data: Uint8Array): number[] {
  const typed = Array.from(type, (c) => c.charCodeAt(0));
  const length = new Uint8Array(4);
  new DataView(length.buffer).setUint32(0, data.length);
  const crc = new Uint8Array(4);
  new DataView(crc.buffer).setUint32(0, crc32([...typed, ...data]));
  return [...length, ...typed, ...data, ...crc];
}

function crc32(bytes: readonly number[]): number {
  let crc = 0xffffffff;
  for (const byte of bytes) {
    crc ^= byte;
    for (let k = 0; k < 8; k++) crc = crc & 1 ? 0xedb88320 ^ (crc >>> 1) : crc >>> 1;
  }
  return (crc ^ 0xffffffff) >>> 0;
}

/**
 * A PNG signature and header followed by [length] bytes in total of padding: a file whose first bytes say PNG, for
 * tests of size limits that never decode it.
 */
export function pngLookalike(length: number): Uint8Array {
  const bytes = new Uint8Array(length);
  bytes.set(pngBytes(1, 1).subarray(0, 33));
  return bytes;
}

/** The first bytes of a little-endian TIFF, padded to [length]. */
export function tiffLookalike(length: number): Uint8Array {
  const bytes = new Uint8Array(length);
  bytes.set([0x49, 0x49, 0x2a, 0x00, 0x08, 0, 0, 0]);
  return bytes;
}
