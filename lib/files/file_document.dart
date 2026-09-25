import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:omp_core/transport.dart';
import 'package:re_editor/re_editor.dart';

/// Files larger than this open as a read-only preview of their first bytes.
const maxEditableBytes = 2 * 1024 * 1024;

/// Why a document is read-only.
enum ReadOnlyReason { tooLarge, binary, notUtf8 }

/// The file changed on the machine since it was loaded or last saved.
final class FileChangedOnDisk implements Exception {
  const FileChangedOnDisk(this.path, {required this.deleted});

  final String path;
  final bool deleted;

  @override
  String toString() => deleted ? '$path was deleted' : '$path changed on the machine';
}

/// One file open in the Files tab: its text in an editor controller, and the size and time it had on disk, which
/// [save] compares before writing so an edit made elsewhere is never silently overwritten.
final class FileDocument extends ChangeNotifier {
  FileDocument._(this._path, this.controller, this._baseline, this.readOnlyReason, this._lineBreak)
    : _saved = controller.codeLines {
    controller.addListener(_onEdit);
  }

  /// Reads [path] (SFTP space). Throws [HostLinkException] when it is missing or a directory.
  static Future<FileDocument> load(HostFiles files, String path) async {
    final (text, stat, reason) = await _read(files, path);
    return FileDocument._(path, CodeLineEditingController.fromText(text), stat, reason, _lineBreakOf(text));
  }

  String _path;
  final CodeLineEditingController controller;
  HostFileStat _baseline;
  CodeLines _saved;

  /// The file's line break, written after every line on save. The editor splits lines at every break.
  TextLineBreak _lineBreak;
  var _dirty = false;
  var _saving = false;

  /// Set when the document can be viewed only.
  ReadOnlyReason? readOnlyReason;

  /// A line (1-based) the editor should reveal once laid out.
  int? pendingLine;

  String get path => _path;

  bool get readOnly => readOnlyReason != null;

  /// Edited since the last load or save. Undoing back to the saved text restores the saved lines, so it is clean
  /// again.
  bool get dirty => _dirty;

  bool get saving => _saving;

  HostFileStat get baseline => _baseline;

  void _onEdit() {
    final dirty = !identical(controller.codeLines, _saved);
    if (dirty == _dirty) return;
    _dirty = dirty;
    notifyListeners();
  }

  /// The file moved (renamed here or a parent directory renamed).
  void movedTo(String path) {
    _path = path;
    notifyListeners();
  }

  /// Writes the text back. Unless [force], first checks that size and modification time still match what was
  /// loaded, and throws [FileChangedOnDisk] when they do not.
  Future<void> save(HostFiles files, {bool force = false}) async {
    if (readOnly) throw StateError('$path is read-only');
    _saving = true;
    notifyListeners();
    try {
      if (!force) {
        final current = await files.stat(path);
        if (current == null) throw FileChangedOnDisk(path, deleted: true);
        if (current.size != _baseline.size || current.modified != _baseline.modified) {
          throw FileChangedOnDisk(path, deleted: false);
        }
      }
      final lines = controller.codeLines;
      await files.write(path, utf8.encode(lines.asString(_lineBreak)));
      _saved = lines;
      _baseline = await files.stat(path) ?? _baseline;
      _dirty = !identical(controller.codeLines, _saved);
    } finally {
      _saving = false;
      notifyListeners();
    }
  }

  /// Replaces the text with the file's current content, dropping edits.
  Future<void> reload(HostFiles files) async {
    final (text, stat, reason) = await _read(files, path);
    controller.value = CodeLineEditingValue(codeLines: text.codeLines);
    _saved = controller.codeLines;
    _baseline = stat;
    _lineBreak = _lineBreakOf(text);
    readOnlyReason = reason;
    _dirty = false;
    notifyListeners();
  }

  @override
  void dispose() {
    controller
      ..removeListener(_onEdit)
      ..dispose();
    super.dispose();
  }
}

Future<(String, HostFileStat, ReadOnlyReason?)> _read(HostFiles files, String path) async {
  final stat = await files.stat(path);
  if (stat == null) throw HostLinkException('no such file: $path');
  if (stat.isDirectory) throw HostLinkException('$path is a directory');
  // Always a bounded read: devices and /proc files report size 0 yet never end, or hold more than they report.
  final bytes = await files.read(path, length: maxEditableBytes + 1);
  final tooLarge = bytes.length > maxEditableBytes;
  final (text, reason) = decodeFileText(tooLarge ? bytes.sublist(0, maxEditableBytes) : bytes, truncated: tooLarge);
  return (text, stat, reason);
}

/// The text of a file's bytes, and why it must stay read-only: [truncated] (only a prefix was read), a NUL byte in
/// the first 8 KiB (binary), or bytes that are not UTF-8 (saving would corrupt them).
(String, ReadOnlyReason?) decodeFileText(List<int> bytes, {required bool truncated}) {
  final head = bytes.length > 8192 ? bytes.sublist(0, 8192) : bytes;
  if (head.contains(0)) return ('', ReadOnlyReason.binary);
  if (truncated) return (utf8.decode(bytes, allowMalformed: true), ReadOnlyReason.tooLarge);
  try {
    return (utf8.decode(bytes), null);
  } on FormatException {
    return (utf8.decode(bytes, allowMalformed: true), ReadOnlyReason.notUtf8);
  }
}

/// The line break most of [text]'s lines end with, so saving rewrites only the lines that differ from it.
TextLineBreak _lineBreakOf(String text) {
  var crlf = 0, cr = 0, lf = 0;
  for (var i = 0; i < text.length; i++) {
    switch (text.codeUnitAt(i)) {
      case 0x0d when i + 1 < text.length && text.codeUnitAt(i + 1) == 0x0a:
        crlf++;
        i++;
      case 0x0d:
        cr++;
      case 0x0a:
        lf++;
    }
  }
  if (crlf > lf && crlf >= cr) return TextLineBreak.crlf;
  if (cr > lf && cr > crlf) return TextLineBreak.cr;
  return TextLineBreak.lf;
}
