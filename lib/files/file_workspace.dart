import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:omp_core/host.dart';
import 'package:omp_core/transport.dart';

import '../utils/app_logger.dart';
import 'file_document.dart';
import 'file_paths.dart';
import 'git_status.dart';

/// A directory's listing in the browser.
sealed class DirListing {
  const DirListing();
}

final class DirLoading extends DirListing {
  const DirLoading();
}

final class DirLoaded extends DirListing {
  const DirLoaded(this.entries);

  /// Directories first, then by name, case-insensitively.
  final List<HostDirEntry> entries;
}

final class DirFailed extends DirListing {
  const DirFailed(this.error);

  final Object error;
}

/// One line of the file browser.
sealed class BrowserRow {
  const BrowserRow(this.depth);

  final int depth;
}

final class EntryRow extends BrowserRow {
  const EntryRow({required int depth, required this.path, required this.entry, required this.expanded}) : super(depth);

  final String path;
  final HostDirEntry entry;
  final bool expanded;

  /// False for a link, whatever it points to.
  bool get isDirectory => entry.stat.isDirectory;

  bool get isLink => entry.stat.isLink;
}

/// A directory being listed.
final class LoadingRow extends BrowserRow {
  const LoadingRow(super.depth);
}

final class FailedRow extends BrowserRow {
  const FailedRow(super.depth, this.dir, this.error);

  final String dir;
  final Object error;
}

final class EmptyRow extends BrowserRow {
  const EmptyRow(super.depth);
}

/// The Files tab of one machine: the browsed directory, listings, expanded folders, git status and open documents.
/// It outlives the dock's widgets, so closing the dock keeps unsaved edits.
final class FileWorkspace extends ChangeNotifier {
  /// Resolves the machine's link and probe at call time; the tab sets it on every build.
  Future<(HostLink, HostProbe)> Function()? connect;

  String? _root;
  String? _home;
  String? _appliedCwd;
  HostProbe? _probe;
  final _dirs = <String, DirListing>{};
  final _expanded = <String>{};
  final _documents = <FileDocument>[];
  FileDocument? _current;
  GitStatus? _git;
  Future<HostFiles>? _files;
  HostLink? _filesLink;

  /// Opens in flight by path, so a double click opens one document.
  final _opening = <String, Future<void>>{};
  var _disposed = false;

  /// The browsed directory (SFTP space); null until the first listing.
  String? get root => _root;

  HostProbe? get probe => _probe;

  List<FileDocument> get documents => List.unmodifiable(_documents);

  /// The document shown instead of the browser, or null for the browser.
  FileDocument? get current => _current;

  GitStatus? get git => _git;

  DirListing? listing(String dir) => _dirs[dir];

  /// The machine's file access, reopened when the link changed or failed. Callers at the same time share one open:
  /// each SFTP channel holds a session slot and a server process on the machine.
  Future<HostFiles> files() async {
    final connect = this.connect;
    if (connect == null) throw StateError('FileWorkspace used before its machine was set');
    final (link, probe) = await connect();
    _probe = probe;
    if (!identical(link, _filesLink)) {
      _forgetFiles();
      _filesLink = link;
      _files = link.files();
    }
    final opening = _files!;
    try {
      return await opening;
    } on Object {
      if (identical(_files, opening)) {
        _files = null;
        _filesLink = null;
      }
      rethrow;
    }
  }

  /// Drops the cached file access after an error, so the next call reconnects.
  void _forgetFiles() {
    final cached = _files;
    _files = null;
    _filesLink = null;
    if (cached != null) _closeQuietly(cached);
  }

  void _closeQuietly(Future<HostFiles> files) {
    unawaited(
      files.then((files) => files.close()).catchError((Object error) {
        appLogger.w('closing file access failed: $error');
      }),
    );
  }

  /// Browses [cwd] (host-native) when the session's directory differs from the one applied last; the user's own
  /// navigation stays otherwise. Null [cwd] browses the home directory.
  Future<void> follow(String? cwd) async {
    if (_root != null && cwd == _appliedCwd) return;
    _appliedCwd = cwd;
    try {
      final files = await this.files();
      _home ??= await files.home();
      await openDir(cwd == null ? _home! : toSftpPath(cwd));
    } on Object catch (error) {
      _forgetFiles();
      _root ??= cwd == null ? '/' : toSftpPath(cwd);
      _dirs[_root!] = DirFailed(error);
      _notify();
    }
  }

  /// Resolves a path from the transcript ([resolveMachinePath]).
  String resolve(String path, {required String? cwd}) =>
      resolveMachinePath(path, home: _home, cwd: cwd, windows: _probe?.isWindows ?? false);

  /// Browses [dir].
  Future<void> openDir(String dir) async {
    _root = normalizePath(dir);
    _current = null;
    _notify();
    await _load(_root!);
    unawaited(refreshGit());
  }

  /// Expands or collapses [dir].
  Future<void> toggle(String dir) async {
    if (_expanded.remove(dir)) {
      _notify();
      return;
    }
    _expanded.add(dir);
    _notify();
    if (_dirs[dir] is! DirLoaded) await _load(dir);
  }

  /// Lists [dir] again, e.g. after its listing failed.
  Future<void> reloadDir(String dir) => _load(dir);

  Future<void> _load(String dir) async {
    _dirs[dir] = const DirLoading();
    _notify();
    try {
      final entries = await (await files()).list(dir);
      entries.sort(_byKindThenName);
      _dirs[dir] = DirLoaded(entries);
    } on Object catch (error) {
      if (error is! HostLinkException) _forgetFiles();
      _dirs[dir] = DirFailed(error);
    }
    _notify();
  }

  /// Lists the browsed directory and every expanded one again, and git status.
  Future<void> refresh() async {
    final root = _root;
    if (root == null) return;
    final dirs = [root, ..._expanded.where((dir) => relativePath(root, dir) != null)];
    await Future.wait([for (final dir in dirs) _load(dir), refreshGit()]);
  }

  /// The browser's rows: the browsed directory's entries and, under each expanded folder, its own.
  List<BrowserRow> rows() {
    final root = _root;
    if (root == null) return const [];
    final rows = <BrowserRow>[];
    // Depth-first without recursion: work items are rows to emit or (directory, depth) to list, popped from the end.
    final work = <Object>[(root, 0)];
    while (work.isNotEmpty) {
      final item = work.removeLast();
      if (item is BrowserRow) {
        rows.add(item);
        continue;
      }
      final (dir, depth) = item as (String, int);
      final children = <Object>[];
      switch (_dirs[dir]) {
        case null || DirLoading():
          children.add(LoadingRow(depth));
        case DirFailed(:final error):
          children.add(FailedRow(depth, dir, error));
        case DirLoaded(:final entries) when entries.isEmpty:
          children.add(EmptyRow(depth));
        case DirLoaded(:final entries):
          for (final entry in entries) {
            final path = joinPath(dir, entry.name);
            final expanded = entry.stat.isDirectory && _expanded.contains(path);
            children.add(EntryRow(depth: depth, path: path, entry: entry, expanded: expanded));
            if (expanded) children.add((path, depth + 1));
          }
      }
      work.addAll(children.reversed);
    }
    return rows;
  }

  /// Opens [path] in the editor, or browses it when it is a directory. A link is followed: the tree lists it as a
  /// link, and opening it opens or browses what it points to. An open document is reused; [line] (1-based) is
  /// revealed.
  Future<void> open(String path, {int? line}) {
    final normalized = normalizePath(path);
    final existing = _documents.where((document) => document.path == normalized).firstOrNull;
    if (existing != null) {
      existing.pendingLine = line;
      _current = existing;
      _notify();
      return Future.value();
    }
    // A block body: `remove` returns this very future, and `whenComplete` would wait for it.
    return _opening[normalized] ??= _openNew(normalized, line).whenComplete(() {
      _opening.remove(normalized);
    });
  }

  Future<void> _openNew(String path, int? line) async {
    final files = await this.files();
    final stat = await files.stat(path);
    if (stat == null) throw HostLinkException('no such file: $path');
    if (stat.isDirectory) {
      await openDir(path);
      return;
    }
    final document = await FileDocument.load(files, path);
    if (_disposed) {
      document.dispose();
      return;
    }
    document.pendingLine = line;
    document.addListener(_notify);
    _documents.add(document);
    _current = document;
    _notify();
  }

  void showBrowser() {
    if (_current == null) return;
    _current = null;
    _notify();
  }

  void show(FileDocument document) {
    if (!_documents.contains(document) || identical(_current, document)) return;
    _current = document;
    _notify();
  }

  /// Closes [document], dropping unsaved edits (the UI asks first).
  void closeDocument(FileDocument document) {
    final index = _documents.indexOf(document);
    if (index < 0) return;
    _documents.removeAt(index);
    document
      ..removeListener(_notify)
      ..dispose();
    if (identical(_current, document)) {
      _current = _documents.isEmpty ? null : _documents[index.clamp(0, _documents.length - 1)];
    }
    _notify();
  }

  Future<void> save(FileDocument document, {bool force = false}) async {
    await document.save(await files(), force: force);
    unawaited(refreshGit());
  }

  Future<void> reload(FileDocument document) async => document.reload(await files());

  /// Creates an empty file [name] in [dir] and opens it. Throws [HostFileExists] when the name is taken.
  Future<void> createFile(String dir, String name) async {
    final files = await this.files();
    final path = joinPath(dir, name);
    if (await files.stat(path) != null) throw HostFileExists(path);
    await files.write(path, const []);
    await _reloadListing(dir);
    await open(path);
  }

  Future<void> createFolder(String dir, String name) async {
    final files = await this.files();
    await files.mkdir(joinPath(dir, name));
    await _reloadListing(dir);
  }

  /// Renames [path] to [name] in the same directory; open documents, expanded folders and their listings follow.
  Future<void> rename(String path, String name) async {
    final files = await this.files();
    final dir = parentPath(path);
    final target = joinPath(dir, name);
    if (await files.stat(target) != null) {
      // Where the file system ignores case (macOS, Windows), a case-only rename finds the file itself; only an entry
      // with exactly that name is another file.
      final caseOnly = name.toLowerCase() == baseName(path).toLowerCase();
      if (!caseOnly || (await files.list(dir)).any((entry) => entry.name == name)) throw HostFileExists(target);
    }
    await files.rename(path, target);
    String moved(String inside) => inside == '.' ? target : joinPath(target, inside);
    for (final document in _documents) {
      final inside = relativePath(path, document.path);
      if (inside != null) document.movedTo(moved(inside));
    }
    for (final expanded in [..._expanded]) {
      final inside = relativePath(path, expanded);
      if (inside != null) {
        _expanded
          ..remove(expanded)
          ..add(moved(inside));
      }
    }
    for (final listed in [..._dirs.keys]) {
      final inside = relativePath(path, listed);
      if (inside != null) _dirs[moved(inside)] = _dirs.remove(listed)!;
    }
    await _reloadListing(dir);
    unawaited(refreshGit());
  }

  /// Deletes [path]; a directory goes with everything in it. A symbolic link, at [path] or inside, is removed
  /// itself, never what it points to. Open documents inside are closed.
  Future<void> delete(String path) async {
    final files = await this.files();
    final stat = await files.stat(path, followLinks: false);
    if (stat == null) throw HostLinkException('no such file: $path');
    if (stat.isDirectory) {
      await _deleteTree(files, path);
    } else {
      await files.remove(path);
    }
    for (final document in [..._documents]) {
      if (relativePath(path, document.path) != null) closeDocument(document);
    }
    _expanded.removeWhere((dir) => relativePath(path, dir) != null);
    _dirs.removeWhere((dir, _) => relativePath(path, dir) != null);
    await _reloadListing(parentPath(path));
    unawaited(refreshGit());
  }

  /// Post-order removal without recursion: SFTP removes only empty directories. Listings describe links
  /// themselves, so a link to a directory is removed like a file.
  Future<void> _deleteTree(HostFiles files, String root) async {
    final dirs = <String>[root];
    final order = <String>[];
    while (dirs.isNotEmpty) {
      final dir = dirs.removeLast();
      order.add(dir);
      for (final entry in await files.list(dir)) {
        final path = joinPath(dir, entry.name);
        if (entry.stat.isDirectory) {
          dirs.add(path);
        } else {
          await files.remove(path);
        }
      }
    }
    for (final dir in order.reversed) {
      await files.removeDir(dir);
    }
  }

  Future<void> _reloadListing(String dir) async {
    if (_dirs.containsKey(dir) || dir == _root) await _load(dir);
  }

  /// Git status of the repository holding the browsed directory; null outside a repository or without git.
  Future<void> refreshGit() async {
    final root = _root;
    if (root == null) return;
    try {
      final (link, probe) = await connect!();
      _git = await gitStatus(link, probe.commandShell, root);
    } on Object catch (error) {
      appLogger.w('git status in $root failed: $error');
      _git = null;
    }
    _notify();
  }

  /// `git diff HEAD` of [path] against the working tree: the text of a unified diff, empty without changes.
  Future<String> diff(String path) async {
    final (link, probe) = await connect!();
    return gitDiff(link, probe.commandShell, path);
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    for (final document in _documents) {
      document
        ..removeListener(_notify)
        ..dispose();
    }
    _documents.clear();
    final files = _files;
    if (files != null) _closeQuietly(files);
    super.dispose();
  }
}

int _byKindThenName(HostDirEntry a, HostDirEntry b) {
  if (a.stat.isDirectory != b.stat.isDirectory) return a.stat.isDirectory ? -1 : 1;
  return a.name.toLowerCase().compareTo(b.name.toLowerCase());
}
