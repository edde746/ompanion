// Syntax highlighting for the transcript (lib/screens/chat/transcript/highlighter.dart) on Shiki's TextMate grammars.
// Shiki, its regex engine and each grammar load with dynamic import() on the first highlight that needs them, so a
// transcript without code costs nothing and the first paint never waits for them.
import type {
  GrammarState,
  HighlighterCore,
  LanguageRegistration,
  ThemedToken,
  ThemeRegistration,
} from "@shikijs/core";
import { deferred } from "../../../../deferred";

/**
 * Scope runs of highlighted code: run `i` covers `[ends[i - 1], ends[i])` of the code (from 0 for the first run) and
 * carries its syntax token (`keyword`, `string`, …), or undefined for plain text.
 */
export interface HighlightRuns {
  readonly ends: Int32Array;
  readonly scopes: readonly (string | undefined)[];
}

type Grammar = () => Promise<{ default: LanguageRegistration[] }>;

/**
 * C++'s grammar without GLSL, which it embeds for shader strings: the GLSL grammar has no licence, so the build leaves
 * it out (vite.config.ts, `withoutGrammars`) and those strings stay plain.
 */
async function cppWithoutGlsl(): Promise<{ default: LanguageRegistration[] }> {
  const { default: langs } = await import("@shikijs/langs/cpp");
  return {
    default: langs
      .filter((lang) => lang.name !== "glsl")
      .map((lang) => ({ ...lang, embeddedLangs: lang.embeddedLangs?.filter((name) => name !== "glsl") })),
  };
}

/**
 * The grammars a coding agent's transcript meets, by Shiki language id, each its own chunk. Curated rather than Shiki's
 * full set: all of its grammars are 8.6 MB, these with what they embed about 3 MB; a fence in another language stays
 * plain. None that is GPL-family or has no licence: not nginx (GPL-3.0), not GLSL (docs/research/licenses.md). A Map,
 * not a record: fence infos are arbitrary text, and `constructor` must not find a prototype member.
 */
const grammars = new Map<string, Grammar>([
  ["bat", () => import("@shikijs/langs/bat")],
  ["c", () => import("@shikijs/langs/c")],
  ["cmake", () => import("@shikijs/langs/cmake")],
  ["cpp", cppWithoutGlsl],
  ["csharp", () => import("@shikijs/langs/csharp")],
  ["css", () => import("@shikijs/langs/css")],
  ["dart", () => import("@shikijs/langs/dart")],
  ["diff", () => import("@shikijs/langs/diff")],
  ["docker", () => import("@shikijs/langs/docker")],
  ["elixir", () => import("@shikijs/langs/elixir")],
  ["fish", () => import("@shikijs/langs/fish")],
  ["go", () => import("@shikijs/langs/go")],
  ["graphql", () => import("@shikijs/langs/graphql")],
  ["groovy", () => import("@shikijs/langs/groovy")],
  ["haskell", () => import("@shikijs/langs/haskell")],
  ["hcl", () => import("@shikijs/langs/hcl")],
  ["html", () => import("@shikijs/langs/html")],
  ["ini", () => import("@shikijs/langs/ini")],
  ["java", () => import("@shikijs/langs/java")],
  ["javascript", () => import("@shikijs/langs/javascript")],
  ["json", () => import("@shikijs/langs/json")],
  ["json5", () => import("@shikijs/langs/json5")],
  ["jsonc", () => import("@shikijs/langs/jsonc")],
  ["jsonl", () => import("@shikijs/langs/jsonl")],
  ["jsx", () => import("@shikijs/langs/jsx")],
  ["kotlin", () => import("@shikijs/langs/kotlin")],
  ["lua", () => import("@shikijs/langs/lua")],
  ["make", () => import("@shikijs/langs/make")],
  ["markdown", () => import("@shikijs/langs/markdown")],
  ["nix", () => import("@shikijs/langs/nix")],
  ["objective-c", () => import("@shikijs/langs/objective-c")],
  ["perl", () => import("@shikijs/langs/perl")],
  ["php", () => import("@shikijs/langs/php")],
  ["powershell", () => import("@shikijs/langs/powershell")],
  ["proto", () => import("@shikijs/langs/proto")],
  ["python", () => import("@shikijs/langs/python")],
  ["r", () => import("@shikijs/langs/r")],
  ["ruby", () => import("@shikijs/langs/ruby")],
  ["rust", () => import("@shikijs/langs/rust")],
  ["scala", () => import("@shikijs/langs/scala")],
  ["scss", () => import("@shikijs/langs/scss")],
  ["shellscript", () => import("@shikijs/langs/shellscript")],
  ["shellsession", () => import("@shikijs/langs/shellsession")],
  ["sql", () => import("@shikijs/langs/sql")],
  ["svelte", () => import("@shikijs/langs/svelte")],
  ["swift", () => import("@shikijs/langs/swift")],
  ["terraform", () => import("@shikijs/langs/terraform")],
  ["toml", () => import("@shikijs/langs/toml")],
  ["tsx", () => import("@shikijs/langs/tsx")],
  ["typescript", () => import("@shikijs/langs/typescript")],
  ["vue", () => import("@shikijs/langs/vue")],
  ["xml", () => import("@shikijs/langs/xml")],
  ["yaml", () => import("@shikijs/langs/yaml")],
  ["zig", () => import("@shikijs/langs/zig")],
]);

/** Fence infos and file extensions that name a grammar under another name. */
const aliases = new Map<string, string>([
  ["batch", "bat"],
  ["cmd", "bat"],
  ["h", "c"],
  ["c++", "cpp"],
  ["cc", "cpp"],
  ["cxx", "cpp"],
  ["hh", "cpp"],
  ["hpp", "cpp"],
  ["hxx", "cpp"],
  ["c#", "csharp"],
  ["cs", "csharp"],
  ["patch", "diff"],
  ["containerfile", "docker"],
  ["dockerfile", "docker"],
  ["ex", "elixir"],
  ["exs", "elixir"],
  ["golang", "go"],
  ["gql", "graphql"],
  ["gradle", "groovy"],
  ["hs", "haskell"],
  ["htm", "html"],
  ["xhtml", "html"],
  ["properties", "ini"],
  ["cjs", "javascript"],
  ["js", "javascript"],
  ["mjs", "javascript"],
  ["ndjson", "jsonl"],
  ["kt", "kotlin"],
  ["kts", "kotlin"],
  ["gnumakefile", "make"],
  ["mak", "make"],
  ["makefile", "make"],
  ["mk", "make"],
  ["md", "markdown"],
  ["m", "objective-c"],
  ["objc", "objective-c"],
  ["pl", "perl"],
  ["pm", "perl"],
  ["ps", "powershell"],
  ["ps1", "powershell"],
  ["psm1", "powershell"],
  ["pwsh", "powershell"],
  ["protobuf", "proto"],
  ["py", "python"],
  ["pyi", "python"],
  ["python3", "python"],
  ["rake", "ruby"],
  ["rb", "ruby"],
  ["rs", "rust"],
  ["bash", "shellscript"],
  ["sh", "shellscript"],
  ["shell", "shellscript"],
  ["zsh", "shellscript"],
  ["console", "shellsession"],
  ["sh-session", "shellsession"],
  ["tf", "terraform"],
  ["tfvars", "terraform"],
  ["cts", "typescript"],
  ["mts", "typescript"],
  ["ts", "typescript"],
  ["plist", "xml"],
  ["svg", "xml"],
  ["xsd", "xml"],
  ["xsl", "xml"],
  ["yml", "yaml"],
]);

/** Files known by their whole name. */
const fileNames = new Map<string, string>([
  ["containerfile", "docker"],
  ["dockerfile", "docker"],
  ["gnumakefile", "make"],
  ["makefile", "make"],
]);

/**
 * The Shiki language for a fence info string (`dart`, `ts`, `sh`, …); undefined for plain text (`text`, `txt`, no
 * info) and for a language without a grammar here. Synchronous and light: it doubles as the "is it known" check.
 */
export function languageForFence(info: string | undefined): string | undefined {
  const name = info?.trim().toLowerCase() ?? "";
  return grammars.has(name) ? name : aliases.get(name);
}

/** The Shiki language for a file path, from its well-known name or its extension; undefined when unknown. */
export function languageForPath(path: string): string | undefined {
  const name = (path.split(/[/\\]/).pop() ?? "").toLowerCase();
  const known = fileNames.get(name);
  if (known !== undefined) return known;
  const dot = name.lastIndexOf(".");
  if (dot <= 0 || dot === name.length - 1) return undefined;
  return languageForFence(name.slice(dot + 1));
}

type SyntaxToken =
  | "comment"
  | "keyword"
  | "tag"
  | "literal"
  | "string"
  | "number"
  | "title"
  | "built-in"
  | "emphasis"
  | "strong";

/**
 * TextMate scopes by the syntax token that colours them: Atom One's groups, as Dart's `_syntaxScopes` gives
 * highlight.js scopes (comment+quote; keyword+doctag; tag: section, name, selector-tag, deletion, subst; literal;
 * string: string, regexp, addition, attribute; number: attr, variable, type, selectors, number; title: symbol, bullet,
 * link, meta, selector-id, title; built-in: built_in, class titles). TextMate grammars scope far more than
 * highlight.js (every identifier, every operator), so the groups name the scopes that carry those meanings, and
 * `plain` returns operators and the like to the text colour. The innermost scope a rule matches wins, a longer
 * selector over a shorter one; an unmatched scope takes its parent's colour.
 */
const syntaxScopes: Record<SyntaxToken | "plain", readonly string[]> = {
  comment: ["comment", "markup.quote", "meta.diff.header", "meta.diff.index"],
  keyword: [
    "keyword",
    "storage",
    "keyword.operator.expression",
    "keyword.operator.logical.python",
    "keyword.operator.new",
    "keyword.operator.sizeof",
    "keyword.operator.word",
  ],
  tag: [
    "entity.name.tag",
    "entity.name.section",
    "markup.heading",
    "markup.deleted",
    "meta.template.expression",
    "punctuation.definition.template-expression",
    "support.type.property-name.array.toml",
    "support.type.property-name.table.toml",
  ],
  literal: ["constant.language"],
  string: ["string", "markup.inserted", "support.type.property-name.css", "support.type.property-name.scss"],
  number: [
    "constant.numeric",
    "constant.other.color",
    "entity.other.attribute-name",
    "entity.name.tag.yaml",
    "keyword.other.definition.ini",
    "keyword.other.unit",
    "meta.object-literal.key",
    "storage.type.boolean.go",
    "storage.type.built-in",
    "storage.type.byte.go",
    "storage.type.error.go",
    "storage.type.numeric.go",
    "storage.type.primitive",
    "storage.type.rune.go",
    "storage.type.string.go",
    "support.type.property-name",
    "variable.language",
    "variable.other.bracket.shell",
    "variable.other.normal.shell",
    "variable.other.php",
    "variable.other.positional.shell",
    "variable.other.special.shell",
  ],
  title: [
    "constant.other.symbol",
    "entity.name.function",
    "entity.other.attribute-name.id",
    "keyword.control.directive",
    "markup.underline.link",
    "meta.attribute.rust",
    "meta.decorator",
    "meta.diff.range",
    "meta.function.decorator",
    "meta.preprocessor",
    "punctuation.definition.list.begin.markdown",
    "storage.type.annotation",
  ],
  "built-in": [
    "entity.name.class",
    "entity.name.type",
    "entity.other.inherited-class",
    "support.class",
    "support.function",
    "support.type",
  ],
  emphasis: ["markup.italic"],
  strong: ["markup.bold"],
  plain: ["keyword.operator", "storage.type.function.arrow", "string.unquoted.plain.out.yaml"],
};

const syntaxTokens = new Set<string>(Object.keys(syntaxScopes).filter((token) => token !== "plain"));

/**
 * A theme whose colours are the syntax token names: Shiki swaps a colour that is not a hex value for a placeholder and
 * back, so each token comes out with its group's name for a colour and the theme's matching does the scope lookup.
 */
const syntaxTheme: ThemeRegistration = {
  name: "transcript",
  type: "dark",
  fg: "plain",
  bg: "plain",
  settings: Object.entries(syntaxScopes).map(([token, scopes]) => ({
    scope: [...scopes],
    settings: { foreground: token },
  })),
};

/**
 * Code longer than this stays plain. TypeScript, the costliest common grammar, tokenizes at about 0.85 ms per 1,000
 * characters on studio's Apple M-series (measured); a mid-range phone is several times slower, so 12,000 characters
 * keep one highlight within a 50 ms long task there.
 */
const maxHighlightChars = 12_000;
/** Longer lines stay plain: one 19,000-character line of minified JavaScript took 506 ms to tokenize (measured). */
const tokenizeMaxLineLength = 1_000;
/**
 * No time limit per line (Shiki's default is 500 ms): it counts the engine compiling a grammar's patterns on their first
 * use, so on a slower device the first line a grammar met stayed plain from where the limit hit, and was cached so. The
 * length limits above bound the work instead.
 */
const tokenizeTimeLimit = 0;

async function createCore(): Promise<HighlighterCore> {
  const [{ createHighlighterCore }, { createJavaScriptRegexEngine }] = await Promise.all([
    import("@shikijs/core"),
    import("@shikijs/engine-javascript"),
  ]);
  return createHighlighterCore({
    themes: [syntaxTheme],
    langs: [],
    // forgiving: a pattern the engine cannot compile is skipped instead of failing its grammar. ES2018 regexes, not
    // the `v` flag: JavaScriptCore compiled the TypeScript grammar's first highlight in 700 ms with `v` and 36 ms
    // without (measured), and Safari 16, the oldest engine, has no `v` flag anyway.
    engine: createJavaScriptRegexEngine({ forgiving: true, target: "ES2018" }),
  });
}

function runsOf(lines: readonly (readonly ThemedToken[])[]): HighlightRuns {
  const ends: number[] = [];
  const scopes: (string | undefined)[] = [];
  for (const line of lines) {
    for (const token of line) {
      const end = token.offset + token.content.length;
      const scope = token.color !== undefined && syntaxTokens.has(token.color) ? token.color : undefined;
      // The line break before a token joins the token's run: it shows no colour.
      if (scopes.length > 0 && scopes[scopes.length - 1] === scope) {
        ends[ends.length - 1] = end;
      } else {
        ends.push(end);
        scopes.push(scope);
      }
    }
  }
  return { ends: Int32Array.from(ends), scopes };
}

/** Resolves in a later task, so input and rendering run between two highlights. */
function nextTask(): Promise<void> {
  const turn = deferred<void>();
  setTimeout(() => turn.resolve(), 0);
  return turn.promise;
}

function warn(message: string): void {
  // Loaded on this rare path only: app_logger reaches the bridge and `import.meta.env`, which this module's bun tests
  // stay clear of.
  void import("../../../utils/app_logger").then(({ appLogger }) => appLogger.w(message));
}

/** The grammar's state at the end of a chunk the file editor highlighted, to highlight the next chunk from. */
export type ChunkState = GrammarState;

const cacheKey = (language: string, code: string) => `${language}\u0000${code}`;

/**
 * Syntax highlighting for the transcript: Shiki on the main thread, one highlight per task so a page of code blocks
 * never holds the page, and results cached by language and code, so a code block that scrolls back into view or
 * renders again finds its colours at once.
 */
export class CodeHighlighter {
  static readonly instance = new CodeHighlighter();

  /** Cached results, least recently used first; an undefined value means the language is unknown. */
  private readonly cache = new Map<string, HighlightRuns | undefined>();
  private cachedChars = 0;
  private static readonly maxCachedChars = 4 << 20;
  private static readonly maxCachedEntries = 512;

  private readonly inFlight = new Map<string, Promise<HighlightRuns | undefined>>();
  private readonly queue: (() => Promise<void>)[] = [];
  private draining = false;
  private core: Promise<HighlighterCore> | undefined;

  private constructor() {}

  /** The cached result for `code` in `language`; undefined when absent or unknown (`isCached` tells them apart). */
  cached(language: string, code: string): HighlightRuns | undefined {
    const key = cacheKey(language, code);
    if (!this.cache.has(key)) return undefined;
    // Most recently used last; an undefined (unknown language) entry moves too, so its size stays counted.
    const runs = this.cache.get(key);
    this.cache.delete(key);
    this.cache.set(key, runs);
    return runs;
  }

  isCached(language: string, code: string): boolean {
    return this.cache.has(cacheKey(language, code));
  }

  /**
   * Highlights `code` in `language` (a `languageForFence`/`languageForPath` id); completes with undefined when the
   * language is unknown or the code too long to highlight without holding the page.
   */
  highlight(language: string, code: string): Promise<HighlightRuns | undefined> {
    if (code.length > maxHighlightChars) return Promise.resolve(undefined);
    const key = cacheKey(language, code);
    if (this.cache.has(key)) return Promise.resolve(this.cached(language, code));
    let request = this.inFlight.get(key);
    if (request === undefined) {
      request = this.enqueue(language, (core) =>
        runsOf(
          core.codeToTokensBase(code, {
            lang: language,
            theme: syntaxTheme.name,
            tokenizeMaxLineLength,
            tokenizeTimeLimit,
          }),
        ),
      ).then((runs) => {
        this.inFlight.delete(key);
        this.store(key, runs);
        return runs;
      });
      this.inFlight.set(key, request);
    }
    return request;
  }

  /**
   * Highlights one chunk of a longer text (the file editor's), going on from `after`, the state the chunk before it
   * ended in. Neither cached nor capped: the caller picks the chunks. Undefined when the language is unknown or its
   * grammar fails.
   */
  highlightChunk(
    language: string,
    code: string,
    after?: ChunkState,
  ): Promise<{ runs: HighlightRuns; state: ChunkState } | undefined> {
    return this.enqueue(language, (core) => {
      const lines = core.codeToTokensBase(code, {
        lang: language,
        theme: syntaxTheme.name,
        tokenizeMaxLineLength,
        tokenizeTimeLimit,
        grammarState: after,
      });
      const state = core.getLastGrammarState(lines);
      return state === undefined ? undefined : { runs: runsOf(lines), state };
    });
  }

  /**
   * Queues `tokenize` behind the highlights before it; it runs in a task of its own once the core and the language's
   * grammar are loaded. Undefined for a language without a grammar; a failure is logged and gives undefined too.
   */
  private enqueue<T>(language: string, tokenize: (core: HighlighterCore) => T | undefined): Promise<T | undefined> {
    const grammar = grammars.get(language);
    if (grammar === undefined) return Promise.resolve(undefined);
    const result = deferred<T | undefined>();
    this.queue.push(async () => {
      try {
        const core = await (this.core ??= createCore());
        if (!core.getLoadedLanguages().includes(language)) await core.loadLanguage(grammar());
        result.resolve(tokenize(core));
      } catch (error) {
        // A grammar that fails to load or throws on some input leaves its text plain.
        warn(`Syntax highlighting failed: ${language}: ${String(error)}`);
        result.resolve(undefined);
      }
    });
    if (!this.draining) void this.drain();
    return result.promise;
  }

  private async drain(): Promise<void> {
    this.draining = true;
    for (let job = this.queue.shift(); job !== undefined; job = this.queue.shift()) {
      await nextTask();
      await job();
    }
    this.draining = false;
  }

  private store(key: string, runs: HighlightRuns | undefined): void {
    this.cache.set(key, runs);
    this.cachedChars += key.length;
    while (this.cache.size > CodeHighlighter.maxCachedEntries || this.cachedChars > CodeHighlighter.maxCachedChars) {
      const oldest = this.cache.keys().next().value;
      if (oldest === undefined) break;
      this.cache.delete(oldest);
      this.cachedChars -= oldest.length;
    }
  }
}

/** `code` as spans coloured by `runs`: each run's text with the `code_style.css` class of its syntax token. */
export function highlightedSpans(code: string, runs: HighlightRuns): { text: string; class?: string }[] {
  const spans: { text: string; class?: string }[] = [];
  let start = 0;
  for (let i = 0; i < runs.ends.length; i++) {
    const end = runs.ends[i] ?? start;
    if (end > code.length) break;
    const scope = runs.scopes[i];
    const text = code.slice(start, end);
    spans.push(scope === undefined ? { text } : { text, class: `code-style-${scope}` });
    start = end;
  }
  if (start < code.length) spans.push({ text: code.slice(start) });
  return spans;
}
