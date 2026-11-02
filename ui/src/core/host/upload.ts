// Port of packages/omp_core/lib/src/host/upload.dart.
import { HostFileExists, HostLinkException, type HostFiles } from "../transport/host_link";
import { concatBytes } from "../util/bytes";

/**
 * Bytes to upload, pulled one part at a time: a source that waits between parts (an async generator over a download
 * or a file reader) is read no faster than the machine takes it. An EventStream is one too, without that pacing.
 */
export type ByteSource = AsyncIterable<Uint8Array> | Iterable<Uint8Array>;

const chunkSize = 4 << 20;

/**
 * Streams [bytes] to [path] (SFTP path space) in 4 MiB appends, so a large file is never held in memory at once.
 * [mode] applies on creation; [onProgress] gets the bytes written so far after every append.
 */
export async function writeStream(
  files: HostFiles,
  path: string,
  bytes: ByteSource,
  options: { mode?: number; onProgress?: (written: number) => void } = {},
): Promise<void> {
  let parts: Uint8Array[] = [];
  let length = 0;
  let first = true;
  let written = 0;
  const flush = async () => {
    const data = concatBytes(parts);
    parts = [];
    length = 0;
    await files.write(path, data, { append: !first, mode: first ? options.mode : undefined });
    first = false;
    written += data.length;
    options.onProgress?.(written);
  };

  for await (const part of bytes) {
    for (let offset = 0; offset < part.length; ) {
      const take = Math.min(chunkSize - length, part.length - offset);
      parts.push(part.subarray(offset, offset + take));
      length += take;
      offset += take;
      if (length === chunkSize) await flush();
    }
  }
  if (first || length > 0) await flush();
}

/**
 * Uploads [bytes] as [name] into [dir] (SFTP path space), creating [dir] and its missing parents. The name is made
 * safe first ([safeFileName]); a name already in [dir] gets `-2`, `-3`, … before its extension, so an earlier upload
 * stays as it was. Only the owner can read the file. A failed upload is removed. Returns the file's SFTP path.
 */
export async function uploadAttachment(
  files: HostFiles,
  options: { dir: string; name: string; bytes: ByteSource; onProgress?: (written: number) => void },
): Promise<string> {
  const { dir } = options;
  await makeDirectories(files, dir);
  const safe = safeFileName(options.name);
  const dot = safe.lastIndexOf(".");
  const [stem, extension] = dot > 0 ? [safe.substring(0, dot), safe.substring(dot)] : [safe, ""];
  let path = `${dir}/${safe}`;
  for (let n = 2; (await files.stat(path, { followLinks: false })) !== null; n++) {
    path = `${dir}/${stem}-${n}${extension}`;
  }
  await writeOrRemove(files, path, options.bytes, options.onProgress);
  return path;
}

/**
 * Saves [text] in [dir] (SFTP path space) as `paste-<n>.md`, n the first number without a file, as the TUI's "Attach
 * as local file" names a large paste in the session's `local://` store. Returns the file name.
 */
export async function savePaste(
  files: HostFiles,
  options: { dir: string; text: string; onProgress?: (written: number) => void },
): Promise<string> {
  const { dir } = options;
  await makeDirectories(files, dir);
  let n = 1;
  while ((await files.stat(`${dir}/paste-${n}.md`, { followLinks: false })) !== null) n++;
  await writeOrRemove(files, `${dir}/paste-${n}.md`, [new TextEncoder().encode(options.text)], options.onProgress);
  return `paste-${n}.md`;
}

async function writeOrRemove(
  files: HostFiles,
  path: string,
  bytes: ByteSource,
  onProgress: ((written: number) => void) | undefined,
): Promise<void> {
  try {
    await writeStream(files, path, bytes, { mode: 0o600, onProgress });
  } catch (error) {
    try {
      if ((await files.stat(path, { followLinks: false })) !== null) await files.remove(path);
    } catch {
      // The link is gone as well; the partial file stays, under a name the next upload skips. The upload's own error
      // is the one thrown below.
    }
    throw error;
  }
}

/** Creates [dir] (SFTP path space) and its missing parents, each only its owner can enter. */
export async function makeDirectories(files: HostFiles, dir: string): Promise<void> {
  const stat = await files.stat(dir);
  if (stat !== null) {
    if (!stat.isDirectory) throw new HostLinkException(`${dir} is not a directory`);
    return;
  }
  const cut = dir.lastIndexOf("/");
  if (cut > 0) await makeDirectories(files, dir.substring(0, cut));
  try {
    await files.mkdir(dir, { mode: 0o700 });
  } catch (error) {
    // Another device made it meanwhile.
    if (!(error instanceof HostFileExists)) throw error;
  }
}

/**
 * [name] as a file name every machine accepts and a quoted `@"…"` mention can carry: path separators, control
 * characters and what Windows forbids (`<>:"|?*`) become `_`; leading spaces and trailing spaces and dots go.
 */
export function safeFileName(name: string): string {
  const safe = name
    .replace(/[\x00-\x1f<>:"/\\|?*]/g, "_")
    .replace(/^\s+/, "")
    .replace(/[\s.]+$/, "");
  return safe === "" ? "attachment" : safe;
}
