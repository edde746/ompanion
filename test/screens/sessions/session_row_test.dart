import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ompanion/i18n/strings.g.dart';
import 'package:ompanion/screens/sessions/machine_sessions.dart';
import 'package:ompanion/widgets/activity_mark.dart';

const _title = 'Fix the build';

Future<void> _pump(WidgetTester tester, SessionStatus status, {required bool unread}) => tester.pumpWidget(
  TranslationProvider(
    child: MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 300,
          child: SessionRow(
            title: _title,
            status: status,
            unread: unread,
            modified: DateTime.now(),
            selected: false,
            onTap: () {},
          ),
        ),
      ),
    ),
  ),
);

void main() {
  final cases = <(String, SessionStatus, bool, Finder? mark, String? tooltip)>[
    ('idle', SessionStatus.none, false, null, null),
    ('unread', SessionStatus.none, true, null, t.sessions.unread),
    ('running', SessionStatus.working, false, find.byType(ActivityMark), t.sessions.working),
    ('needs input', SessionStatus.needsInput, false, find.byIcon(Icons.help), t.sessions.needsInput),
    ('failed', SessionStatus.failed, false, find.byIcon(Icons.error), t.sessions.failed),
    (
      'needs input and unread',
      SessionStatus.needsInput,
      true,
      find.byIcon(Icons.help),
      '${t.sessions.needsInput} · ${t.sessions.unread}',
    ),
    (
      'running and unread',
      SessionStatus.working,
      true,
      find.byType(ActivityMark),
      '${t.sessions.working} · ${t.sessions.unread}',
    ),
  ];

  for (final (name, status, unread, mark, tooltip) in cases) {
    testWidgets('$name: one mark before the title, the time after it', (tester) async {
      final semantics = tester.ensureSemantics();
      await _pump(tester, status, unread: unread);
      final title = tester.getRect(find.text(_title));
      final time = tester.getRect(find.text(t.time.now));

      if (tooltip == null) {
        expect(find.byType(Tooltip), findsNothing);
      } else {
        // The only mark: a status replaces the unread dot rather than sitting beside it.
        expect(find.byType(Tooltip), findsOneWidget);
        expect(find.byTooltip(tooltip), findsOneWidget);
        expect(tester.getRect(find.byType(Tooltip)).right, lessThanOrEqualTo(title.left));
      }
      if (mark != null) {
        expect(mark, findsOneWidget);
        expect(tester.getRect(mark).right, lessThanOrEqualTo(title.left));
      }
      expect(find.byType(Icon), mark != null && status != SessionStatus.working ? findsOneWidget : findsNothing);
      expect(time.left, greaterThanOrEqualTo(title.right));

      final weight = tester.widget<Text>(find.text(_title)).style?.fontWeight;
      expect(weight, unread ? FontWeight.w700 : FontWeight.w400);
      final words = [
        _title,
        ?switch (status) {
          SessionStatus.working => t.sessions.working,
          SessionStatus.needsInput => t.sessions.needsInput,
          SessionStatus.failed => t.sessions.failed,
          _ => null,
        },
        if (unread) t.sessions.unread,
        t.time.now,
      ];
      expect(find.bySemanticsLabel(words.join(', ')), findsOneWidget);
      semantics.dispose();
    });
  }
}
