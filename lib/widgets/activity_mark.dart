import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// Time between two steps of every [ActivityMark]: the step of omp's TUI activity spinner, so the app and the
/// terminal move alike.
const activityStep = Duration(milliseconds: 80);

/// The app's one mark for work that is under way: omp's TUI activity spinner (⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏) painted as a braille
/// cell, two columns of three dots in a [size] square, the frame's dots lit and the rest dimmed, stepping to the next
/// frame every [activityStep]. Every mark on screen steps together from one clock, in one frame, and a step only
/// repaints the mark's own layer. It stands still on the first frame when the device asks for less motion or the
/// mark sits in a subtree whose tickers are off (a route below another, a hidden tab).
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
        painter: _Braille(
          color: color ?? Theme.of(context).colorScheme.onSurfaceVariant,
          clock: stepping ? _clock : null,
        ),
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

/// The frames of omp's TUI activity spinner, ⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏, as their braille dot bits: bits 0 to 2 are the left column
/// from the top, bits 3 to 5 the right one.
const _frames = [0x0B, 0x19, 0x39, 0x38, 0x3C, 0x34, 0x26, 0x27, 0x07, 0x0F];

class _Braille extends CustomPainter {
  _Braille({required this.color, required this.clock}) : super(repaint: clock);

  final Color color;

  /// Null while the mark stands still.
  final ValueListenable<int>? clock;

  @override
  void paint(Canvas canvas, Size size) {
    final lit = _frames[(clock?.value ?? 0) % _frames.length];
    final radius = size.shortestSide * 0.1;
    final pitch = size.shortestSide * 0.3;
    final center = size.center(Offset.zero);
    final paint = Paint();
    for (var dot = 0; dot < 6; dot++) {
      paint.color = (lit & (1 << dot)) != 0 ? color : color.withValues(alpha: color.a * 0.13);
      canvas.drawCircle(center + Offset((dot ~/ 3 - 0.5) * pitch, (dot % 3 - 1) * pitch), radius, paint);
    }
  }

  @override
  bool shouldRepaint(_Braille oldDelegate) => oldDelegate.color != color || oldDelegate.clock != clock;
}
