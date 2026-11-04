import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { mkdir, mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import * as path from "node:path";
import { HTML_RENDER_DESCRIPTION, htmlRender, viewportHeightUnits } from "../src/html-render.ts";

/** A PNG signature and the start of its header chunk: the inliner reads only the signature. */
const PNG = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x00, 0x00, 0x00, 0x0d, 0x49, 0x48]);
const JPEG = Buffer.from([0xff, 0xd8, 0xff, 0xe0, 0x00, 0x10, 0x4a, 0x46, 0x49, 0x46, 0x00]);
const SVG =
	'<?xml version="1.0"?>\n<!-- drawn by hand -->\n<!DOCTYPE svg [ <!ENTITY c "red"> ]>\n' +
	'<svg xmlns="http://www.w3.org/2000/svg" width="4" height="4"><rect fill="&c;" width="4" height="4"/></svg>';

async function refusal(html: string): Promise<string> {
	try {
		await htmlRender({ title: "Page", html });
	} catch (error) {
		if (error instanceof Error) return error.message;
		throw error;
	}
	throw new Error(`htmlRender accepted ${html.slice(0, 200)}`);
}

describe("html_render", () => {
	test("the result tells the model the page is shown; details carry the trimmed title and no html", async () => {
		expect(await htmlRender({ title: "  Sales by month \n", html: "<p>hi</p>" })).toStrictEqual({
			content: [
				{
					type: "text",
					text:
						"Shown to the reader where you called this, above your reply. " +
						"Don't mention or describe the page; reply with only what it doesn't already say.",
				},
			],
			details: { title: "Sales by month" },
		});
	});

	test("a blank title is refused", async () => {
		await expect(htmlRender({ title: " \n ", html: "<p>hi</p>" })).rejects.toThrow("The title is blank");
	});

	test("the description names every theme variable the frame defines", () => {
		const variables = [
			"--background",
			"--foreground",
			"--muted",
			"--muted-foreground",
			"--card",
			"--card-foreground",
			"--border",
			"--accent",
			"--accent-foreground",
			"--error",
			"--warning",
			"--success",
			"--chart-1",
			"--chart-2",
			"--chart-3",
			"--chart-4",
			"--chart-5",
			"--chart-6",
			"--radius",
			"--font-sans",
			"--font-mono",
		];
		const named = new Set(HTML_RENDER_DESCRIPTION.match(/--[a-z0-9-]+/g));
		expect([...named].sort()).toEqual(variables.sort());
	});
});

describe("viewport height units", () => {
	test("found in <style> bodies and style attributes, every kind and case", () => {
		expect(viewportHeightUnits("<style>.a{height:100vh}</style>")).toEqual(["100vh"]);
		expect(viewportHeightUnits('<style media="screen">b { max-height: 10lvh }</style>')).toEqual(["10lvh"]);
		expect(viewportHeightUnits('<div class="x" style="min-height: 50dvh">')).toEqual(["50dvh"]);
		expect(viewportHeightUnits("<p style='height:.5svh;top:1VH'>")).toEqual([".5svh", "1VH"]);
		expect(viewportHeightUnits('<div title="a > b" style="height:calc(100vh - 2px)">')).toEqual(["100vh"]);
		expect(viewportHeightUnits('<iframe style="height:30vh"></iframe>')).toEqual(["30vh"]);
		expect(viewportHeightUnits("<style>a{height:1vh}")).toEqual(["1vh"]);
	});

	test("not in scripts, text, comments or other attributes; vw and base64 runs pass", () => {
		const pages = [
			'<script>el.style.height = "100vh"; document.write("<style>a{height:100vh}</style>")</script>',
			"<p>Use 100vh for a full-height panel.</p>",
			'<!-- <div style="height:100vh"> -->',
			"<style>/* height: 100vh */ a { width: 100vw; height: 40px }</style>",
			'<textarea><div style="height:100vh"></div></textarea>',
			'<div data-style="height:100vh" title="style=height:100vh">',
			'<div style="background:url(data:image/png;base64,AAAA+100vh/9vh)">',
		];
		for (const page of pages) expect(viewportHeightUnits(page)).toEqual([]);
	});

	test("htmlRender refuses the page, naming the units and why", async () => {
		const message = await refusal('<style>main{height:100vh}</style><div style="height:50dvh">');
		expect(message).toContain("(100vh, 50dvh)");
		expect(message).toContain("again and again");
		expect(message).toContain("fixed pixel heights");
	});
});

describe("local images", () => {
	let dir: string;

	beforeEach(async () => {
		dir = await mkdtemp(path.join(tmpdir(), "ompx-html-"));
	});

	afterEach(async () => {
		await rm(dir, { recursive: true, force: true });
	});

	async function file(name: string, content: string | Buffer): Promise<string> {
		const target = path.join(dir, name);
		await writeFile(target, content);
		return target;
	}

	test("an absolute path in a quoted attribute or url() is inlined by its bytes into details.html", async () => {
		const png = await file("chart one.png", PNG);
		const jpeg = await file("photo.JPEG", JPEG);
		const svg = await file("icon.svg", SVG);
		const html =
			`<img src="${png}" alt="chart"><img src='${jpeg}'><div style="background:url(${svg})"></div>` +
			`<style>b { background: url( "${png}" ) }</style>`;
		const result = await htmlRender({ title: "Images", html });
		const expected = html
			.replaceAll(png, `data:image/png;base64,${PNG.toString("base64")}`)
			.replaceAll(jpeg, `data:image/jpeg;base64,${JPEG.toString("base64")}`)
			.replaceAll(svg, `data:image/svg+xml;base64,${Buffer.from(SVG).toString("base64")}`);
		expect(result.details).toStrictEqual({ title: "Images", html: expected });
	});

	test("remote, relative and data URLs and paths that are not images stay; details has no html", async () => {
		const html =
			'<img src="https://example.com/a.png"><img src="//cdn.example.com/b.png"><img src="img/c.png">' +
			'<img src="data:image/png;base64,iVBORw0KGgo="><a href="/etc/hosts">hosts</a>' +
			"<style>a{background:url(https://example.com/d.png)}</style><p>/tmp/e.png is a file</p>";
		expect((await htmlRender({ title: "Remote", html })).details).toStrictEqual({ title: "Remote" });
	});

	test("a file whose bytes are not its extension's type is refused and stays out of the page", async () => {
		const secret = await file("key.png", "sk-not-a-picture");
		const photo = await file("photo.png", JPEG);
		const message = await refusal(`<img src="${secret}"><img src="${photo}">`);
		expect(message).toContain(`${secret} (not a PNG image)`);
		expect(message).toContain(`${photo} (not a PNG image)`);
		expect(message).not.toContain("sk-not-a-picture");
	});

	test("missing files and directories are named", async () => {
		const missing = path.join(dir, "missing.png");
		const folder = path.join(dir, "folder.svg");
		await mkdir(folder);
		const message = await refusal(`<img src="${missing}"><div style="background:url('${folder}')">`);
		expect(message).toStartWith(
			`These local images could not be inlined: ${missing} (no such file); ${folder} (not a file).`,
		);
	});

	test("an image over 5 MiB is refused with its size", async () => {
		const big = await file("big.png", Buffer.concat([PNG, Buffer.alloc(5 * 1024 * 1024 + 1 - PNG.length)]));
		const message = await refusal(`<img src="${big}">`);
		expect(message).toContain(`${big} (5.0 MiB, too large)`);
		expect(message).toContain("at most 5 MiB each");
	});

	test("a page over 10 MiB once its images are inlined is refused with its size", async () => {
		const large = await file("large.png", Buffer.concat([PNG, Buffer.alloc(4 * 1024 * 1024 - PNG.length)]));
		const message = await refusal(`<img src="${large}"><img src="${large}">`);
		expect(message).toBe(
			"With its images inlined the page is 10.7 MiB; the limit is 10 MiB. Use fewer or smaller images.",
		);
	});
});
