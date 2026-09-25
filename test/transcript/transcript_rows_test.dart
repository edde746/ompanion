import 'package:flutter_test/flutter_test.dart';
import 'package:omp_app/screens/chat/transcript/transcript_rows.dart';
import 'package:omp_core/store.dart';

UserItem user(int timestamp, String text) => UserItem(timestamp: timestamp, content: [TextBlock(text)]);

AssistantItem assistant(
  int timestamp,
  List<ContentBlock> content, {
  bool streaming = false,
  StopReason stopReason = StopReason.stop,
  Usage? usage,
  String? errorMessage,
}) => AssistantItem(
  timestamp: timestamp,
  content: content,
  provider: 'fake',
  model: 'fake-1',
  stopReason: stopReason,
  streaming: streaming,
  usage: usage,
  errorMessage: errorMessage,
);

List<TranscriptRow> rowsOf(List<TranscriptItem> items) => (TranscriptRowModel()..update(items)).rows;

ToolResultItem result(String callId, {String name = 'bash'}) =>
    ToolResultItem(toolCallId: callId, toolName: name, state: ToolState.done, content: const [TextBlock('ok')]);

void main() {
  group('transcriptRows', () {
    test('a tool result joins the row of its call', () {
      final call = const ToolCallBlock(id: 'c1', name: 'bash', arguments: {'command': 'ls'});
      final rows = rowsOf([
        user(1, 'list'),
        assistant(2, [const TextBlock('Listing.'), call], stopReason: StopReason.toolUse),
        result('c1'),
      ]);
      expect(rows.map((row) => row.runtimeType), [ItemRow, AssistantTextRow, ToolRow]);
      expect((rows.last as ToolRow).call, same(call));
    });

    test('a result whose call is not loaded is a row of its own', () {
      final rows = rowsOf([result('c9', name: 'read')]);
      final row = rows.single as ToolRow;
      expect((row.call, row.callId, row.toolName), (null, 'c9', 'read'));
    });

    test('hidden custom messages and empty blocks have no rows', () {
      final rows = rowsOf([
        CustomItem(timestamp: 1, customType: 'goal-continuation', content: const [TextBlock('x')], display: false),
        assistant(2, [const TextBlock('  '), const ThinkingBlock(''), const TextBlock('answer')]),
      ]);
      expect(rows.map((row) => row.runtimeType), [AssistantTextRow]);
    });

    test('a response that has shown nothing yet is a pending row; the last thinking block is live', () {
      expect(rowsOf([assistant(1, const [], streaming: true)]).single, isA<PendingRow>());
      final rows = rowsOf([
        assistant(1, const [ThinkingBlock('plan'), TextBlock('a'), ThinkingBlock('')], streaming: true),
      ]);
      expect([for (final row in rows.whereType<ThinkingRow>()) row.live], [false, true]);
    });

    test('footers: failures, interruptions and final answers, not tool-use steps or silent aborts', () {
      bool footer(AssistantItem item) => rowsOf([item]).last is AssistantFooterRow;
      expect(footer(assistant(1, const [TextBlock('a')], usage: const Usage(input: 1))), isTrue);
      expect(footer(assistant(1, const [TextBlock('a')], stopReason: StopReason.toolUse)), isFalse);
      expect(footer(assistant(1, const [TextBlock('a')], stopReason: StopReason.error)), isTrue);
      expect(footer(assistant(1, const [], stopReason: StopReason.aborted)), isTrue);
      expect(
        footer(assistant(1, const [TextBlock('a')], stopReason: StopReason.aborted, errorMessage: '__omp.silent_abort__')),
        isFalse,
      );
    });

    test('the split row is the first row of the split item', () {
      final transcript = [
        user(1, 'a'),
        assistant(2, const [TextBlock('b'), TextBlock('c')]),
        user(3, 'd'),
      ];
      final model = TranscriptRowModel()..update(transcript);
      expect([model.rowOf(2), model.rowOf(3)], [3, 4]);
    });

    test('rows of an unchanged item are the same instances, so their widgets are reused', () {
      final first = user(1, 'a');
      final done = assistant(2, const [TextBlock('b')]);
      final before = rowsOf([first, done, assistant(3, const [TextBlock('c')], streaming: true)]);
      final after = rowsOf([first, done, assistant(3, const [TextBlock('cd')], streaming: true)]);
      expect(after[0], same(before[0]));
      expect(after[1], same(before[1]));
      expect(after.last, isNot(same(before.last)));
    });
  });

  test('updating in place gives the rows, positions and results of a fresh model', () {
    final call = const ToolCallBlock(id: 'c1', name: 'bash', arguments: {'command': 'ls'});
    final steps = <List<TranscriptItem>>[];
    final first = user(1, 'a');
    final asking = assistant(2, [call], stopReason: StopReason.toolUse);
    steps
      ..add([first, assistant(2, const [], streaming: true)])
      ..add([first, asking])
      ..add([first, asking, result('c1')])
      ..add([result('c0'), first, asking, result('c1'), assistant(3, const [TextBlock('done')])])
      ..add([first]);
    final model = TranscriptRowModel();
    for (final step in steps) {
      model.update(step);
      final fresh = TranscriptRowModel()..update(step);
      expect([for (final row in model.rows) row.key], [for (final row in fresh.rows) row.key]);
      for (final row in fresh.rows) {
        expect(model.positionOf(row.key), fresh.positionOf(row.key));
      }
      expect(model.resultOf('c1'), fresh.resultOf('c1'));
      expect(model.resultOf('c0'), fresh.resultOf('c0'));
    }
  });

  test('a long text block is split into parts at segment boundaries; earlier parts keep their text as it grows', () {
    final paragraphs = [for (var i = 0; i < 40; i++) 'Paragraph $i ${'word ' * 12}'];
    List<AssistantTextRow> parts(int count) => rowsOf([
      assistant(1, [TextBlock(paragraphs.take(count).join('\n\n'))], streaming: true),
    ]).cast<AssistantTextRow>();
    final before = parts(30);
    final after = parts(40);
    expect(before.length, greaterThan(1));
    expect(before.map((row) => row.text).join('\n\n'), paragraphs.take(30).join('\n\n'));
    expect(after.first.key, before.first.key);
    expect(after.first.text, before.first.text);
    expect(before.every((row) => row.text.length <= partChars), isTrue);
  });

  group('toolKindFor', () {
    test('omp tool names pick their cards', () {
      expect(
        {
          for (final name in ['bash', 'read', 'edit', 'apply_patch', 'write', 'todo', 'task', 'ask', 'web_search', 'eval'])
            name: toolKindFor(name),
        },
        {
          'bash': ToolKind.bash,
          'read': ToolKind.read,
          'edit': ToolKind.edit,
          'apply_patch': ToolKind.edit,
          'write': ToolKind.write,
          'todo': ToolKind.todo,
          'task': ToolKind.task,
          'ask': ToolKind.ask,
          'web_search': ToolKind.webSearch,
          'eval': ToolKind.eval,
        },
      );
    });

    test('a read of a URL is a fetch card', () {
      expect(toolKindFor('read', args: {'path': 'https://dart.dev/'}), ToolKind.fetch);
      expect(toolKindFor('read', args: {'path': 'x'}, details: {'kind': 'url'}), ToolKind.fetch);
      expect(toolKindFor('read', args: {'path': 'lib/main.dart:1-20'}), ToolKind.read);
    });

    test('a write to an xd:// device and unknown tools are generic', () {
      expect(toolKindFor('write', args: {'path': 'xd://lsp', 'content': '{}'}), ToolKind.generic);
      expect(toolKindFor('grep'), ToolKind.generic);
      expect(toolKindFor('mcp__github_search'), ToolKind.generic);
    });
  });
}
