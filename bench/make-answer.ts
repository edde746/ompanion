// Writes bench/answer.md: the fixed markdown both apps stream in the bench (BENCH.md). ASCII only, so bytes and
// characters agree. Run: bun bench/make-answer.ts
const blocks: string[] = [];
for (let i = 0; blocks.join("\n\n").length < 120_000; i++) {
  switch (i % 6) {
    case 0:
      blocks.push(
        `## Section ${i}: reading the session file\n\n` +
          `The run directory for session ${i} holds \`in.jsonl\` and \`out.jsonl\`. Every device appends to the first ` +
          `and tails the second, so a dropped connection never loses a turn.`,
      );
      break;
    case 1:
      blocks.push(
        `Paragraph ${i} has **bold text**, *emphasis*, \`inline_code_${i}()\` and a [link to item ${i}](https://example.com/items/${i}). ` +
          `It goes on long enough to wrap across several lines on a phone, which is where layout cost shows: ` +
          `the renderer measures each word, breaks the lines and positions the inline spans. Number ${i * 7} keeps the ` +
          `lines distinct so nothing upstream mistakes the stream for a loop.`,
      );
      break;
    case 2:
      blocks.push(
        [1, 2, 3, 4, 5]
          .map((n) => `- Item ${i}.${n}: check \`step_${n}\` and record the result in **run ${i}**`)
          .join("\n"),
      );
      break;
    case 3:
      blocks.push(
        "```dart\n" +
          `/// Block ${i}.\n` +
          `Future<int> handle${i}(Stream<String> lines) async {\n` +
          "  var count = 0;\n" +
          "  await for (final line in lines) {\n" +
          "    if (line.isEmpty) continue;\n" +
          `    final parts = line.split(':');\n` +
          `    if (parts.length < 2) throw FormatException('bad line \$line');\n` +
          `    count += int.parse(parts[1]) * ${i};\n` +
          "  }\n" +
          "  return count;\n" +
          "}\n" +
          "```",
      );
      break;
    case 4:
      blocks.push(
        `| Run | Platform | Frames | Result |\n|---|---|---|---|\n` +
          [1, 2, 3, 4, 5, 6].map((n) => `| ${i}.${n} | \`os-${n}\` | ${i * 10 + n} | **pass** |`).join("\n"),
      );
      break;
    default:
      blocks.push(
        `Math in block ${i}: the inline term $a_{${i}} + b^2 = c_{${i}}$ sits in a sentence, and the display form follows.\n\n` +
          `$$\\sum_{k=1}^{${i}} k^2 = \\frac{${i}(${i}+1)(2 \\cdot ${i}+1)}{6}$$`,
      );
  }
}
const text = blocks.join("\n\n") + "\n";
await Bun.write(new URL("./answer.md", import.meta.url), text);
console.log(`answer.md: ${text.length} bytes, ${blocks.length} blocks`);
