import 'package:omp_core/host.dart';
import 'package:omp_core/transport.dart';

import 'file_paths.dart';

/// Git status of the repository holding [dir] (SFTP space); null when [dir] is not in a repository or git is
/// missing. Two commands, because PowerShell 5.1 has no `&&`. The repository root is [dir] minus its
/// `--show-prefix`, not `--show-toplevel`: the top level is a real path, and [dir] may lie behind a symlink (macOS
/// `/var` is `/private/var`).
Future<GitStatus?> gitStatus(HostLink link, CommandShell shell, String dir) async {
  final quoted = _quote(shell, hostPath(dir));
  final (prefix, status) = await (
    _run(link, shell, 'git -C $quoted rev-parse --show-prefix'),
    _run(link, shell, 'git -C $quoted status --porcelain=v1 -z'),
  ).wait;
  if (prefix.exit.code != 0 || status.exit.code != 0) return null;
  var root = normalizePath(dir);
  for (final segment in prefix.stdout.trim().split('/')) {
    if (segment.isNotEmpty) root = parentPath(root);
  }
  return GitStatus.parse(root, status.stdout);
}

/// `git diff HEAD` of the file [path] (SFTP space) as unified diff text; empty when it has no changes. A repository
/// without commits has no HEAD, so the diff falls back to the index. Throws [HostLinkException] when git fails.
Future<String> gitDiff(HostLink link, CommandShell shell, String path) async {
  final dir = _quote(shell, hostPath(parentPath(path)));
  final name = _quote(shell, baseName(path));
  final command = 'git -C $dir diff --no-color --no-ext-diff -U3';
  var result = await _run(link, shell, '$command HEAD -- $name');
  if (result.exit.code != 0) result = await _run(link, shell, '$command -- $name');
  if (result.exit.code != 0) throw HostLinkException('git diff failed (${result.exit}): ${result.stderr.trim()}');
  return result.stdout;
}

/// A POSIX machine's login shell may be fish or csh, which parse [shQuote]'s quoting differently, so the command
/// goes to `sh -s` as a script. cmd.exe and PowerShell parse it on the command line, quoted for them.
Future<ScriptResult> _run(HostLink link, CommandShell shell, String command) =>
    shell == CommandShell.posix ? runPosixScript(link, command) : runCommand(link, command);

String _quote(CommandShell shell, String value) => switch (shell) {
  CommandShell.posix => shQuote(value),
  CommandShell.powershell => psQuote(value),
  // cmd.exe: paths cannot contain double quotes.
  CommandShell.cmd => '"$value"',
};

/// A file's state in `git status`, reduced to one badge.
enum GitChange { modified, added, deleted, renamed, copied, typeChanged, untracked, ignored, conflicted }

/// `git status --porcelain=v1 -z` of one repository, keyed by absolute path in SFTP space.
final class GitStatus {
  const GitStatus({required this.root, required this.files, required this.dirty});

  /// Parses the NUL-separated porcelain output. Its paths are relative to the repository [root] (porcelain ignores
  /// `status.relativePaths`). A renamed or copied entry is followed by its source path, which is skipped. An
  /// untracked directory is reported once, with a trailing slash.
  factory GitStatus.parse(String root, String porcelain) {
    final files = <String, GitChange>{};
    final dirty = <String>{};
    final records = porcelain.split('\u0000');
    for (var i = 0; i < records.length; i++) {
      final record = records[i];
      if (record.length < 4 || record[2] != ' ') continue;
      final x = record[0];
      final y = record[1];
      final change = _change(x, y);
      if (x == 'R' || x == 'C') i++;
      final path = normalizePath(joinPath(root, record.substring(3)));
      files[path] = change;
      if (change == GitChange.ignored) continue;
      var parent = parentPath(path);
      while (parent != path && relativePath(root, parent) != null && dirty.add(parent)) {
        if (parent == normalizePath(root)) break;
        parent = parentPath(parent);
      }
    }
    return GitStatus(root: normalizePath(root), files: files, dirty: dirty);
  }

  /// Repository top level.
  final String root;
  final Map<String, GitChange> files;

  /// Directories that hold a change (the root included when anything changed).
  final Set<String> dirty;

  /// The change of [path]: its own entry, or the untracked directory holding it.
  GitChange? changeOf(String path) {
    final normalized = normalizePath(path);
    final own = files[normalized];
    if (own != null) return own;
    var parent = parentPath(normalized);
    while (relativePath(root, parent) != null) {
      final change = files[parent];
      if (change == GitChange.untracked || change == GitChange.ignored) return change;
      if (parent == root) break;
      parent = parentPath(parent);
    }
    return null;
  }
}

/// `XY` of porcelain v1: X is the index, Y the work tree (`git help status`, "Short Format").
GitChange _change(String x, String y) {
  if (x == '?' && y == '?') return GitChange.untracked;
  if (x == '!' && y == '!') return GitChange.ignored;
  if (x == 'U' || y == 'U' || (x == 'A' && y == 'A') || (x == 'D' && y == 'D')) return GitChange.conflicted;
  for (final code in [y, x]) {
    switch (code) {
      case 'D':
        return GitChange.deleted;
      case 'R':
        return GitChange.renamed;
      case 'C':
        return GitChange.copied;
      case 'T':
        return GitChange.typeChanged;
      case 'A':
        return GitChange.added;
    }
  }
  return GitChange.modified;
}
