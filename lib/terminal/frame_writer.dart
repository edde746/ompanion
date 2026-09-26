import 'dart:collection';

import 'package:flutter/scheduler.dart';

/// Writes terminal output into xterm's parser without letting one frame carry a burst.
///
/// A PTY hands over whatever the shell wrote, so `cat` of a large log arrives as many chunks of up to a buffer's
/// worth, all delivered inside one frame. Passing them to `Terminal.write` as they come parses megabytes in that
/// frame and the UI isolate stops drawing until it is done. This writer moves at most [charBudget] code units per
/// frame — the rest waits for the frames that carry it — while an idle terminal writes a prompt or a keystroke's
/// echo through at once.
///
/// The frame callback is a transient one rather than a post-frame one: transient callbacks run at the start of a
/// frame, before build and layout, so text parsed here paints in the same frame, and they can be unregistered in
/// [dispose], which post-frame callbacks cannot.
final class TerminalFrameWriter {
  /// [write] is where a slice of output goes: xterm's `Terminal.write`.
  TerminalFrameWriter(this._write);

  final void Function(String text) _write;

  /// The most UTF-16 code units parsed in one frame. 64 Ki code units are a few milliseconds in xterm's parser and
  /// fill a screen several times over, so a burst spreads over frames instead of blocking one.
  static const int charBudget = 64 * 1024;

  final _pending = ListQueue<String>();

  /// How much of `_pending.first` has been written already; only the head of the queue is ever partial.
  var _headOffset = 0;

  /// The scheduled frame callback, or null when none is pending.
  int? _frameId;

  /// Code units written since the current frame began. A burst is many chunks in one frame, so the budget counts
  /// what the frame has carried, not what one chunk is worth.
  var _written = 0;

  /// The engine's stamp of the frame [_written] belongs to; a moved stamp means a frame went by.
  Duration _frameStamp = Duration.zero;

  var _disposed = false;

  /// Queues [data], or writes it straight through while this frame's budget lasts.
  void write(String data) {
    if (_disposed || data.isEmpty) return;
    _pending.addLast(data);
    // Nothing is scheduled while the writer keeps up, so this is the immediate path: a keystroke's echo is in the
    // buffer inside the frame it was typed in. Once the budget is spent, the queue waits for the next frame.
    if (_frameId == null) _drain();
  }

  /// Writes everything queued, now: for tests and for teardown paths that need the terminal up to date.
  void flush() {
    _cancelFrame();
    if (_disposed) return;
    while (_pending.isNotEmpty) {
      final head = _pending.removeFirst();
      _write(_headOffset == 0 ? head : head.substring(_headOffset));
      _headOffset = 0;
    }
  }

  /// Stops writing: the scheduled frame is cancelled and what is still queued is dropped.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _cancelFrame();
    _pending.clear();
    _headOffset = 0;
  }

  void _cancelFrame() {
    final frameId = _frameId;
    if (frameId == null) return;
    SchedulerBinding.instance.cancelFrameCallbackWithId(frameId);
    _frameId = null;
  }

  /// Writes what the frame's remaining budget covers and schedules the frame that carries the rest.
  void _drain() {
    _frameId = null;
    _rollFrame();
    var budget = charBudget - _written;
    while (budget > 0 && _pending.isNotEmpty) {
      final head = _pending.first;
      final available = head.length - _headOffset;
      var take = available > budget ? budget : available;
      if (take < available && _isHighSurrogate(head.codeUnitAt(_headOffset + take - 1))) {
        // xterm2's parser decodes a code point only within one chunk of input (byte_consumer.dart), so a slice that
        // ends between the two code units hands on two lone surrogates instead of one character: hold the pair over.
        take--;
      }
      if (take == 0) break;
      _write(_headOffset == 0 && take == available ? head : head.substring(_headOffset, _headOffset + take));
      _headOffset += take;
      budget -= take;
      _written += take;
      if (_headOffset == head.length) {
        _pending.removeFirst();
        _headOffset = 0;
      }
    }
    if (_pending.isNotEmpty) _frameId = SchedulerBinding.instance.scheduleFrameCallback(_onFrame);
  }

  /// A frame callback runs at the start of a frame, so its budget is free again.
  void _onFrame(Duration _) {
    _written = 0;
    _drain();
  }

  /// Gives back the budget when the engine stamped a new frame. Output arriving between frames — the usual case for
  /// PTY data — therefore starts each frame with a full budget instead of waiting for a callback of ours.
  void _rollFrame() {
    final stamp = SchedulerBinding.instance.currentSystemFrameTimeStamp;
    if (stamp == _frameStamp) return;
    _frameStamp = stamp;
    _written = 0;
  }
}

bool _isHighSurrogate(int codeUnit) => codeUnit >= 0xd800 && codeUnit <= 0xdbff;
