import { createHash } from "node:crypto";
import { readdirSync, readFileSync } from "node:fs";
import { isAbsolute, relative } from "node:path";
import { fileURLToPath } from "node:url";
import solid from "@solidjs/vite-plugin";
import { defineConfig, type Plugin } from "vite";

const fixtures = decodeURIComponent(new URL("../harness/fixtures", import.meta.url).pathname);

// KaTeX's stylesheet offers woff2, woff and ttf for every font. Every target webview reads woff2; the other two
// would add ~600 KB of files nothing loads.
function katexWoff2Only(): Plugin {
  return {
    name: "katex-woff2-only",
    enforce: "pre",
    transform(code, id) {
      if (!/katex(\.min)?\.css$/.test(id)) return null;
      return code.replace(/,\s*url\([^)]*\.(woff|ttf)\)\s*format\("(woff|truetype)"\)/g, "");
    },
  };
}

// index.html's CSP. Only the dev server talks to the dev bridge's WebSocket; the shells' pages connect nowhere.
function contentSecurityPolicy(): Plugin {
  let serve = false;
  return {
    name: "content-security-policy",
    configResolved(config) {
      serve = config.command === "serve";
    },
    transformIndexHtml(html) {
      return html.replace("%CONNECT_SRC%", serve ? "'self' ws://127.0.0.1:* ws://localhost:*" : "'self'");
    },
  };
}

// What the first frame needs comes in index.html, not as files the parser waits for (docs/research/web-ui/startup.md):
// the script that paints the last launch's first frame (src/app/first_frame_restore.js), which the CSP allows by its
// hash, and in a build the entry's stylesheet, its url()s (relative to assets/) rewritten to the page's base. The
// stylesheet's <link> stays with `media="not all"`: it neither applies nor blocks, but Vite's loader finds it there
// and does not add it again when a lazy chunk that lists it loads.
function inlineFirstFrame(): Plugin {
  const script = readFileSync(new URL("src/app/first_frame_restore.js", import.meta.url), "utf8");
  const hash = createHash("sha256").update(script).digest("base64");
  return {
    name: "inline-first-frame",
    transformIndexHtml: {
      order: "post",
      handler(html, context) {
        const page = html.replace("%FIRST_FRAME_HASH%", `'sha256-${hash}'`).replace("%FIRST_FRAME_SCRIPT%", () => script);
        const bundle = context.bundle;
        if (bundle === undefined) return page;
        const entryCss = /<link rel="stylesheet" crossorigin href="\.\/(assets\/index-[\w-]+\.css)">/;
        return page.replace(entryCss, (link, file: string) => {
          const asset = bundle[file];
          if (asset?.type !== "asset") throw new Error(`inline-first-frame: ${file} is not in the bundle`);
          const css = String(asset.source).replaceAll("url(./", "url(./assets/");
          return `<style>${css}</style>\n    ${link.replace(">", ' media="not all">')}`;
        });
      },
    },
  };
}

// Shiki grammars the bundle leaves out (docs/research/licenses.md): nginx is GPL-3.0 and GLSL has no licence.
// highlighter.ts imports neither; C++'s grammar imports GLSL's for shader strings and gets an empty one instead.
const excludedGrammars = new Set(["glsl", "nginx"]);
const grammarModule = /node_modules\/@shikijs\/langs\/dist\/([^/]+)\.mjs$/;

function withoutGrammars(): Plugin {
  return {
    name: "without-grammars",
    enforce: "pre",
    load(id) {
      const grammar = grammarModule.exec(id)?.[1];
      return grammar !== undefined && excludedGrammars.has(grammar) ? "export default [];" : null;
    },
  };
}

const root = fileURLToPath(new URL(".", import.meta.url));

/** A licence as the page lists it; `text` is the licence text itself until the file is written. */
interface Listed {
  readonly name: string;
  readonly version: string;
  readonly license: string;
  readonly text: string;
}

/** licenses/index.json: corrections for packages, and third-party code and fonts that are no package of their own. */
interface LicenseManifest {
  readonly packages: Readonly<Record<string, { readonly license?: string; readonly text?: string }>>;
  readonly vendored: readonly (Listed & { readonly in: string })[];
}

// The licences page (src/app/screens/settings/licenses_page.tsx) lists what the app ships with its licence, from
// `licenses.json` beside index.html: `{texts, groups: [{id, packages: [{name, version, license, text}]}]}`, each
// distinct licence text once in `texts` and a package's `text` its index. `vite build` writes the group `page`: every
// npm package the bundle holds code or assets of (its package.json's licence and licence file), each Shiki grammar by
// its upstream's licence as tm-grammars, the record Shiki's grammars come from, has it, and what licenses/index.json
// adds (a licence a package lacks, third-party code and fonts that are no package). Each shell's build adds the core's
// and its native libraries' groups (core/cmd/licenses). The build fails on a package without a licence text and on
// GPL-family code. The dev server has no bundle to list.
function bundledLicenses(): Plugin {
  return {
    name: "bundled-licenses",
    apply: "build",
    generateBundle(_options, bundle) {
      // Every module and asset source, relative to ui/: fonts a stylesheet @imports are assets only.
      const sources = new Set<string>();
      const add = (file: string) => sources.add(isAbsolute(file) ? relative(root, file) : file);
      for (const id of this.getModuleIds()) if (!id.startsWith("\0")) add(id.split("?")[0] ?? id);
      for (const output of Object.values(bundle)) {
        if (output.type === "asset") for (const file of output.originalFileNames) add(file);
      }
      const manifest = JSON.parse(readFileSync(`${root}licenses/index.json`, "utf8")) as LicenseManifest;
      const overridden = (entry: Listed): Listed => {
        const fix = manifest.packages[entry.name];
        return {
          ...entry,
          license: fix?.license ?? entry.license,
          text: fix?.text === undefined ? entry.text : readFileSync(`${root}licenses/${fix.text}`, "utf8"),
        };
      };
      const listed: Listed[] = [];
      const packageRoots = new Set<string>();
      const grammars = new Set<string>();
      for (const source of sources) {
        const packageRoot = /^(.*node_modules\/(?:@[^/]+\/)?[^/.][^/]*)\//.exec(source)?.[1];
        if (packageRoot !== undefined) packageRoots.add(packageRoot);
        const grammar = grammarModule.exec(source)?.[1];
        if (grammar !== undefined && !excludedGrammars.has(grammar)) grammars.add(grammar);
      }
      for (const packageRoot of packageRoots) {
        const pkg: unknown = JSON.parse(readFileSync(`${root}${packageRoot}/package.json`, "utf8"));
        const file = readdirSync(`${root}${packageRoot}`).find((name) => /^(licen[cs]e|copying)\b/i.test(name));
        listed.push(
          overridden({
            name: manifestString(pkg, "name"),
            version: manifestString(pkg, "version"),
            license: manifestString(pkg, "license"),
            text: file === undefined ? "" : readFileSync(`${root}${packageRoot}/${file}`, "utf8"),
          }),
        );
      }
      if (grammars.size > 0) {
        const langs: unknown = JSON.parse(readFileSync(`${root}node_modules/@shikijs/langs/package.json`, "utf8"));
        const notices = grammarNotices(readFileSync(`${root}node_modules/tm-grammars/NOTICE`, "utf8"));
        for (const grammar of grammars) {
          const notice = notices.get(grammar);
          listed.push(
            overridden({
              name: `@shikijs/langs/${grammar}`,
              version: manifestString(langs, "version"),
              license: notice?.license ?? "",
              text: notice?.text ?? "",
            }),
          );
        }
      }
      for (const { in: path, ...entry } of manifest.vendored) {
        const ships = [...sources].some((source) => {
          // A path in a package from where the package's own node_modules/ begins, wherever the packages are.
          const inPackage = path.startsWith("node_modules/") ? source.slice(source.lastIndexOf("node_modules/")) : source;
          return path.endsWith("/") ? inPackage.startsWith(path) : inPackage === path;
        });
        if (ships) listed.push({ ...entry, text: readFileSync(`${root}licenses/${entry.text}`, "utf8") });
      }
      for (const entry of listed) {
        if (entry.text.trim() === "") this.error(`${entry.name} ${entry.version} has no licence text (licenses/index.json)`);
        if (/GPL/.test(entry.license) && !/\bOR\b/.test(entry.license)) {
          this.error(`${entry.name} ${entry.version} is ${entry.license}: GPL-family code must not ship`);
        }
        if (entry.license === "" || entry.license === "NOASSERTION") {
          this.error(`${entry.name} ${entry.version} has no licence id (licenses/index.json)`);
        }
      }
      listed.sort((a, b) => a.name.localeCompare(b.name) || a.version.localeCompare(b.version));
      const texts: string[] = [];
      const index = new Map<string, number>();
      const packages = listed.map(({ text, ...entry }) => {
        let at = index.get(text);
        if (at === undefined) {
          at = texts.push(text) - 1;
          index.set(text, at);
        }
        return { ...entry, text: at };
      });
      this.emitFile({
        type: "asset",
        fileName: "licenses.json",
        source: JSON.stringify({ texts, groups: [{ id: "page", packages }] }),
      });
    },
  };
}

/**
 * tm-grammars' NOTICE, by grammar: sections of `Files: a.json, b.json`, `License: <url>`, `SPDX: <id>`, a dashed
 * line and the licence text, between lines of `=`.
 */
function grammarNotices(notice: string): Map<string, { license: string; text: string }> {
  const byGrammar = new Map<string, { license: string; text: string }>();
  for (const section of notice.split(/^=+$/m)) {
    const files = /^Files:\s+(.+)$/m.exec(section)?.[1];
    const license = /^SPDX:\s+(.+)$/m.exec(section)?.[1]?.trim();
    const dashes = /^-{20,}$/m.exec(section);
    if (files === undefined || license === undefined || dashes === null) continue;
    const text = section.slice(dashes.index + dashes[0].length).trim();
    for (const file of files.split(",")) byGrammar.set(file.trim().replace(/\.json$/, ""), { license, text });
  }
  return byGrammar;
}

function manifestString(manifest: unknown, key: string): string {
  const value: unknown = typeof manifest === "object" && manifest !== null ? Reflect.get(manifest, key) : undefined;
  return typeof value === "string" ? value : "";
}

export default defineConfig({
  base: "./",
  // The oldest engine a shell runs: iOS 16's WebKit (Safari 16.0, macOS 13 the same or newer); Chromium of that time
  // for WebView2 and Android's WebView. No asset is inlined as a data: URL: the page's CSP loads fonts from 'self' only.
  build: {
    outDir: "dist",
    emptyOutDir: true,
    chunkSizeWarningLimit: 1024,
    assetsInlineLimit: 0,
    target: ["safari16", "chrome107", "edge107"],
    rolldownOptions: {
      output: {
        // Every module the first frame imports statically goes into one chunk: split up, they were ~130 files, each a
        // request through the shell's scheme handler (docs/research/web-ui/startup.md).
        codeSplitting: { groups: [{ name: "app", tags: ["$initial"] }] },
      },
    },
  },
  plugins: [
    withoutGrammars(),
    katexWoff2Only(),
    solid(),
    contentSecurityPolicy(),
    inlineFirstFrame(),
    bundledLicenses(),
  ],
  server: { fs: { allow: [".", "../bench", fixtures] } },
});
