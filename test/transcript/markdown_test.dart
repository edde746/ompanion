import 'package:flutter_test/flutter_test.dart';
import 'package:gpt_markdown/gpt_markdown.dart';
import 'package:omp_app/screens/chat/transcript/markdown.dart';

List<MdNode> parse(String markdown) => Plusparse.parse(
  markdown,
  blockRegistry: MarkdownBlockRegistry([CommonMarkFence.backtick, CommonMarkFence.tilde]),
).children;

MdCustomBlock fence(MdNode node) => node as MdCustomBlock;

void main() {
  group('CommonMarkFence', () {
    test('a backtick fence with an info string', () {
      final nodes = parse('before\n\n```dart title="x"\nvoid main() {}\n```\n\nafter');
      expect(nodes, hasLength(3));
      expect(fence(nodes[1]).body, 'void main() {}');
      expect(fence(nodes[1]).data, 'dart title="x"');
      expect(fence(nodes[1]).closed, isTrue);
      expect(nodes[2], isA<MdParagraph>());
    });

    test('a tilde fence', () {
      final nodes = parse('~~~python\nprint(1)\n~~~');
      expect(fence(nodes.single).type, 'tilde-fence');
      expect(fence(nodes.single).body, 'print(1)');
    });

    test('a longer fence keeps shorter fences as content', () {
      final nodes = parse('````markdown\n```bash\nls\n```\n````\ntail');
      expect(fence(nodes.first).body, '```bash\nls\n```');
      expect(fence(nodes.first).closed, isTrue);
      expect(nodes.last, isA<MdParagraph>());
    });

    test('a tilde fence is not closed by backticks and the reverse', () {
      expect(fence(parse('~~~\n```\n~~~').single).body, '```');
      expect(fence(parse('```\n~~~\n```').single).body, '~~~');
    });

    test('a closing line with text after the fence does not close it', () {
      final block = fence(parse('```\na\n``` not a closer\nb\n```').single);
      expect(block.body, 'a\n``` not a closer\nb');
    });

    test('an unclosed fence runs to the end while it streams', () {
      final block = fence(parse('text\n\n```ts\nconst a = 1;\nconst b').last);
      expect(block.closed, isFalse);
      expect(block.body, 'const a = 1;\nconst b');
    });

    test("the opener's indentation is removed from the content", () {
      final block = fence(parse('   ```\n   indented\n  less\n     more\n   ```').single);
      expect(block.body, 'indented\nless\n  more');
    });

    test('a backtick info string containing a backtick is not a fence', () {
      expect(parse('```a`b\ntext').first, isNot(isA<MdCustomBlock>()));
    });

    test('a fence inside a list item', () {
      final list = parse('1. Run:\n   ```bash\n   npm install\n   ```\n2. Done').single as MdOrderedList;
      final code = list.items.first.children.whereType<MdCustomBlock>().single;
      expect(code.body, 'npm install');
      expect(list.items, hasLength(2));
    });

    test('the streaming segment splitter keeps a fence with blank lines in one segment', () {
      final registry = MarkdownBlockRegistry([CommonMarkFence.backtick, CommonMarkFence.tilde]);
      expect(splitStreamSegments('a\n\n````md\n```\nx\n\ny\n```\n````\n\nb', blockRegistry: registry), [
        'a',
        '````md\n```\nx\n\ny\n```\n````',
        'b',
      ]);
    });
  });

  group('rewriteDollarMath', () {
    test('inline and display math', () {
      expect(rewriteDollarMath(r'Euler: $e^{i\pi}+1=0$.'), r'Euler: \(e^{i\pi}+1=0\).');
      expect(rewriteDollarMath('\$\$\n\\int_0^1 x\\,dx\n\$\$'), '\\[\n\\int_0^1 x\\,dx\n\\]');
    });

    test('prices and lone dollars stay text', () {
      expect(rewriteDollarMath(r'It costs $5 and $10 today.'), r'It costs $5 and $10 today.');
      expect(rewriteDollarMath(r'Pay $ 5 or $ 6'), r'Pay $ 5 or $ 6');
    });

    test('code spans and fences are left alone', () {
      expect(rewriteDollarMath(r'Run `echo $HOME` then `echo $PATH`.'), r'Run `echo $HOME` then `echo $PATH`.');
      const fenced = 'Math \$x\$\n\n```bash\necho \$A \$B\n```\n\n~~~\n\$y\$\n~~~\nand \$z\$';
      expect(rewriteDollarMath(fenced), 'Math \\(x\\)\n\n```bash\necho \$A \$B\n```\n\n~~~\n\$y\$\n~~~\nand \\(z\\)');
    });

    test('an escaped dollar is not math', () {
      expect(rewriteDollarMath(r'\$x\$ and $y$'), r'\$x\$ and \(y\)');
    });

    test('inline math does not cross lines', () {
      expect(rewriteDollarMath('\$a\nb\$'), '\$a\nb\$');
    });
  });
}
