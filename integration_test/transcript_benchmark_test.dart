// Streaming benchmark of the chat transcript, a profile-mode target:
//
//   flutter drive --profile -d macos --driver=integration_test/driver/report_driver.dart \
//     --target=integration_test/transcript_benchmark_test.dart
//
// A 2,000-item session, its settled turns folded, is on screen while its run works on the last turn: a 12 KB markdown
// reply (prose, lists, code, tables) streams into that turn in 300 updates at 50 per second, then the run settles and
// the turn folds. Frame timings of the streaming phase are printed and written to build/integration_response_data.json.
import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:ompanion/app/palette.dart';
import 'package:ompanion/app/theme.dart';
import 'package:ompanion/i18n/strings.g.dart';
import 'package:ompanion/screens/chat/transcript/transcript_view.dart';
import 'package:omp_core/store.dart';
import 'package:window_manager/window_manager.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  // Frames come from the engine as in the app, not from the test's pumps.
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.benchmarkLive;

  testWidgets('a reply streams into a 2,000-item transcript at 50 updates per second', (tester) async {
    // The macOS runner keeps its window hidden until Dart shows it.
    await windowManager.ensureInitialized();
    await windowManager.setSize(const Size(1100, 900));
    await windowManager.show();

    final history = syntheticTranscript(2000);
    final view = ValueNotifier(
      SessionView(transcript: history, historyLength: history.length, run: const RunState(running: true)),
    );
    final actions = TranscriptActions(onCopy: (_) {}, onOpenFile: (path, {line}) {}, onOpenSubagent: (_) {});
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          theme: appTheme(AppPalette.light),
          home: Scaffold(
            body: ValueListenableBuilder<SessionView>(
              valueListenable: view,
              builder: (context, value, _) => TranscriptView(view: value, actions: actions),
            ),
          ),
        ),
      ),
    );
    await Future<void>.delayed(const Duration(seconds: 2));

    final reply = benchmarkReply();
    const updates = 300;
    final chunk = (reply.length / updates).ceil();
    final timings = <FrameTiming>[];
    void collect(List<FrameTiming> batch) => timings.addAll(batch);
    SchedulerBinding.instance.addTimingsCallback(collect);
    for (var sent = 1; sent <= updates; sent++) {
      final item = AssistantItem(
        timestamp: 9000000000000,
        content: [TextBlock(reply.substring(0, math.min(reply.length, sent * chunk)))],
        provider: 'fake',
        model: 'fake-1',
        stopReason: StopReason.stop,
        streaming: sent < updates,
      );
      view.value = SessionView(
        transcript: [...history, item],
        historyLength: history.length,
        run: RunState(running: sent < updates),
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    await Future<void>.delayed(const Duration(seconds: 1));
    SchedulerBinding.instance.removeTimingsCallback(collect);

    final build = [for (final timing in timings) timing.buildDuration.inMicroseconds / 1000];
    final raster = [for (final timing in timings) timing.rasterDuration.inMicroseconds / 1000];
    final report = <String, Object>{
      'frames': timings.length,
      'build_ms': percentiles(build),
      'raster_ms': percentiles(raster),
      'frames_over_16_7ms_build': build.where((ms) => ms > 1000 / 60).length,
    };
    binding.reportData = {'transcript_streaming': report};
    debugPrint('transcript_streaming: $report');
    expect(timings, isNotEmpty);
  });
}

Map<String, double> percentiles(List<double> values) {
  final sorted = [...values]..sort();
  double at(double quantile) => sorted[math.min(sorted.length - 1, (sorted.length * quantile).floor())];
  double round(double value) => (value * 100).round() / 100;
  return {
    'mean': round(sorted.reduce((a, b) => a + b) / sorted.length),
    'p50': round(at(0.5)),
    'p90': round(at(0.9)),
    'p99': round(at(0.99)),
    'max': round(sorted.last),
  };
}

/// Questions, tool steps and answers in rotation, [count] items long.
List<TranscriptItem> syntheticTranscript(int count) {
  final messages = <Map<String, Object?>>[];
  var time = 1758800000000;
  Map<String, Object?> assistant(List<Map<String, Object?>> content, String stop) => {
    'role': 'assistant',
    'content': content,
    'provider': 'fake',
    'model': 'fake-1',
    'stopReason': stop,
    'timestamp': time += 1000,
    if (stop == 'stop') 'usage': {'input': 1200, 'output': 80, 'totalTokens': 1280},
  };
  for (var turn = 1; messages.length < count; turn++) {
    messages
      ..add({'role': 'user', 'content': 'Question $turn: what does step $turn change?', 'timestamp': time += 1000})
      ..add(
        assistant([
          {'type': 'text', 'text': 'Checking step $turn.'},
          {
            'type': 'toolCall',
            'id': 's$turn',
            'name': 'bash',
            'arguments': {'command': 'git log -1 --stat step-$turn'},
          },
        ], 'toolUse'),
      )
      ..add({
        'role': 'toolResult',
        'toolCallId': 's$turn',
        'toolName': 'bash',
        'content': 'commit ${turn.toRadixString(16).padLeft(7, '0')}\n lib/a.dart | 4 ++--\n',
        'timestamp': time += 1000,
      })
      ..add(
        assistant([
          {
            'type': 'text',
            'text':
                'Step $turn changes **two lines** in `lib/a.dart`:\n\n```dart\nfinal step = $turn;\nprint(step);\n```\n\n'
                '- keeps the API\n- adds a test\n\n| file | lines |\n|---|---|\n| lib/a.dart | 4 |',
          },
        ], 'stop'),
      );
  }
  return withMessages(SessionView(), messages.take(count).toList()).transcript;
}

/// A long reply with headings, prose, lists, code and tables.
String benchmarkReply() {
  final buffer = StringBuffer('# Streaming benchmark\n\n');
  for (var section = 1; buffer.length < 12000; section++) {
    buffer
      ..write('## Section $section\n\n')
      ..write(
        'This paragraph explains part $section of the change in plain words, with `inline code`, '
        '**emphasis** and a [link](https://dart.dev). It is long enough to wrap across lines.\n\n',
      )
      ..write('- first point of $section\n- second point with `code`\n- third point\n\n')
      ..write(
        '```dart\nvoid section$section() {\n  final values = [for (var i = 0; i < $section; i++) i * i];\n'
        '  print(values.join(", "));\n}\n```\n\n',
      )
      ..write('| column | value |\n|---|---|\n| a | $section |\n| b | ${section * 2} |\n\n');
  }
  return buffer.toString();
}
