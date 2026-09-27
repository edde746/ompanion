import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// Time between two steps of every [ActivityMark].
const activityStep = Duration(milliseconds: 500);

/// The app's one mark for work that is under way: three dots in a [size] square, one lit and two dimmed, the lit one
/// stepping to the next every [activityStep]. Every mark on screen steps together from one clock, in one frame, and a
/// step only repaints the mark's own layer. It is still, all three dots lit, when the device asks for less motion or
/// the mark sits in a subtree whose tickers are off (a route below another, a hidden tab).
///
/// A spinning indicator draws a new frame every vsync for as long as it shows; a run that works for minutes with a
/// tool card, a sidebar row and the header all busy kept the app at 60 or 120 frames a second.
class ActivityMark extends StatelessWidget {
  const ActivityMark({super.key, this.size = 14, this.color});

  /// The square the mark takes: the icon size of the slot it stands in.
  final double size;

  /// Defaults to [ColorScheme.onSurfaceVariant].
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final stepping = !MediaQuery.disableAnimationsOf(context) && TickerMode.valuesOf(context).enabled;
    return RepaintBoundary(
      child: CustomPaint(
        size: Size.square(size),
        painter: _Dots(color: color ?? Theme.of(context).colorScheme.onSurfaceVariant, clock: stepping ? _clock : null),
      ),
    );
  }
}

final _clock = _ActivityClock();

/// Counts [activityStep]s while any mark listens; no timer runs while none does.
final class _ActivityClock extends ChangeNotifier implements ValueListenable<int> {
  Timer? _timer;
  int _listeners = 0;
  int _value = 0;

  @override
  int get value => _value;

  @override
  void addListener(VoidCallback listener) {
    super.addListener(listener);
    if (_listeners++ == 0) {
      _timer = Timer.periodic(activityStep, (_) {
        _value++;
        notifyListeners();
      });
    }
  }

  @override
  void removeListener(VoidCallback listener) {
    super.removeListener(listener);
    if (--_listeners == 0) {
      _timer?.cancel();
      _timer = null;
    }
  }
}

class _Dots extends CustomPainter {
  _Dots({required this.color, required this.clock}) : super(repaint: clock);

  final Color color;

  /// Null while the mark stands still.
  final ValueListenable<int>? clock;

  @override
  void paint(Canvas canvas, Size size) {
    final lit = switch (clock) {
      final clock? => clock.value % 3,
      null => null,
    };
    final radius = size.shortestSide * 0.11;
    final gap = (size.width - 6 * radius) / 2;
    final paint = Paint();
    for (var index = 0; index < 3; index++) {
      paint.color = lit == null || lit == index ? color : color.withValues(alpha: color.a * 0.35);
      canvas.drawCircle(Offset(radius + index * (2 * radius + gap), size.height / 2), radius, paint);
    }
  }

  @override
  bool shouldRepaint(_Dots oldDelegate) => oldDelegate.color != color || oldDelegate.clock != clock;
}
