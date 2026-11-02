// Port of packages/omp_core/lib/src/store/content.dart.
import {
  asJsonObject,
  describeJson,
  FormatException,
  isJsonObject,
  optObject,
  optString,
  string,
  type JsonObject,
} from "../rpc/json_fields";

/**
 * One block of message content. Mirrors the content unions in omp `packages/ai/src/types.ts` (`TextContent`,
 * `ThinkingContent`, `RedactedThinkingContent`, `ImageContent`, `ToolCall`).
 */
export type ContentBlock = TextBlock | ThinkingBlock | RedactedThinkingBlock | ImageBlock | ToolCallBlock | OtherBlock;

export interface TextBlock {
  readonly kind: "TextBlock";
  readonly text: string;
}

export interface ThinkingBlock {
  readonly kind: "ThinkingBlock";
  readonly thinking: string;
  /** Provider replay signature (`thinkingSignature`); present when the provider signs reasoning. */
  readonly signature?: string;
}

/** Reasoning the provider returned encrypted; only its presence is displayable. */
export interface RedactedThinkingBlock {
  readonly kind: "RedactedThinkingBlock";
  readonly data: string;
}

/** An image in message content: its bytes inline, or in omp's blob store. */
export type ImageBlock = InlineImageBlock | BlobImageBlock;

export function isImageBlock(block: ContentBlock): block is ImageBlock {
  return block.kind === "InlineImageBlock" || block.kind === "BlobImageBlock";
}

export interface InlineImageBlock {
  readonly kind: "InlineImageBlock";
  /** Base64 image bytes. */
  readonly data: string;
  readonly mimeType: string;
  /** Optional https mirror of `data`. */
  readonly url?: string;
}

/**
 * An image in omp's blob store (`session/blob-store.ts`): omp writes an image of 1024 base64 characters or more to the
 * session file as `blob:sha256:<hash>` and puts the bytes back only when it loads the file itself, keeping the
 * reference when the blob is gone. The app reads session files itself, so its history holds the reference.
 */
export interface BlobImageBlock {
  readonly kind: "BlobImageBlock";
  /** SHA-256 of the image bytes in lowercase hex: the blob's file name. */
  readonly hash: string;
  readonly mimeType: string;
}

const blobRef = /^blob:sha256:([0-9a-f]{64})$/;

/** An omp image (`ImageContent`: `data`, `mimeType`, optional `url`) whose `data` is base64 or a blob reference. */
export function decodeImage(image: JsonObject): ImageBlock {
  const data = string(image, "data");
  const mimeType = string(image, "mimeType");
  const ref = blobRef.exec(data);
  if (ref?.[1] !== undefined) return { kind: "BlobImageBlock", hash: ref[1], mimeType };
  return { kind: "InlineImageBlock", data, mimeType, url: optString(image, "url") };
}

export interface ToolCallBlock {
  readonly kind: "ToolCallBlock";
  readonly id: string;
  readonly name: string;
  /** Tool arguments; partial while the assistant message streams. */
  readonly arguments: JsonObject;
  /** Harness-level intent (the `i` argument) when omp extracted one. */
  readonly intent?: string;
}

/**
 * A block the app does not render: `fallback`, `anthropicServerTool`, a type added by a newer omp, or an image without
 * inline bytes.
 */
export interface OtherBlock {
  readonly kind: "OtherBlock";
  readonly type: string;
  readonly raw: JsonObject;
}

/** Decodes message `content`: a plain string or an array of blocks. */
export function decodeContent(content: unknown): ContentBlock[] {
  if (content === null || content === undefined || content === "") return [];
  if (typeof content === "string") return [{ kind: "TextBlock", text: content }];
  if (Array.isArray(content)) return content.map((block) => decodeBlock(asJsonObject(block, "content block")));
  throw new FormatException(`content: expected a string or an array, got ${describeJson(content)}`);
}

export function decodeBlock(block: JsonObject): ContentBlock {
  const type = string(block, "type");
  switch (type) {
    case "text":
      return { kind: "TextBlock", text: string(block, "text") };
    case "thinking":
      return { kind: "ThinkingBlock", thinking: string(block, "thinking"), signature: optString(block, "thinkingSignature") };
    case "redactedThinking":
      return { kind: "RedactedThinkingBlock", data: string(block, "data") };
    case "toolCall":
      return {
        kind: "ToolCallBlock",
        id: string(block, "id"),
        name: string(block, "name"),
        arguments: optObject(block, "arguments") ?? {},
        intent: optString(block, "intent"),
      };
  }
  // omp's own renderers check `data` before use: an image may travel as a provider file reference only.
  if (type === "image" && typeof block.data === "string") return decodeImage(block);
  return { kind: "OtherBlock", type, raw: block };
}

/**
 * [next] with every block equal to the block at the same index of [previous] replaced by that previous instance, so a
 * UI can skip rebuilding finished blocks while a message streams. Returns [previous] itself when nothing changed.
 */
export function reuseBlocks(previous: readonly ContentBlock[], next: readonly ContentBlock[]): readonly ContentBlock[] {
  if (previous.length === 0) return next;
  let unchanged = previous.length === next.length;
  const merged = [...next];
  for (let i = 0; i < merged.length && i < previous.length; i++) {
    const old = previous[i] as ContentBlock;
    if (sameBlock(old, merged[i] as ContentBlock)) merged[i] = old;
    else unchanged = false;
  }
  return unchanged ? previous : merged;
}

function sameBlock(a: ContentBlock, b: ContentBlock): boolean {
  switch (a.kind) {
    case "TextBlock":
      return b.kind === "TextBlock" && a.text === b.text;
    case "ThinkingBlock":
      return b.kind === "ThinkingBlock" && a.thinking === b.thinking && a.signature === b.signature;
    case "RedactedThinkingBlock":
      return b.kind === "RedactedThinkingBlock" && a.data === b.data;
    case "InlineImageBlock":
      return b.kind === "InlineImageBlock" && a.data === b.data && a.mimeType === b.mimeType && a.url === b.url;
    case "BlobImageBlock":
      return b.kind === "BlobImageBlock" && a.hash === b.hash && a.mimeType === b.mimeType;
    case "ToolCallBlock":
      return (
        b.kind === "ToolCallBlock" &&
        a.id === b.id &&
        a.name === b.name &&
        a.intent === b.intent &&
        jsonEquals(a.arguments, b.arguments)
      );
    case "OtherBlock":
      return b.kind === "OtherBlock" && jsonEquals(a.raw, b.raw);
  }
}

function jsonEquals(a: unknown, b: unknown): boolean {
  if (a === b) return true;
  if (Array.isArray(a) || Array.isArray(b)) {
    if (!Array.isArray(a) || !Array.isArray(b) || a.length !== b.length) return false;
    return a.every((value, i) => jsonEquals(value, b[i]));
  }
  if (!isJsonObject(a) || !isJsonObject(b)) return false;
  const keys = Object.keys(a);
  if (keys.length !== Object.keys(b).length) return false;
  return keys.every((key) => key in b && jsonEquals(a[key], b[key]));
}

/** Concatenated text of the TextBlocks in [blocks]. */
export function textOf(blocks: readonly ContentBlock[]): string {
  let text = "";
  for (const block of blocks) if (block.kind === "TextBlock") text += block.text;
  return text;
}
