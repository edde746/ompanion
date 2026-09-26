import 'package:flutter_test/flutter_test.dart';
import 'package:ompanion/screens/chat/transcript/transcript_rows.dart';
import 'package:omp_core/store.dart';

UserItem user(int timestamp, String text) => UserItem(timestamp: timestamp, content: [TextBlock(text)]);

AssistantItem assistant(
  int timestamp,
  List<ContentBlock> content, {
  bool streaming = false,
  StopReason stopReason = StopReason.stop,
  Usage? usage,
  String? errorMessage,
  Duration? duration,
  RetryRecovery? retryRecovery,
}) => AssistantItem(
  timestamp: timestamp,
  content: content,
  provider: 'fake',
  model: 'fake-1',
  stopReason: stopReason,
  streaming: streaming,
  usage: usage,
  errorMessage: errorMessage,
  duration: duration,
  retryRecovery: retryRecovery,
);

List<TranscriptRow> rowsOf(List<TranscriptItem> items) => (TranscriptRowModel()..update(items)).rows;

ToolResultItem result(
  String callId, {
  String name = 'bash',
  ToolState state = ToolState.done,
  bool isError = false,
  Object? details,
  int? timestamp,
}) => ToolResultItem(
  toolCallId: callId,
  toolName: name,
  state: state,
  isError: isError,
  details: details,
  timestamp: timestamp,
  content: const [TextBlock('ok')],
);

ToolCallBlock call(String id, {String name = 'bash', Map<String, Object?> arguments = const {'command': 'ls'}}) =>
    ToolCallBlock(id: id, name: name, arguments: arguments);

/// A model whose open turns are those whose first item's key is in [open].
TranscriptRowModel folding(Set<String> open) => TranscriptRowModel(isOpen: (head) => open.contains(head.key));

/// What each row shows, in one short word or two.
List<String> shown(List<TranscriptRow> rows) => [
  for (final row in rows)
    switch (row) {
      ItemRow(item: UserItem(:final text)) => 'user $text',
      ItemRow(item: ExecutionItem(:final command)) => 'run $command',
      ItemRow(item: CustomItem(:final customType)) => 'custom $customType',
      ItemRow(:final item) => item.runtimeType.toString(),
      AssistantTextRow(:final text) => 'text $text',
      ThinkingRow() => 'thinking',
      AssistantImageRow() => 'image',
      ToolRow(:final callId) => 'tool $callId',
      AssistantFooterRow(:final item, :final retryFailed) =>
        'footer ${item.stopReason.name}${retryFailed ? ' retry failed' : ''}',
      PendingRow() => 'pending',
      TurnSummaryRow(:final open) => open ? 'summary open' : 'summary',
    },
];

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

    test('in a retry saga only the attempt before the answer says its retry succeeded', () {
      AssistantItem failed(int timestamp, int attempt) => AssistantItem(
        timestamp: timestamp,
        content: const [],
        provider: 'fake',
        model: 'fake-1',
        stopReason: StopReason.error,
        errorMessage: '500',
        retryRecovery: RetryRecovery(recovered: true, attempt: attempt, note: 'error; retried'),
      );
      final rows = rowsOf([
        user(1, 'a'),
        failed(2, 1),
        failed(3, 2),
        failed(4, 3),
        assistant(5, const [TextBlock('answer')], usage: const Usage(input: 1)),
        user(6, 'b'),
        failed(7, 1),
        assistant(8, const [TextBlock('answer')], usage: const Usage(input: 1)),
      ]);
      expect(
        [
          for (final row in rows.whereType<AssistantFooterRow>())
            if (row.item.retryRecovery != null) (row.item.retryRecovery!.attempt, row.retryFailed),
        ],
        [(1, true), (2, true), (3, false), (1, false)],
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

  group('turns fold', () {
    final q1 = user(1000, 'a');
    final s1 = assistant(2000, [const TextBlock('Looking.'), call('c1')], stopReason: StopReason.toolUse);
    final r1 = result('c1');
    final a1 = assistant(3000, const [TextBlock('Done.')]);
    final q2 = user(4000, 'b');
    final s2 = assistant(5000, [call('c2')], stopReason: StopReason.toolUse);
    final r2 = result('c2');
    final a2 = assistant(6000, const [TextBlock('Also done.')]);

    test('a settled turn shows its user message, a summary, what always shows and its last message', () {
      final transcript = [
        user(1000, 'fix it'),
        FileMentionItem(timestamp: 1001, files: const [MentionedFile(path: 'a.dart')]),
        assistant(2000, [
          const ThinkingBlock('plan'),
          const TextBlock('Looking.'),
          call('c1'),
        ], stopReason: StopReason.toolUse),
        result('c1'),
        CustomItem(timestamp: 3000, customType: 'note', content: const [TextBlock('x')], display: true),
        ExecutionItem(kind: ExecutionKind.bash, timestamp: 3500, command: 'git status', output: ''),
        CompactionItem(summary: 'earlier work', tokensBefore: 100),
        assistant(4000, const [
          ThinkingBlock('check'),
          ImageBlock(data: 'AA==', mimeType: 'image/png'),
          TextBlock('Done.'),
        ], usage: const Usage(input: 1)),
      ];
      expect(shown((folding({})..update(transcript)).rows), [
        'user fix it',
        'FileMentionItem',
        'summary',
        'run git status',
        'CompactionItem',
        'text Done.',
        'footer stop',
      ]);
      expect(shown((folding({transcript.first.key})..update(transcript)).rows), [
        'user fix it',
        'FileMentionItem',
        'summary open',
        'thinking',
        'text Looking.',
        'tool c1',
        'custom note',
        'run git status',
        'CompactionItem',
        'thinking',
        'image',
        'text Done.',
        'footer stop',
      ]);
    });

    test('a turn aborted mid-tool shows no last message: its work folds and the interruption shows', () {
      final rows = (folding({})..update([
        q1,
        s1,
        result('c1', state: ToolState.interrupted),
        assistant(3000, const [], stopReason: StopReason.aborted),
      ])).rows;
      expect(shown(rows), ['user a', 'summary', 'footer aborted']);
    });

    test('an error and every attempt of a retry that gave up show; an attempt a retry recovered folds', () {
      AssistantItem failed(int timestamp, int attempt, {required bool recovered}) => assistant(
        timestamp,
        const [],
        stopReason: StopReason.error,
        errorMessage: '500',
        retryRecovery: RetryRecovery(recovered: recovered, attempt: attempt, note: ''),
      );
      final gaveUp = [q1, s1, r1, failed(3000, 1, recovered: false), failed(3500, 2, recovered: false)];
      expect(shown((folding({})..update(gaveUp)).rows), [
        'user a',
        'summary',
        'footer error retry failed',
        'footer error',
      ]);
      final recovered = [q1, s1, r1, failed(3000, 1, recovered: true), a1];
      expect(shown((folding({})..update(recovered)).rows), ['user a', 'summary', 'text Done.']);
      final failedAnswer = [q1, s1, r1, assistant(3000, const [], stopReason: StopReason.error, errorMessage: '400')];
      expect(shown((folding({})..update(failedAnswer)).rows), ['user a', 'summary', 'footer error']);
    });

    test('a turn with no work has no summary row', () {
      final transcript = [q1, assistant(2000, const [TextBlock('hi')], usage: const Usage(input: 1))];
      expect(shown((folding({})..update(transcript)).rows), ['user a', 'text hi', 'footer stop']);
    });

    test('the latest turn shows every row while the session works on it, and folds once it settles', () {
      final model = folding({})..update([q1, s1, r1, a1, q2, s2, r2, a2], live: true);
      expect(shown(model.rows), ['user a', 'summary', 'text Done.', 'user b', 'tool c2', 'text Also done.']);
      final settled = [for (final row in model.rows.take(3)) row.content];

      model.update([q1, s1, r1, a1, q2, s2, r2, assistant(6000, const [TextBlock('Also done, twice.')])], live: true);
      expect(shown(model.rows), ['user a', 'summary', 'text Done.', 'user b', 'tool c2', 'text Also done, twice.']);
      expect([for (final row in model.rows.take(3)) row.content], settled, reason: 'streaming leaves settled turns');

      model.update([q1, s1, r1, a1, q2, s2, r2, a2], live: false);
      expect(shown(model.rows), ['user a', 'summary', 'text Done.', 'user b', 'summary', 'text Also done.']);
    });

    test('opening a turn shows its rows in order under its summary; closing folds them again', () {
      final open = <String>{};
      final model = folding(open)..update([q1, s1, r1, a1, q2, s2, r2, a2]);
      final closed = shown(model.rows);
      expect(closed, ['user a', 'summary', 'text Done.', 'user b', 'summary', 'text Also done.']);
      final second = [for (final row in model.rows.skip(3)) row.content];

      open.add(q1.key);
      model.refold();
      expect(shown(model.rows), [
        'user a',
        'summary open',
        'text Looking.',
        'tool c1',
        'text Done.',
        'user b',
        'summary',
        'text Also done.',
      ]);
      expect([for (final row in model.rows.skip(5)) row.content], second);

      open.remove(q1.key);
      model.refold();
      expect(shown(model.rows), closed);
    });

    test('a summary counts the time from the user message to the last response, tool calls and changed files', () {
      final transcript = [
        user(10000, 'edit'),
        assistant(11000, [
          call('e1', name: 'edit', arguments: const {'input': '[a.dart#1A2B]'}),
          call('e2', name: 'edit', arguments: const {}),
          call('w1', name: 'write', arguments: const {'path': 'c.md', 'content': 'x'}),
          call('e3', name: 'edit', arguments: const {}),
          call('b1'),
        ], stopReason: StopReason.toolUse),
        result('e1', name: 'edit', details: const {'path': '/w/a.dart', 'diff': '+x'}, timestamp: 20000),
        result(
          'e2',
          name: 'edit',
          details: const {
            'perFileResults': [
              {'path': '/w/a.dart', 'diff': '+y'},
              {'path': '/w/b.dart', 'diff': '+z'},
              {'path': '/w/x.dart', 'errorText': 'no match'},
            ],
          },
        ),
        result('w1', name: 'write'),
        result('e3', name: 'edit', isError: true, details: const {'path': '/w/d.dart'}),
        result('b1'),
        assistant(70000, const [TextBlock('Done.')], duration: const Duration(seconds: 12)),
      ];
      final summary = (folding({})..update(transcript)).rows.whereType<TurnSummaryRow>().single;
      expect(summary.facts, (worked: const Duration(seconds: 72), toolCalls: 5, filesEdited: 3));

      final quick = (folding({})..update([q1, s1, r1, a1])).rows.whereType<TurnSummaryRow>().single;
      expect(quick.facts, (worked: const Duration(seconds: 2), toolCalls: 1, filesEdited: 0));
    });

    test('updating in place gives the rows, positions and item rows of a fresh model', () {
      final open = <String>{};
      final aborted = assistant(7000, const [], stopReason: StopReason.aborted);
      final steps = <(List<TranscriptItem>, bool)>[
        ([q1, assistant(2000, const [], streaming: true)], true),
        ([q1, s1], true),
        ([q1, s1, r1], true),
        ([q1, s1, r1, a1], true),
        ([q1, s1, r1, a1], false),
        ([q1, s1, r1, a1, q2], true),
        ([q1, s1, r1, a1, q2, assistant(5000, [call('c2')], streaming: true)], true),
        ([q1, s1, r1, a1, q2, s2, result('c2', state: ToolState.running)], true),
        ([q1, s1, r1, a1, q2, s2, result('c2', state: ToolState.interrupted), aborted], true),
        ([q1, s1, r1, a1, q2, s2, result('c2', state: ToolState.interrupted), aborted], false),
        ([result('c0'), q1, s1, r1, a1], false),
        ([q1], false),
      ];
      final model = folding(open);
      for (final (transcript, live) in steps) {
        model.update(transcript, live: live);
        final fresh = folding(open)..update(transcript, live: live);
        expect(shown(model.rows), shown(fresh.rows));
        expect([for (final row in model.rows) row.key], [for (final row in fresh.rows) row.key]);
        for (final row in fresh.rows) {
          expect(model.positionOf(row.key), fresh.positionOf(row.key));
        }
        for (var item = 0; item <= transcript.length; item++) {
          expect(model.rowOf(item), fresh.rowOf(item), reason: 'row of item $item');
        }
      }
    });
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
