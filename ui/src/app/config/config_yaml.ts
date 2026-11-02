// Port of lib/config/config_yaml.dart. The `yaml` package's Document keeps comments, key order and scalar styles
// through an edit, as yaml_edit does; it reprints the document's layout in its own style (two-space indents).
import { type Document, isAlias, isMap, isScalar, type Node, parseDocument, Scalar, visit, type YAMLError } from "yaml";
import { FormatException, isJsonObject, type JsonObject } from "../../core/rpc/json_fields";

/**
 * One omp settings file (`config.yml`) as nested plain values. Setting paths address it by their dotted segments:
 * `startup.checkUpdate` is `startup: {checkUpdate: …}`.
 */
export interface ConfigLayer {
  readonly root: JsonObject;
}

/**
 * Parses a settings file. An empty file, or one holding only comments, is an empty layer. Throws a [FormatException]
 * with the position only: the file may hold credentials, so no source text is quoted.
 */
export function configLayerParse(text: string): ConfigLayer {
  const document = parse(text);
  const plain: unknown = document.toJS();
  if (plain === null || plain === undefined) return { root: {} };
  if (!isJsonObject(plain)) throw new FormatException("the settings file does not hold a map");
  return { root: plain };
}

/**
 * The value at [path], or undefined when the file does not hold it. A key present with an empty value is a hit whose
 * value is undefined.
 */
export function configLayerLookup(layer: ConfigLayer, path: readonly string[]): { value: unknown } | undefined {
  let node: unknown = layer.root;
  for (const segment of path) {
    if (!isJsonObject(node) || !Object.hasOwn(node, segment)) return undefined;
    node = node[segment];
  }
  return { value: node ?? undefined };
}

/**
 * [source] with [path] set to [value], comments and layout kept. Missing parent maps are created; a parent holding a
 * scalar is a [FormatException].
 */
export function setConfigValue(source: string, path: readonly string[], value: unknown): string {
  if (path.length === 0) throw new RangeError("setConfigValue: empty path");
  if (!writable(value)) throw new FormatException(`could not write ${path.join(".")} into the settings file`);
  const document = parse(source);
  const root = document.contents;
  if (!isMap(root)) {
    if (root !== null && !(isScalar(root) && root.value === null)) {
      throw new FormatException("the settings file does not hold a map");
    }
    const created = createNode(document, nest(path, value));
    // A document of only `~` keeps the comments around it.
    if (root !== null) {
      created.commentBefore = root.commentBefore;
      created.comment = root.comment;
    }
    document.contents = created;
    return render(document, source);
  }
  let node = root;
  let depth = 0;
  for (; depth < path.length - 1; depth++) {
    const child: unknown = node.get(path[depth], true);
    if (isAlias(child)) throw throughAlias(path);
    if (isMap(child)) {
      node = child;
      continue;
    }
    if (child !== undefined && !(isScalar(child) && child.value === null)) {
      throw new FormatException(`${path.slice(0, depth + 1).join(".")} holds a value, not a map`);
    }
    break;
  }
  const key = path[depth];
  const rest = path.slice(depth + 1);
  const existing: unknown = node.get(key, true);
  if (isAlias(existing)) throw throughAlias(path);
  if (rest.length === 0 && isScalar(existing) && (typeof value !== "object" || value === null)) {
    // In place, so a comment after the value on its line stays.
    existing.value = value ?? null;
    existing.type = quoted(value) ? Scalar.QUOTE_DOUBLE : undefined;
  } else {
    node.set(key, createNode(document, nest(rest, value)));
  }
  return render(document, source);
}

/**
 * [source] without [path]; parent maps left empty by the removal are removed too. Unchanged when the file does not
 * hold [path].
 */
export function removeConfigValue(source: string, path: readonly string[]): string {
  if (path.length === 0) throw new RangeError("removeConfigValue: empty path");
  const document = parse(source);
  let node: unknown = document.contents;
  for (const segment of path) {
    if (isAlias(node)) throw throughAlias(path);
    if (!isMap(node)) return source;
    node = node.get(segment, true);
    if (node === undefined) return source;
  }
  document.deleteIn(path);
  for (let depth = path.length - 1; depth > 0; depth--) {
    const parent: unknown = document.getIn(path.slice(0, depth), true);
    if (!isMap(parent) || parent.items.length > 0) break;
    document.deleteIn(path.slice(0, depth));
  }
  return render(document, source);
}

/** The document in [source]; its errors become [FormatException]s that name a position, never the file's text. */
function parse(source: string): Document {
  const document = parseDocument(source);
  const error = document.errors[0];
  if (error !== undefined) throw invalid(error);
  return document;
}

// The package's messages quote the lines around the error, which may hold credentials; its code says what is wrong.
function invalid(error: YAMLError): FormatException {
  const start = error.linePos?.[0];
  const where = start === undefined ? "" : ` at line ${start.line}, column ${start.col}`;
  return new FormatException(`not valid YAML${where}: ${error.code.toLowerCase().replaceAll("_", " ")}`);
}

function throughAlias(path: readonly string[]): FormatException {
  return new FormatException(`${path.join(".")} is reached through a YAML alias (& or *), which the app does not edit`);
}

function render(document: Document, source: string): string {
  const text = document.toString({ lineWidth: 0, flowCollectionPadding: false });
  return source.includes("\r\n") ? text.replaceAll("\n", "\r\n") : text;
}

function nest(rest: readonly string[], value: unknown): unknown {
  let nested = value ?? null;
  for (const segment of [...rest].reverse()) nested = { [segment]: nested };
  return nested;
}

function createNode(document: Document, value: unknown): Node {
  const node = document.createNode(value);
  visit(node, {
    Scalar(_, scalar) {
      if (quoted(scalar.value)) scalar.type = Scalar.QUOTE_DOUBLE;
    },
  });
  return node;
}

/**
 * YAML 1.1 readers take these plain words as booleans or null; omp's parser does not, but quoting keeps the file
 * unambiguous for every reader (omp's own docs quote `"off"`).
 */
const ambiguousWord = /^(?:y|Y|yes|Yes|YES|n|N|no|No|NO|on|On|ON|off|Off|OFF|~)$/;

function quoted(value: unknown): boolean {
  return typeof value === "string" && ambiguousWord.test(value);
}

/** JSON values only: YAML could hold NaN and the infinities, but omp's settings are JSON-shaped. */
function writable(value: unknown): boolean {
  if (typeof value === "number") return Number.isFinite(value);
  if (Array.isArray(value)) return value.every(writable);
  if (isJsonObject(value)) return Object.values(value).every(writable);
  return true;
}
