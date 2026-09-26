import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ompanion/screens/dock/tree/session_tree.dart';

/// A `get_tree` node; [children] nest.
Map<String, Object?> node(
  Map<String, Object?> entry, [
  List<Map<String, Object?>> children = const [],
  String? label,
]) => {'entry': entry, 'children': children, 'label': ?label};

Map<String, Object?> user(String id, String text, {String? parent}) => {
  'type': 'message',
  'id': id,
  'parentId': parent,
  'timestamp': '2026-09-25T10:00:00.000Z',
  'message': {
    'role': 'user',
    'content': [
      {'type': 'text', 'text': text},
    ],
  },
};

Map<String, Object?> assistant(String id, List<Map<String, Object?>> content, {String stopReason = 'stop'}) => {
  'type': 'message',
  'id': id,
  'message': {'role': 'assistant', 'content': content, 'stopReason': stopReason},
};

Map<String, Object?> text(String value) => {'type': 'text', 'text': value};

Map<String, Object?> entry(String id, String type, [Map<String, Object?> fields = const {}]) => {
  'type': type,
  'id': id,
  ...fields,
};

List<String> ids(List<TreeRow> rows) => [for (final row in rows) row.entry.id];

void main() {
  group('decode', () {
    test('a recorded get_tree hides bookkeeping and marks the visible ancestor of a session_exit leaf', () {
      final line = File('testing/fixtures/session-resume.out.jsonl').readAsLinesSync()[10];
      final data = (jsonDecode(line) as Map<String, Object?>)['data']! as Map<String, Object?>;
      final tree = SessionTree.decode([
        for (final node in data['tree']! as List<Object?>) node! as Map<String, Object?>,
      ], data['leafId'] as String?);

      final rows = tree.rows();
      expect(
        [for (final row in rows) (row.entry.kind, row.entry.text)],
        [
          (TreeEntryKind.user, 'Remember the word fixture.'),
          (TreeEntryKind.assistant, 'Noted: the word is fixture.'),
          (TreeEntryKind.user, 'What was the word?'),
          (TreeEntryKind.assistant, 'The word was fixture.'),
        ],
      );
      expect([for (final row in rows) row.depth], everyElement(0));
      expect(rows.where((row) => row.isLeaf).single.entry.text, 'The word was fixture.');
      expect(rows.every((row) => row.onActivePath), isTrue);

      final all = tree.rows(filter: TreeFilter.all);
      expect([for (final row in all) row.entry.type].first, 'model_change');
      expect(all.last.entry.type, 'custom');
      expect(all.last.isLeaf, isTrue);
    });

    test('a linear session thousands of entries deep decodes without recursion', () {
      Map<String, Object?> chain = node(user('e0', 'first'));
      for (var i = 1; i < 20000; i++) {
        chain = node(user('e$i', 'message $i'), [chain]);
      }
      final tree = SessionTree.decode([chain], 'e0');
      final rows = tree.rows();
      expect(rows, hasLength(20000));
      expect(rows.first.entry.id, 'e19999');
      expect(rows.last.isLeaf, isTrue);
      expect(rows.map((row) => row.depth).toSet(), {0});
    });

    test('a malformed node is a FormatException', () {
      expect(
        () => SessionTree.decode([
          {'children': []},
        ], null),
        throwsFormatException,
      );
      expect(
        () => SessionTree.decode([
          {'entry': user('a', 'x'), 'children': 'nope'},
        ], null),
        throwsFormatException,
      );
    });

    test('tool results read as the call that produced them', () {
      final tree = SessionTree.decode([
        node(user('u', 'look'), [
          node(
            assistant('a', [
              {
                'type': 'toolCall',
                'id': 'call-1',
                'name': 'read',
                'arguments': {'path': 'src/main.dart', 'offset': 10, 'limit': 5},
              },
              {
                'type': 'toolCall',
                'id': 'call-2',
                'name': 'bash',
                'arguments': {'command': 'ls\n-la'},
              },
            ], stopReason: 'toolUse'),
            [
              node(
                entry('r1', 'message', {
                  'message': {'role': 'toolResult', 'toolCallId': 'call-1', 'toolName': 'read'},
                }),
                [
                  node(
                    entry('r2', 'message', {
                      'message': {'role': 'toolResult', 'toolCallId': 'call-2', 'toolName': 'bash'},
                    }),
                    [
                      node(
                        entry('r3', 'message', {
                          'message': {'role': 'toolResult', 'toolCallId': 'gone', 'toolName': 'grep'},
                        }),
                      ),
                    ],
                  ),
                ],
              ),
            ],
          ),
        ]),
      ], 'r3');

      final rows = tree.rows();
      // The assistant turn that only called tools is not a row of its own.
      expect(ids(rows), ['u', 'r1', 'r2', 'r3']);
      expect([for (final row in rows.skip(1)) row.entry.text], ['read src/main.dart:10-14', 'bash ls -la', 'grep']);
      expect(tree.rows(filter: TreeFilter.noTools).map((row) => row.entry.id), ['u']);
    });

    test('an assistant turn that only called tools shows when it is the leaf, errors and aborts always do', () {
      final tree = SessionTree.decode([
        node(user('u', 'go'), [
          node(assistant('aborted', [], stopReason: 'aborted'), [
            node(
              {
                ...assistant('failed', [], stopReason: 'error'),
                'message': {'role': 'assistant', 'content': [], 'stopReason': 'error', 'errorMessage': 'rate limited'},
              },
              [
                node(
                  assistant('tools', [
                    {'type': 'toolCall', 'id': 'c', 'name': 'ls', 'arguments': {}},
                  ], stopReason: 'toolUse'),
                ),
              ],
            ),
          ]),
        ]),
      ], 'tools');

      final rows = tree.rows();
      expect(ids(rows), ['u', 'aborted', 'failed', 'tools']);
      expect(rows[1].entry.aborted, isTrue);
      expect((rows[2].entry.error, rows[2].entry.text), (true, 'rate limited'));
      expect(rows.last.isLeaf, isTrue);
    });
  });

  group('branches', () {
    // root → a1 → { b (older branch) → b1, c (holds the leaf) → c1 → leaf }
    SessionTree branched({String? leaf = 'c2'}) => SessionTree.decode([
      node(user('root', 'start'), [
        node(assistant('a1', [text('answer')]), [
          node(user('b', 'first try'), [
            node(assistant('b1', [text('first answer')])),
          ], 'old'),
          node(user('c', 'second try'), [
            node(assistant('c1', [text('second answer')]), [node(user('c2', 'follow up'))]),
          ]),
        ]),
      ]),
    ], leaf);

    test('the branch holding the leaf comes first and stays expanded; others collapse with a count', () {
      final rows = branched().rows();
      expect(ids(rows), ['root', 'a1', 'c', 'c1', 'c2', 'b']);
      expect([for (final row in rows) row.depth], [0, 0, 1, 1, 1, 1]);
      expect([for (final row in rows) row.branchHead], [false, false, true, false, false, true]);
      expect(rows.firstWhere((row) => row.entry.id == 'b').collapsedCount, 1);
      expect(rows.firstWhere((row) => row.entry.id == 'c').collapsedCount, isNull);
      expect([for (final row in rows) row.onActivePath], [true, true, true, true, true, false]);
      expect(rows.firstWhere((row) => row.isLeaf).entry.id, 'c2');
      expect(rows.firstWhere((row) => row.entry.id == 'b').entry.label, 'old');
    });

    test('toggling a branch head flips its default', () {
      final tree = branched();
      final rows = tree.rows(toggled: {'b', 'c'});
      expect(ids(rows), ['root', 'a1', 'c', 'b', 'b1']);
      expect(rows.firstWhere((row) => row.entry.id == 'c').collapsedCount, 2);
    });

    test('a search expands every branch and keeps only matches, under their nearest visible ancestor', () {
      final rows = branched().rows(query: 'ANSWER');
      expect(ids(rows), ['a1', 'c1', 'b1']);
      expect([for (final row in rows) (row.depth, row.branchHead)], [(0, false), (1, true), (1, true)]);
      expect(branched().rows(query: 'second answer'), hasLength(1));
      expect(branched().rows(query: 'nothing like it'), isEmpty);
    });

    test('filters: your messages, and labeled entries', () {
      final tree = branched();
      expect(ids(tree.rows(filter: TreeFilter.userOnly)), ['root', 'c', 'c2', 'b']);
      expect(ids(tree.rows(filter: TreeFilter.labeledOnly)), ['b']);
    });

    test('without a leaf nothing is on the active path and every branch is collapsed', () {
      final rows = branched(leaf: null).rows();
      expect(ids(rows), ['root', 'a1', 'b', 'c']);
      expect(rows.where((row) => row.onActivePath || row.isLeaf), isEmpty);
      expect(branched(leaf: null).parentOf('c1'), 'c');
      expect(branched(leaf: null).parentOf('root'), isNull);
    });

    test('a first message replaced under a hidden root: both are branches, the current one first and open', () {
      final tree = SessionTree.decode([
        node(entry('model', 'model_change', {'provider': 'fake', 'modelId': 'one'}), [
          node(user('old', 'Show the renderer demo'), [
            node(assistant('old1', [text('long demo')])),
          ]),
          node(user('new', 'Show a shorter renderer demo'), [
            node(assistant('new1', [text('short demo')])),
          ]),
        ]),
      ], 'new1');
      final rows = tree.rows();
      expect(ids(rows), ['new', 'new1', 'old']);
      expect([for (final row in rows) (row.depth, row.branchHead)], [(1, true), (1, false), (1, true)]);
      expect(rows.last.collapsedCount, 1);
      expect(rows.last.lastSibling, isTrue);
    });
  });

  test('entries without text describe themselves', () {
    final tree = SessionTree.decode([
      node(entry('comp', 'compaction', {'summary': 'long summary', 'tokensBefore': 48123}), [
        node(entry('bs', 'branch_summary', {'summary': 'what was tried', 'fromId': 'x'}), [
          node(
            entry('adv', 'custom_message', {
              'customType': 'advisor',
              'content': 'ignored',
              'details': {
                'notes': [
                  {'note': 'watch the tests', 'advisor': 'critic', 'severity': 'concern'},
                  {'note': 'and the docs', 'advisor': 'default', 'severity': 'nit'},
                ],
              },
            }),
            [
              node(
                entry('bash', 'message', {
                  'message': {'role': 'bashExecution', 'command': 'git status'},
                }),
              ),
            ],
          ),
        ]),
      ]),
    ], 'bash');
    final rows = tree.rows();
    expect(
      [for (final row in rows) (row.entry.kind, row.entry.text)],
      [
        (TreeEntryKind.compaction, 'long summary'),
        (TreeEntryKind.branchSummary, 'what was tried'),
        (TreeEntryKind.advisor, 'watch the tests and the docs'),
        (TreeEntryKind.bash, 'git status'),
      ],
    );
    expect(rows.first.entry.tokensBefore, 48123);
    // Advisor names other than `default`, then severities, as omp's advisorTreeDisplay lists them.
    expect(rows[2].entry.advisorTags, 'critic, concern, nit');
    expect(tree.rows(query: 'critic').map((row) => row.entry.id), contains('adv'));
  });
}
