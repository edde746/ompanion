import 'package:flutter_test/flutter_test.dart';
import 'package:ompanion/screens/chat/composer_intent.dart';
import 'package:omp_core/rpc.dart';
import 'package:omp_core/store.dart';

const _commands = [
  SlashCommand(name: 'compact', source: 'builtin'),
  SlashCommand(name: 'force', aliases: ['force:'], source: 'builtin'),
  SlashCommand(name: 'pause', source: 'extension'),
  SlashCommand(name: 'skill:review', aliases: ['review'], source: 'skill'),
];

ComposerIntent _intent(String text, {bool running = false, bool followUp = false, bool images = false}) =>
    composerIntent(text, hasImages: images, running: running, followUp: followUp, commands: _commands);

void main() {
  group('prompts', () {
    test('an idle session gets a plain prompt, trimmed', () {
      final intent = _intent('  fix the bug \n');
      expect(intent, isA<SendPrompt>());
      intent as SendPrompt;
      expect(intent.text, 'fix the bug');
      expect(intent.behavior, isNull);
    });

    test('while a run streams Enter steers and the modifier queues a follow-up', () {
      expect((_intent('stop that', running: true) as SendPrompt).behavior, StreamingBehavior.steer);
      expect((_intent('then this', running: true, followUp: true) as SendPrompt).behavior, StreamingBehavior.followUp);
    });

    test('the follow-up modifier does nothing while idle', () {
      expect((_intent('hi', followUp: true) as SendPrompt).behavior, isNull);
    });

    test('images alone are a prompt; nothing at all is not', () {
      expect(_intent('', images: true), isA<SendPrompt>());
      expect(_intent('   '), isA<NothingToSend>());
    });
  });

  group('slash commands', () {
    test('a listed command is sent as prompt text, arguments included', () {
      final intent = _intent('/compact keep the API notes') as SendPrompt;
      expect(intent.text, '/compact keep the API notes');
      expect(intent.command, 'compact');
    });

    test('aliases count', () {
      expect((_intent('/review') as SendPrompt).command, 'skill:review');
    });

    test('a command while running steers like text', () {
      expect((_intent('/pause', running: true) as SendPrompt).behavior, StreamingBehavior.steer);
    });

    test('an unlisted command is never sent', () {
      final intent = _intent('/plan make it faster');
      expect(intent, isA<UnknownCommand>());
      expect((intent as UnknownCommand).name, 'plan');
    });

    test('a path is a prompt, not a command', () {
      expect(_intent('/usr/bin/env is missing'), isA<SendPrompt>());
      expect((_intent('/tmp/x.log') as SendPrompt).command, isNull);
    });

    // omp ends extension, custom and file command names at the first space only; `pause⏎now` would be no command
    // and go to the model.
    test('arguments after a new line or tab are sent after a space', () {
      expect((_intent('/pause\nfor a minute') as SendPrompt).text, '/pause for a minute');
      expect((_intent('/pause\tnow\nand later') as SendPrompt).text, '/pause now\nand later');
      expect((_intent('/pause  twice') as SendPrompt).text, '/pause  twice');
    });

    test('a builtin takes its arguments after a colon too', () {
      final intent = _intent('/force:bash list the files') as SendPrompt;
      expect(intent.text, '/force:bash list the files');
      expect(intent.command, 'force');
      expect((_intent('/force:') as SendPrompt).command, 'force');
    });

    test('only builtins split at a colon', () {
      expect(_intent('/pause:now'), isA<UnknownCommand>());
    });

    test('a bare slash sends nothing', () {
      expect(_intent('/'), isA<NothingToSend>());
    });
  });

  group('shell and Python', () {
    test('! runs bash in context, !! outside it', () {
      final bash = _intent('!ls -la') as RunBash;
      expect(bash.command, 'ls -la');
      expect(bash.excludeFromContext, isFalse);
      final quiet = _intent('!! git status') as RunBash;
      expect(quiet.command, 'git status');
      expect(quiet.excludeFromContext, isTrue);
    });

    test(r'$ runs Python in context, $$ outside it', () {
      final python = _intent(r'$print(1)') as RunPython;
      expect(python.code, 'print(1)');
      expect(python.excludeFromContext, isFalse);
      expect((_intent(r'$$ x = 2') as RunPython).excludeFromContext, isTrue);
    });

    test('exec wins over streaming: it never becomes a steer', () {
      expect(_intent('!make', running: true), isA<RunBash>());
    });

    test('a bare prefix sends nothing', () {
      expect(_intent('!'), isA<NothingToSend>());
      expect(_intent('!!  '), isA<NothingToSend>());
      expect(_intent(r'$$'), isA<NothingToSend>());
    });
  });
}
