import { open, stat } from "node:fs/promises";
import type { AgentToolResult, ExtensionAPI } from "@oh-my-pi/pi-coding-agent";

/**
 * `html_render`: the agent shows an HTML page in the chat, where the call sits. The app renders `details.html ??
 * args.html` in a sandboxed frame (ui `PageFrame`); this module only checks the page and inlines its local images.
 */

/**
 * Longest `html` argument, in characters. Streaming a call costs more than its size: every delta resends the whole
 * message (measured with omp 18.12.6, 1000 characters a second: 100 KB wrote 504 MB of run log before the pump
 * coalesced updates), and the page stays in the model's context (about 35K tokens at 100 KB).
 */
export const MAX_HTML = 100_000;
export const MAX_TITLE = 200;
const MIB = 1024 * 1024;
/** Bytes of one local image file. */
export const MAX_IMAGE_BYTES = 5 * MIB;
/** UTF-8 bytes of the page after its images are inlined. */
export const MAX_PAGE_BYTES = 10 * MIB;

export const HTML_RENDER_RESULT =
	"Shown to the reader where you called this, above your reply. " +
	"Don't mention or describe the page; reply with only what it doesn't already say.";

/** The model's only guidance. The variables are the ones the frame defines from the app's theme (ui `PageFrame`). */
export const HTML_RENDER_DESCRIPTION = [
	"Shows an HTML page to the reader, in the chat where you call this, above your reply. Use it when a chart, " +
		"diagram, mockup or visual comparison says more than text.",
	"Send a complete, self-contained document: scripts, styles and fonts inline or from https URLs (CDN libraries " +
		"work). Local images given by absolute path are inlined.",
	"The frame is as wide as your reply (about 360 px on phones, up to about 800 px on desktops) and its height " +
		"follows the page, up to 20000 px: no vh units, no height:100% on html or body, fixed pixel heights for charts.",
	"Leave html and body without background, border or padding: the page sits on the chat's background. A box that " +
		"needs a background uses var(--card) and var(--radius).",
	"Use the theme's CSS variables for colours, corners and fonts: --background --foreground --muted " +
		"--muted-foreground --card --card-foreground --border --accent --accent-foreground --error --warning --success " +
		"--chart-1 --chart-2 --chart-3 --chart-4 --chart-5 --chart-6 --radius --font-sans --font-mono.",
	"Links ask the reader before they open.",
].join("\n");

export interface HtmlRenderParams {
	title: string;
	html: string;
}

/** `html` only when `execute` changed the page (an image was inlined); the app shows `details.html ?? args.html`. */
export interface HtmlRenderDetails {
	title: string;
	html?: string;
}

export function registerHtmlRender(pi: ExtensionAPI): void {
	const z = pi.zod;
	// Title first: the app shows it while the page streams.
	const parameters = z.object({
		title: z.string().min(1).max(MAX_TITLE).describe("Shown above the page; the file name when the reader saves it."),
		html: z.string().min(1).max(MAX_HTML).describe("A complete HTML document."),
	});
	pi.registerTool<typeof parameters, HtmlRenderDetails>({
		name: "html_render",
		label: "Page",
		description: HTML_RENDER_DESCRIPTION,
		loadMode: "essential",
		approval: "read",
		parameters,
		execute: (_toolCallId, params, signal) => htmlRender(params, signal),
	});
}

/**
 * The tool's `execute`. Every refusal is an `Error` whose message tells the model what to change; omp returns it as
 * an error result.
 */
export async function htmlRender(
	params: HtmlRenderParams,
	signal?: AbortSignal,
): Promise<AgentToolResult<HtmlRenderDetails>> {
	const title = params.title.trim();
	if (title === "") throw new Error("The title is blank. Give the page a short title.");
	const units = viewportHeightUnits(params.html);
	if (units.length > 0) {
		throw new Error(
			`The page's CSS uses viewport height units (${units.join(", ")}). The frame's height follows the page, so a ` +
				"height that follows the frame's viewport makes it grow again and again. Let the content set the height, " +
				"or use fixed pixel heights.",
		);
	}
	const html = await inlineLocalImages(params.html, signal);
	return {
		content: [{ type: "text", text: HTML_RENDER_RESULT }],
		details: html === params.html ? { title } : { title, html },
	};
}

// t3code's: the lookbehind skips runs like base64 data (`...+12vh`), the lookahead names like `12vhx`.
const VIEWPORT_HEIGHT = /(?<![\w.+/])(?:\d+(?:\.\d+)?|\.\d+)[sld]?vh(?![\w-])/gi;

/**
 * Elements whose content the parser does not read as markup (or, for `style`, reads as CSS), and comments. Matched
 * leftmost first, as the parser meets them, so a comment inside a script and a script inside a comment both stay
 * inert. An unclosed one runs to the end of the page, as in the parser.
 */
const RAW_TEXT = new RegExp(
	String.raw`<!--[\s\S]*?(?:-->|$)` +
		String.raw`|(<(script|style|textarea|title|xmp|iframe|noembed|noframes|noscript)\b(?:"[^"]*"|'[^']*'|[^"'>])*>)` +
		String.raw`([\s\S]*?)(?:<\/\2\b[^>]*>|$)`,
	"gi",
);
const START_TAG = /<[a-z][^\s/>]*((?:"[^"]*"|'[^']*'|[^"'>])*)>/gi;
const ATTRIBUTE = /([^\s"'>/=]+)(?:\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'>]+)))?/g;
const CSS_COMMENT = /\/\*[\s\S]*?(?:\*\/|$)/g;

/** Viewport height lengths in the page's CSS (`<style>` bodies, `style` attributes), not in scripts, text or comments. */
export function viewportHeightUnits(html: string): string[] {
	const css: string[] = [];
	const markup = html.replace(RAW_TEXT, (_match, startTag?: string, element?: string, body?: string) => {
		if (startTag === undefined) return " ";
		if (element?.toLowerCase() === "style") css.push(body ?? "");
		// The start tag stays: its own `style` attribute is CSS.
		return `${startTag} `;
	});
	for (const tag of markup.matchAll(START_TAG)) {
		for (const attribute of (tag[1] ?? "").matchAll(ATTRIBUTE)) {
			if (attribute[1]?.toLowerCase() === "style") css.push(attribute[2] ?? attribute[3] ?? attribute[4] ?? "");
		}
	}
	const found = new Set<string>();
	for (const source of css) {
		for (const match of source.replace(CSS_COMMENT, " ").matchAll(VIEWPORT_HEIGHT)) found.add(match[0]);
	}
	return [...found];
}

interface ImageType {
	name: string;
	mime: string;
	/** Whether the file's bytes are this type, so a renamed file (a key named `.png`) is never inlined. */
	matches: (bytes: Uint8Array) => boolean;
}

function hasAt(bytes: Uint8Array, at: number, signature: string | readonly number[]): boolean {
	const codes = typeof signature === "string" ? Array.from(signature, char => char.charCodeAt(0)) : signature;
	return codes.every((code, index) => bytes[at + index] === code);
}

const JPEG: ImageType = { name: "JPEG", mime: "image/jpeg", matches: bytes => hasAt(bytes, 0, [0xff, 0xd8, 0xff]) };

const IMAGE_TYPES: Record<string, ImageType> = {
	png: {
		name: "PNG",
		mime: "image/png",
		matches: bytes => hasAt(bytes, 0, [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
	},
	jpg: JPEG,
	jpeg: JPEG,
	gif: { name: "GIF", mime: "image/gif", matches: bytes => hasAt(bytes, 0, "GIF87a") || hasAt(bytes, 0, "GIF89a") },
	webp: { name: "WebP", mime: "image/webp", matches: bytes => hasAt(bytes, 0, "RIFF") && hasAt(bytes, 8, "WEBP") },
	avif: {
		name: "AVIF",
		mime: "image/avif",
		matches: bytes => hasAt(bytes, 4, "ftyp") && ["avif", "avis", "mif1"].some(brand => hasAt(bytes, 8, brand)),
	},
	svg: { name: "SVG", mime: "image/svg+xml", matches: isSvg },
	bmp: { name: "BMP", mime: "image/bmp", matches: bytes => hasAt(bytes, 0, "BM") },
	ico: { name: "ICO", mime: "image/x-icon", matches: bytes => hasAt(bytes, 0, [0x00, 0x00, 0x01, 0x00]) },
};

/** An SVG root after an optional XML prolog: declaration, processing instructions, comments, a doctype. */
function isSvg(bytes: Uint8Array): boolean {
	const text = new TextDecoder().decode(bytes);
	let at = 0;
	while (at !== -1) {
		while (at < text.length && " \t\r\n".includes(text.charAt(at))) at++;
		if (text.startsWith("<?", at)) at = skipPast(text, "?>", at);
		else if (text.startsWith("<!--", at)) at = skipPast(text, "-->", at);
		else if (text.startsWith("<!DOCTYPE", at)) {
			// An internal subset (`[...]`) may hold `>`.
			const subset = text.indexOf("[", at);
			const close = text.indexOf(">", at);
			at = skipPast(text, ">", subset !== -1 && (close === -1 || subset < close) ? skipPast(text, "]", subset) : at);
		} else return /^<svg[\s/>]/.test(text.slice(at, at + 5));
	}
	return false;
}

/** Index just past the first `token` at or after `from`, or -1 (also when `from` is -1). */
function skipPast(text: string, token: string, from: number): number {
	if (from === -1) return -1;
	const index = text.indexOf(token, from);
	return index === -1 ? -1 : index + token.length;
}

const ABSOLUTE_PATH = String.raw`(?:\/(?!\/)|[a-z]:[\\\/])`;
const IMAGE_EXTENSION = String.raw`\.(?<ext>${Object.keys(IMAGE_TYPES).join("|")})`;
/** A path inside the quotes `q`. */
const QUOTED_PATH = String.raw`(?<path>${ABSOLUTE_PATH}(?:(?!\k<q>)[^<>\r\n]){0,2048}?${IMAGE_EXTENSION})`;

/** Where a local image may be given: a quoted attribute value that is the whole path, and CSS `url(...)`. */
const LOCAL_IMAGES: readonly RegExp[] = [
	String.raw`(?<lead>=\s*(?<q>["']))${QUOTED_PATH}(?=\k<q>)`,
	String.raw`(?<lead>url\(\s*(?<q>["']))${QUOTED_PATH}(?=\k<q>\s*\))`,
	String.raw`(?<lead>url\(\s*)(?<path>${ABSOLUTE_PATH}[^\s"'()<>]{0,2048}?${IMAGE_EXTENSION})(?=\s*\))`,
].map(source => new RegExp(source, "gi"));

/** Replaces every local image path in `html` with `rewrite(path, extension)`. */
function mapLocalImages(html: string, rewrite: (path: string, extension: string) => string): string {
	let page = html;
	for (const pattern of LOCAL_IMAGES) {
		let out = "";
		let last = 0;
		for (const match of page.matchAll(pattern)) {
			const { lead = "", path = "", ext = "" } = match.groups ?? {};
			const start = match.index + lead.length;
			out += page.slice(last, start) + rewrite(path, ext.toLowerCase());
			last = start + path.length;
		}
		page = out + page.slice(last);
	}
	return page;
}

interface LocalImage {
	/** The path as the page writes it. */
	path: string;
	type: ImageType;
	size: number;
	/** Every reference to it is replaced. */
	uses: number;
	data?: string;
}

/** A path written in a JavaScript string escapes Windows' backslashes. */
function filePath(written: string): string {
	return /^[a-z]:/i.test(written) ? written.replaceAll("\\\\", "\\") : written;
}

const mib = (bytes: number): string => `${(bytes / MIB).toFixed(1)} MiB`;

function unreadable(problems: readonly string[]): Error {
	return new Error(
		`These local images could not be inlined: ${problems.join("; ")}. Use absolute paths to existing image files ` +
			`of at most ${MAX_IMAGE_BYTES / MIB} MiB each, or remove them.`,
	);
}

function pageTooLarge(bytes: number): Error {
	return new Error(
		`With its images inlined the page is ${mib(bytes)}; the limit is ${MAX_PAGE_BYTES / MIB} MiB. ` +
			"Use fewer or smaller images.",
	);
}

function readProblem(error: unknown): string {
	const code = error instanceof Error && "code" in error ? error.code : undefined;
	if (code === "ENOENT" || code === "ENOTDIR") return "no such file";
	return `cannot be read (${typeof code === "string" ? code : error instanceof Error ? error.message : String(error)})`;
}

/** At most `limit + 1` bytes of `file`: more than `limit` means it is too large, whatever `stat` said before. */
async function readCapped(file: string, limit: number): Promise<Buffer> {
	const handle = await open(file, "r");
	try {
		const buffer = Buffer.allocUnsafe(limit + 1);
		let length = 0;
		while (length < buffer.length) {
			const { bytesRead } = await handle.read(buffer, length, buffer.length - length, length);
			if (bytesRead === 0) break;
			length += bytesRead;
		}
		return buffer.subarray(0, length);
	} finally {
		await handle.close();
	}
}

/**
 * Inlines each local image the page gives by absolute path as a `data:` URL. Remote, relative and `data:` URLs stay
 * as they are. Sizes are checked from `stat` before anything is read, and again on the bytes read.
 */
export async function inlineLocalImages(html: string, signal?: AbortSignal): Promise<string> {
	const images = new Map<string, LocalImage>();
	mapLocalImages(html, (path, extension) => {
		const type = IMAGE_TYPES[extension];
		if (!type) throw new Error(`no image type for .${extension}`);
		const image = images.get(path);
		if (image) image.uses++;
		else images.set(path, { path, type, size: 0, uses: 1 });
		return path;
	});
	if (images.size === 0) return html;

	const problems: string[] = [];
	for (const image of images.values()) {
		signal?.throwIfAborted();
		try {
			const info = await stat(filePath(image.path));
			if (!info.isFile()) problems.push(`${image.path} (not a file)`);
			else if (info.size > MAX_IMAGE_BYTES) problems.push(`${image.path} (${mib(info.size)}, too large)`);
			image.size = info.size;
		} catch (error) {
			problems.push(`${image.path} (${readProblem(error)})`);
		}
	}
	if (problems.length > 0) throw unreadable(problems);
	let estimate = Buffer.byteLength(html);
	for (const image of images.values()) {
		const dataUrl = `data:${image.type.mime};base64,`.length + Math.ceil(image.size / 3) * 4;
		estimate += image.uses * (dataUrl - Buffer.byteLength(image.path));
	}
	if (estimate > MAX_PAGE_BYTES) throw pageTooLarge(estimate);

	for (const image of images.values()) {
		signal?.throwIfAborted();
		let bytes: Buffer;
		try {
			bytes = await readCapped(filePath(image.path), MAX_IMAGE_BYTES);
		} catch (error) {
			problems.push(`${image.path} (${readProblem(error)})`);
			continue;
		}
		if (bytes.length > MAX_IMAGE_BYTES) problems.push(`${image.path} (over ${MAX_IMAGE_BYTES / MIB} MiB, too large)`);
		else if (!image.type.matches(bytes)) problems.push(`${image.path} (not a ${image.type.name} image)`);
		else image.data = `data:${image.type.mime};base64,${bytes.toString("base64")}`;
	}
	if (problems.length > 0) throw unreadable(problems);

	const page = mapLocalImages(html, path => images.get(path)?.data ?? path);
	const bytes = Buffer.byteLength(page);
	if (bytes > MAX_PAGE_BYTES) throw pageTooLarge(bytes);
	return page;
}
