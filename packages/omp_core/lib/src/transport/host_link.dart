import 'dart:async';
import 'dart:typed_data';

/// A machine the app can run commands on, read files from, and open sockets through.
///
/// Implementations: `LocalLink` (this computer) and `SshLink` (dartssh2).
abstract interface class HostLink {
  /// Short human label for errors and logs, e.g. `user@host` or `this computer`.
  String get label;

  /// Starts [command] with SSH exec semantics: the machine's shell for this user parses it.
  /// `LocalLink` runs `/bin/sh -c` on POSIX and `cmd.exe /d /s /c` on Windows.
  ///
  /// With [pty] the process gets a terminal; stderr is merged into stdout.
  Future<HostProcess> exec(String command, {PtyRequest? pty});

  /// File access in SFTP path space: POSIX paths, Windows drives as `/C:/...`.
  Future<HostFiles> files();

  /// Opens a TCP connection from the machine to [host]:[port] (SSH `direct-tcpip`).
  Future<HostSocket> connect(String host, int port);

  /// Completes when the link is gone: closed locally, closed by the peer, or the network dropped.
  Future<void> get done;

  Future<void> close();
}

final class PtyRequest {
  const PtyRequest({required this.columns, required this.rows, this.term = 'xterm-256color'});

  final int columns;
  final int rows;
  final String term;
}

abstract interface class HostProcess {
  Stream<Uint8List> get stdout;

  /// Empty when the process runs with a PTY.
  Stream<Uint8List> get stderr;

  void write(List<int> bytes);

  /// Sends EOF on stdin.
  Future<void> closeStdin();

  Future<HostExit> get exit;

  /// Only meaningful with a PTY.
  void resize(int columns, int rows);

  /// Best effort: SIGTERM over SSH, `Process.kill` locally.
  void kill();

  /// Ends the process for good: over SSH the channel closes, so sshd hangs up a PTY session (interactive shells
  /// ignore [kill]'s SIGTERM); locally the process is killed. Completes when the channel or process is gone.
  Future<void> close();
}

final class HostExit {
  const HostExit({this.code, this.signal});

  /// Null when the process ended by signal or the channel closed without an exit status.
  final int? code;
  final String? signal;

  @override
  String toString() => signal != null ? 'signal $signal' : 'exit $code';
}

abstract interface class HostFiles {
  /// Null when [path] does not exist. With [followLinks] false a symbolic link describes itself (SFTP LSTAT):
  /// [HostFileStat.isLink] is true and [HostFileStat.isDirectory] false, whatever the link points to.
  Future<HostFileStat?> stat(String path, {bool followLinks = true});

  /// Entries describe themselves without following links, as [stat] with `followLinks: false` does.
  Future<List<HostDirEntry>> list(String path);

  /// Reads [length] bytes from [offset], or to the end when [length] is null.
  Future<Uint8List> read(String path, {int offset = 0, int? length});

  /// Creates or truncates [path], or appends when [append] is true. [mode] applies on creation.
  Future<void> write(String path, List<int> bytes, {bool append = false, int? mode});

  /// Throws [HostFileExists] when [path] already exists; used as an atomic lock.
  Future<void> mkdir(String path, {int? mode});

  /// Deletes a file or a symbolic link. A link is removed itself, never what it points to.
  Future<void> remove(String path);

  Future<void> removeDir(String path);

  Future<void> rename(String from, String to);

  /// Absolute home directory of the logged-in user, in SFTP path space.
  Future<String> home();

  Future<void> close();
}

final class HostFileStat {
  const HostFileStat({required this.size, required this.isDirectory, this.isLink = false, this.modified, this.mode});

  final int size;
  final bool isDirectory;
  final bool isLink;
  final DateTime? modified;
  final int? mode;
}

final class HostDirEntry {
  const HostDirEntry(this.name, this.stat);

  final String name;
  final HostFileStat stat;
}

abstract interface class HostSocket {
  Stream<Uint8List> get input;

  void add(List<int> bytes);

  Future<void> get done;

  Future<void> close();
}

class HostLinkException implements Exception {
  HostLinkException(this.message, {this.cause});

  final String message;
  final Object? cause;

  @override
  String toString() => cause == null ? message : '$message: $cause';
}

class HostFileExists extends HostLinkException {
  HostFileExists(String path) : super('already exists: $path');
}
