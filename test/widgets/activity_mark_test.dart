import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ompanion/widgets/activity_mark.dart';

/// Frames the app asks for over [seconds] of fake time, looked at every 16 ms without drawing in between.
Future<int> _framesAskedFor(WidgetTester tester, {int seconds = 5}) async {
  var frames = 0;
  for (var elapsed = 0; elapsed < seconds * 1000; elapsed += 16) {
    await tester.binding.delayed(const Duration(milliseconds: 16));
    if (tester.binding.hasScheduledFrame) {
      frames++;
      await tester.pump();
    }
  }
  return frames;
}

Widget _marks({bool disableAnimations = false, bool tickers = true}) => MaterialApp(
  home: MediaQuery(
    data: MediaQueryData(disableAnimations: disableAnimations),
    child: TickerMode(
      enabled: tickers,
      child: const Row(children: [ActivityMark(), ActivityMark(size: 20), ActivityMark(size: 12)]),
    ),
  ),
);

void main() {
  testWidgets('marks on screen step together, two frames a second and none in between', (tester) async {
    await tester.pumpWidget(_marks());
    await tester.pump();
    // One step every 500 ms: 10 in 5 s, one frame each however many marks show.
    expect(await _framesAskedFor(tester), 10);
  });

  testWidgets('a device that asks for less motion gets still marks and no frames', (tester) async {
    await tester.pumpWidget(_marks(disableAnimations: true));
    await tester.pump();
    expect(await _framesAskedFor(tester), 0);
  });

  testWidgets('marks under disabled tickers (a covered route, a hidden tab) stand still', (tester) async {
    await tester.pumpWidget(_marks(tickers: false));
    await tester.pump();
    expect(await _framesAskedFor(tester), 0);
  });
}
