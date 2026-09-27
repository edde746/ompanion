import 'package:flutter_test/flutter_test.dart';
import 'package:ompanion/i18n/strings.g.dart';
import 'package:ompanion/sessions/session_name.dart';
import 'package:omp_core/host.dart';
import 'package:omp_core/store.dart';

UserItem _user(String text, {bool synthetic = false, String? attribution}) =>
    UserItem(timestamp: text.length, content: [TextBlock(text)], synthetic: synthetic, attribution: attribution);

SessionSummary _file({String? title, String? firstMessage}) => SessionSummary(
  path: '/s.jsonl',
  size: 1,
  modified: DateTime.utc(2026),
  id: 's',
  title: title,
  firstMessage: firstMessage,
);

void main() {
  final t = AppLocale.en.translations;

  test('the omp title wins over the first message', () {
    expect(sessionName(t, title: 'Fix the login', firstMessage: 'hello'), 'Fix the login');
  });

  test('without a title the first message names the session, on one line', () {
    expect(
      sessionName(t, title: '  ', firstMessage: '  refactor the\n\n  parser\tplease '),
      'refactor the parser please',
    );
  });

  test('a title from the first message leaves out its file mentions and local:// references', () {
    expect(
      sessionName(
        t,
        firstMessage:
            'Please review these. @"/Users/x/.omp/agent/sessions/-p/2026/local/meeting notes.txt" '
            '@src/foo.ts\nand local://paste-1.md',
      ),
      'Please review these. and',
    );
  });

  test('a first message of mentions only is named after its first file', () {
    expect(sessionName(t, firstMessage: '@"/tmp/up/meeting notes.txt" @b.md'), 'meeting notes.txt');
    expect(sessionName(t, firstMessage: ' local://paste-2.md '), 'paste-2.md');
  });

  test('a quoted mention the listing cut short leaves no path fragment in the title', () {
    expect(
      sessionName(t, firstMessage: 'Please review these. @"/tmp/AttachmentDelivery-home/.omp/agent/sess'),
      'Please review these.',
    );
  });

  test('a tagged model names itself in a title from the first message; a tag the listing cut short drops', () {
    expect(
      sessionName(t, firstMessage: 'Have <model agent="m1" name="Fake Think"/> review this change'),
      'Have Fake Think review this change',
    );
    expect(sessionName(t, firstMessage: 'Have <model agent="m1" name="Fake Th'), 'Have');
  });

  test('a session with neither is a new session', () {
    expect(sessionName(t), 'New session');
    expect(sessionName(t, firstMessage: ' \n '), 'New session');
  });

  test('the first message typed by the user, not an injected one', () {
    final view = SessionView(
      transcript: [
        _user('auto-continue', synthetic: true),
        _user('handoff context', attribution: 'agent'),
        _user('add a dark theme', attribution: 'user'),
        _user('and a light one'),
      ],
    );
    expect(firstUserMessage(view), 'add a dark theme');
    expect(firstUserMessage(SessionView()), isNull);
  });

  test('an open session is named like its file in the sidebar, then by its transcript', () {
    final view = SessionView(transcript: [_user('a later page of the transcript')]);
    expect(liveSessionName(t, view, _file(firstMessage: 'the first prompt')), 'the first prompt');
    expect(liveSessionName(t, view, null), 'a later page of the transcript');
    expect(
      liveSessionName(t, SessionView(config: const SessionConfig(sessionName: 'Titled')), _file(firstMessage: 'x')),
      'Titled',
    );
  });
}
