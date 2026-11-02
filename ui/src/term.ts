// xterm.js, in its own chunk: the smoke checks load it on demand.
import { Terminal } from "@xterm/xterm";
import "@xterm/xterm/css/xterm.css";
import { deferred } from "./deferred";

/** A terminal themed from the page's custom properties. */
export function createTerminal(options: ConstructorParameters<typeof Terminal>[0] = {}): Terminal {
  const style = getComputedStyle(document.documentElement);
  const color = (name: string) => style.getPropertyValue(name).trim();
  return new Terminal({
    fontFamily: color("--font-mono"),
    fontSize: 13,
    scrollback: 5000,
    theme: { background: color("--term-bg"), foreground: color("--term-fg"), cursor: color("--term-fg") },
    ...options,
  });
}

/** Resolves once xterm has parsed everything written so far. */
export function written(term: Terminal): Promise<void> {
  const { promise, resolve } = deferred<void>();
  term.write("", resolve);
  return promise;
}

/** The terminal's buffer, one string per row, trailing blanks trimmed. */
export function bufferLines(term: Terminal): string[] {
  const buffer = term.buffer.active;
  const lines: string[] = [];
  for (let i = 0; i < buffer.length; i++) lines.push(buffer.getLine(i)?.translateToString(true) ?? "");
  return lines;
}
