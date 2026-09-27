import 'dart:collection';

import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

/// Writes terminal output into xterm's parser without letting one frame carry a burst.
///
/// A PTY hands over whatever the shell wrote, so `cat` of a large log arrives as many chunks, often all inside one
/// frame. Passing them to `Terminal.write` as they come parses megabytes in that frame and the UI isolate stops
/// drawing until it is done. This writer parses for at most [frameBudget] per frame, in slices of [sliceLength]
/// code units, and the rest waits for the frames that carry it, while an idle terminal writes a prompt or a
/// keystroke's echo through at once. The budget is time, not characters: a code unit of Cyrillic, CJK or emoji costs
/// xterm2's parser fifteen to twenty times one of plain ASCII (measured), so no character count is both safe for the
/// one and fast for the other.
///
/// Output queued beyond [backlogLimit] pauses the source until the frames have carried it: a shell that writes faster
/// than the terminal draws blocks, as in any terminal, instead of filling memory, and the prompt after Ctrl-C waits
/// for at most the backlog.
///
/// While the app is hidden no frames run; output is then parsed as it arrives, so a shell in a minimised window
/// neither blocks on frames that do not come nor piles up output.
///
/// The frame callback is a transient one rather than a post-frame one: transient callbacks run at the start of a
/// frame, before build and layout, so text parsed here paints in the same frame, and they can be unregistered in
/// [dispose], which post-frame callbacks cannot.
final class TerminalFrameWriter {
  /// [_write] is where a slice of output goes: xterm's `Terminal.write`. `pause` and `resume` hold and release the
  /// source of the output.
  TerminalFrameWriter(this._write, {required this._pause, required this._resume}) {
    _lifecycle = AppLifecycleListener(onStateChange: _onLifecycle);
  }

  final void Function(String text) _write;
  final void Function() _pause;
  final void Function() _resume;
  late final AppLifecycleListener _lifecycle;

  /// Parsing time per frame: half a 60 Hz frame, the other half left to build, layout and paint.
  static const frameBudget = Duration(milliseconds: 8);

  /// Code units parsed between two looks at the clock. 4 Ki code units of Cyrillic, the slowest text measured, take
  /// about 2 ms in xterm2 with the view attached on an M3 Mac, so that is what a frame overshoots [frameBudget] by;
  /// larger slices overshoot more on a slow phone, smaller ones pay the view's per-write overhead more often.
  static const sliceLength = 4096;

  /// Queued code units beyond which the source is paused: about a quarter of a second of the slowest text at the
  /// frame budget, so the prompt after Ctrl-C does not wait behind megabytes.
  static const backlogLimit = 256 * 1024;

  final _pending = ListQueue<String>();

  /// How much of `_pending.first` has been written already; only the head of the queue is ever partial.
  var _headOffset = 0;

  /// Code units in [_pending] not yet written.
  var _queued = 0;

  /// The scheduled frame callback, or null when none is pending.
  int? _frameId;

  /// Parsing time since the current frame began. A burst is many chunks in one frame, so the budget counts what the
  /// frame has carried, not what one chunk cost.
  final _spent = Stopwatch();

  /// The engine's stamp of the frame [_spent] belongs to; a moved stamp means a frame went by.
  Duration _frameStamp = Duration.zero;

  var _paused = false;
  var _disposed = false;

  /// Queues [data], or writes it straight through while this frame's budget lasts.
  void write(String data) {
    if (_disposed || data.isEmpty) return;
    _pending.addLast(data);
    _queued += data.length;
    // Nothing is scheduled while the writer keeps up, so this is the immediate path: a keystroke's echo is in the
    // buffer inside the frame it was typed in. Once the budget is spent, the queue waits for the next frame.
    if (_frameId == null) _drain();
    if (!_paused && _queued > backlogLimit) {
      _paused = true;
      _pause();
    }
  }

  /// Stops writing: the scheduled frame is cancelled and what is still queued is dropped.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _lifecycle.dispose();
    _cancelFrame();
    _pending.clear();
  }

  void _cancelFrame() {
    final frameId = _frameId;
    if (frameId == null) return;
    SchedulerBinding.instance.cancelFrameCallbackWithId(frameId);
    _frameId = null;
  }

  /// Writes what the frame's remaining budget covers (everything while no frames run), schedules the frame that
  /// carries the rest, and resumes the source once the backlog is below the limit.
  void _drain() {
    _frameId = null;
    final scheduler = SchedulerBinding.instance;
    final paced = scheduler.framesEnabled;
    final stamp = scheduler.currentSystemFrameTimeStamp;
    if (stamp != _frameStamp) {
      // Output arriving between frames, the usual case for PTY data, starts each frame with a full budget instead of
      // waiting for a callback of ours.
      _frameStamp = stamp;
      _spent.reset();
    }
    _spent.start();
    while (_pending.isNotEmpty && (!paced || _spent.elapsed < frameBudget)) {
      final head = _pending.first;
      final available = head.length - _headOffset;
      var take = available > sliceLength ? sliceLength : available;
      if (take < available && _isHighSurrogate(head.codeUnitAt(_headOffset + take - 1))) {
        // xterm2's parser decodes a code point only within one chunk of input (byte_consumer.dart), so a slice that
        // ends between the two code units hands on two lone surrogates instead of one character: hold the pair over.
        take--;
      }
      _write(_headOffset == 0 && take == available ? head : head.substring(_headOffset, _headOffset + take));
      _headOffset += take;
      _queued -= take;
      if (_headOffset == head.length) {
        _pending.removeFirst();
        _headOffset = 0;
      }
    }
    _spent.stop();
    if (_pending.isNotEmpty) _frameId = scheduler.scheduleFrameCallback(_onFrame);
    // Last, with the state settled: a source that delivers synchronously writes again from inside resume.
    if (_paused && _queued <= backlogLimit) {
      _paused = false;
      _resume();
    }
  }

  /// A frame callback runs at the start of a frame, so its budget is free again.
  void _onFrame(Duration _) {
    _spent.reset();
    _drain();
  }

  /// Hidden: the frame that would carry the queue does not come, so write it all now.
  void _onLifecycle(AppLifecycleState _) {
    if (SchedulerBinding.instance.framesEnabled) return;
    _cancelFrame();
    _drain();
  }
}

bool _isHighSurrogate(int codeUnit) => codeUnit >= 0xd800 && codeUnit <= 0xdbff;
