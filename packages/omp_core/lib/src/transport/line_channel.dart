import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

/// One newline-delimited stream to an omp RPC process, however it is carried
/// (attached stdio, a detached run directory, a Windows byte pump).
abstract interface class LineChannel {
  /// Complete lines without the trailing newline, in order. Single subscription.
  /// Closes when the channel ends; errors when the transport fails.
  Stream<String> get lines;

  /// Sends one line. [line] must not contain `\n`.
  Future<void> send(String line);

  /// Stops reading and releases the transport. Does not stop the omp process.
  Future<void> close();
}

/// Splits UTF-8 bytes into lines without breaking multi-byte characters across chunk boundaries.
Stream<String> decodeLines(Stream<Uint8List> bytes) =>
    bytes.cast<List<int>>().transform(utf8.decoder).transform(const LineSplitter());
