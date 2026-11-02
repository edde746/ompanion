/**
 * String.raw for host scripts ported from Dart's `r'''…'''` strings: backslashes stay as written, and in the literal
 * parts `` \` `` and `\${` stand for a backtick and `${`, which a template literal cannot hold otherwise. Keep the
 * literal parts ASCII: Bun's transpiler rewrites other characters there as `\uXXXX` escapes, which String.raw keeps.
 */
export function script(strings: TemplateStringsArray, ...values: unknown[]): string {
  let text = "";
  strings.raw.forEach((part, i) => {
    text += part.replace(/\\(`|\$\{)/g, "$1");
    if (i < values.length) text += String(values[i]);
  });
  return text;
}
