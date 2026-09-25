/// Paths in SFTP path space, the form `HostFiles` takes: POSIX paths, and Windows drives as `/C:/...`.
library;

/// `/C:` or `/C:/`: a Windows drive root in SFTP form.
final _driveRoot = RegExp(r'^/[A-Za-z]:/?$');

/// Collapses repeated slashes, `.` and `..`, and drops a trailing slash. A drive root keeps its slash (`/C:/`); `..`
/// never climbs above `/`.
String normalizePath(String path) {
  final absolute = path.startsWith('/');
  final parts = <String>[];
  for (final part in path.split('/')) {
    if (part.isEmpty || part == '.') continue;
    if (part == '..') {
      if (parts.isNotEmpty) parts.removeLast();
      continue;
    }
    parts.add(part);
  }
  final joined = parts.join('/');
  if (!absolute) return joined.isEmpty ? '.' : joined;
  if (parts.length == 1 && _isDrive(parts.single)) return '/$joined/';
  return '/$joined';
}

bool _isDrive(String part) => part.length == 2 && part[1] == ':' && RegExp('[A-Za-z]').hasMatch(part[0]);

bool isRootPath(String path) => path == '/' || _driveRoot.hasMatch(path);

/// [name] inside directory [dir].
String joinPath(String dir, String name) => dir.endsWith('/') ? '$dir$name' : '$dir/$name';

/// The directory holding [path]; a root is its own parent, and a drive root's parent is `/`.
String parentPath(String path) {
  final normalized = normalizePath(path);
  if (normalized == '/') return '/';
  if (_driveRoot.hasMatch(normalized)) return '/';
  final cut = normalized.lastIndexOf('/');
  if (cut <= 0) return '/';
  final parent = normalized.substring(0, cut);
  return _isDrive(parent.substring(1)) && parent.indexOf('/', 1) < 0 ? '$parent/' : parent;
}

/// The last segment of [path]; a drive root names its drive (`C:`), `/` stays `/`.
String baseName(String path) {
  final normalized = normalizePath(path);
  if (normalized == '/') return '/';
  final trimmed = normalized.endsWith('/') ? normalized.substring(0, normalized.length - 1) : normalized;
  return trimmed.substring(trimmed.lastIndexOf('/') + 1);
}

/// The file extension without its dot, lowercased; empty when there is none. A leading dot (`.bashrc`) is a name.
String extensionOf(String name) {
  final dot = name.lastIndexOf('.');
  if (dot <= 0 || dot == name.length - 1) return '';
  return name.substring(dot + 1).toLowerCase();
}

/// One segment of a breadcrumb bar and the directory it opens.
final class Crumb {
  const Crumb(this.label, this.path);

  final String label;
  final String path;

  @override
  bool operator ==(Object other) => other is Crumb && other.label == label && other.path == path;

  @override
  int get hashCode => Object.hash(label, path);

  @override
  String toString() => 'Crumb($label, $path)';
}

/// The directories from the root down to [path]: `/`, then every segment. A Windows drive is one crumb (`C:`).
List<Crumb> breadcrumbs(String path) {
  final normalized = normalizePath(path);
  final crumbs = <Crumb>[const Crumb('/', '/')];
  var current = '';
  for (final part in normalized.split('/')) {
    if (part.isEmpty) continue;
    if (current.isEmpty && _isDrive(part)) {
      current = '/$part/';
      crumbs.add(Crumb(part, current));
      continue;
    }
    current = joinPath(current.isEmpty ? '/' : current, part);
    crumbs.add(Crumb(part, current));
  }
  return crumbs;
}

/// [path] relative to [root] when it lies inside it, else null. The root itself is `.`.
String? relativePath(String root, String path) {
  final base = normalizePath(root);
  final target = normalizePath(path);
  if (target == base) return '.';
  final prefix = base.endsWith('/') ? base : '$base/';
  return target.startsWith(prefix) ? target.substring(prefix.length) : null;
}

/// Why [name] cannot be a new file or folder name, or null when it can.
enum NameProblem { empty, reserved, separator }

NameProblem? checkName(String name) {
  if (name.trim().isEmpty) return NameProblem.empty;
  if (name == '.' || name == '..') return NameProblem.reserved;
  if (name.contains('/') || name.contains(r'\') || name.contains('\u0000')) return NameProblem.separator;
  return null;
}
