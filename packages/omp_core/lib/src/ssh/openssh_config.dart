import 'dart:io';

/// One `ProxyJump` hop: `[user@]host[:port]` or `ssh://[user@]host[:port]`, IPv6 in brackets.
final class SshJumpSpec {
  const SshJumpSpec({this.user, required this.host, this.port});

  factory SshJumpSpec.parse(String spec) {
    var rest = spec.trim();
    if (rest.startsWith('ssh://')) rest = rest.substring('ssh://'.length);
    String? user;
    final at = rest.lastIndexOf('@');
    if (at >= 0) {
      user = rest.substring(0, at);
      rest = rest.substring(at + 1);
    }
    String host = rest;
    int? port;
    if (rest.startsWith('[')) {
      final close = rest.indexOf(']');
      if (close < 0) throw FormatException('unclosed [ in jump host', spec);
      host = rest.substring(1, close);
      final after = rest.substring(close + 1);
      if (after.isNotEmpty) {
        if (!after.startsWith(':')) throw FormatException('unexpected text after ]', spec);
        port = _port(after.substring(1), spec);
      }
    } else if (':'.allMatches(rest).length == 1) {
      final colon = rest.indexOf(':');
      host = rest.substring(0, colon);
      port = _port(rest.substring(colon + 1), spec);
    }
    if (host.isEmpty || (user != null && user.isEmpty)) throw FormatException('empty user or host', spec);
    return SshJumpSpec(user: user, host: host, port: port);
  }

  final String? user;
  final String host;
  final int? port;

  static int _port(String text, String spec) {
    final port = int.tryParse(text);
    if (port == null || port < 1 || port > 65535) throw FormatException('bad port', spec);
    return port;
  }
}

/// The settings `ssh -G` resolved for one host, after `Host`, `Match` and `Include`.
final class SshResolvedHost {
  const SshResolvedHost({
    this.name,
    required this.hostname,
    required this.user,
    required this.port,
    this.identityFiles = const [],
    this.identitiesOnly = false,
    this.proxyJump = const [],
    this.proxyCommand,
    this.identityAgent,
    this.userKnownHostsFiles = const [],
  });

  /// The name given to `ssh` (`%n`).
  final String? name;
  final String hostname;
  final String user;
  final int port;

  /// In config order, as ssh prints them: `~` and `%` tokens are not expanded (see [sshIdentities]). Without an
  /// `IdentityFile`, ssh prints its defaults.
  final List<String> identityFiles;
  final bool identitiesOnly;

  /// Jump hosts in dial order. Each may itself be an alias; resolve it with [resolveSshAlias].
  final List<SshJumpSpec> proxyJump;

  /// A `ProxyCommand` ompanion cannot follow, reported so the UI can say so.
  final String? proxyCommand;

  /// As configured, `none` included; null when unset (`SSH_AUTH_SOCK`).
  final String? identityAgent;
  final List<String> userKnownHostsFiles;
}

/// Parses the output of `ssh -G`. Throws [FormatException] when a required key is missing.
SshResolvedHost parseSshG(String output) {
  final values = <String, List<String>>{};
  for (final line in output.split('\n')) {
    final trimmed = line.trim();
    if (trimmed.isEmpty) continue;
    final space = trimmed.indexOf(' ');
    if (space < 0) continue;
    values.putIfAbsent(trimmed.substring(0, space).toLowerCase(), () => []).add(trimmed.substring(space + 1).trim());
  }
  String required(String key) =>
      values[key]?.first ?? (throw FormatException('ssh -G output has no "$key" line', output));
  String? optional(String key) {
    final value = values[key]?.first;
    return value == null || value == 'none' ? null : value;
  }

  final port = int.tryParse(required('port'));
  if (port == null) throw FormatException('ssh -G printed a non-numeric port', output);
  final jump = optional('proxyjump');
  return SshResolvedHost(
    name: values['host']?.first,
    hostname: required('hostname'),
    user: required('user'),
    port: port,
    identityFiles: values['identityfile'] ?? const [],
    identitiesOnly: values['identitiesonly']?.first == 'yes',
    proxyJump: jump == null ? const [] : [for (final spec in jump.split(',')) SshJumpSpec.parse(spec)],
    proxyCommand: optional('proxycommand'),
    identityAgent: values['identityagent']?.first,
    userKnownHostsFiles: [for (final value in values['userknownhostsfile'] ?? const <String>[]) ...value.split(' ')],
  );
}

/// Runs the local `ssh -G` (desktop). [user] and [port] override the config like `-l` and `-p`,
/// which is how a `ProxyJump` hop is resolved.
Future<SshResolvedHost> resolveSshAlias(String alias, {String? user, int? port, String? configFile}) async {
  if (alias.isEmpty || alias.startsWith('-')) throw ArgumentError.value(alias, 'alias', 'not a host name');
  final result = await Process.run('ssh', [
    '-G',
    if (configFile != null) ...['-F', configFile],
    if (user != null) ...['-l', user],
    if (port != null) ...['-p', '$port'],
    alias,
  ]);
  if (result.exitCode != 0) {
    throw ProcessException('ssh', ['-G', alias], '${result.stderr}'.trim(), result.exitCode);
  }
  return parseSshG(result.stdout as String);
}

/// Replaces a leading `~` with [home].
String expandHome(String path, String home) => path == '~'
    ? home
    : path.startsWith('~/')
    ? '$home${path.substring(1)}'
    : path;

/// The keys `ssh` would offer one host: the agent's, then [files] (see `pubkey_prepare` in OpenSSH's sshconnect2.c).
final class SshIdentities {
  const SshIdentities({this.agentSocket, this.agentProblem, this.files = const [], this.identitiesOnly = false});

  /// The ssh-agent to ask; null for none, and then [agentProblem] says why.
  final String? agentSocket;
  final String? agentProblem;

  /// In config order: the path as configured, for messages, and expanded.
  final List<({String configured, String path})> files;

  /// Offer only agent keys that are also one of [files].
  final bool identitiesOnly;
}

/// What `ssh` does with [host]'s `IdentityAgent`, `IdentityFile` and `IdentitiesOnly`: the agent is `IdentityAgent`
/// (`none`, `SSH_AUTH_SOCK`, `$VAR` or a path) or else `SSH_AUTH_SOCK` from [environment]; paths get `~`, `${VAR}`
/// and `%` tokens expanded. Throws [FormatException] for a token or variable ssh would reject.
SshIdentities sshIdentities(
  SshResolvedHost host, {
  required String home,
  required Map<String, String> environment,
  String? localHostname,
}) {
  final local = localHostname ?? Platform.localHostname;
  final tokens = {
    '%': '%',
    'd': home,
    'h': host.hostname,
    'n': host.name ?? host.hostname,
    'p': '${host.port}',
    'r': host.user,
    'u': environment['USER'] ?? environment['USERNAME'] ?? environment['LOGNAME'] ?? '',
    'l': local,
    'L': local.split('.').first,
  };
  String expand(String path) => _expandPath(path, home, tokens, environment);

  (String?, String?) fromEnvironment(String name) => switch (environment[name]) {
    null || '' => (null, '$name is not set'),
    final socket => (socket, null),
  };
  final (socket, problem) = switch (host.identityAgent) {
    null || 'SSH_AUTH_SOCK' => fromEnvironment('SSH_AUTH_SOCK'),
    'none' => (null, 'IdentityAgent is none'),
    final agent when agent.startsWith(r'$') => fromEnvironment(agent.substring(1)),
    final agent => (expand(agent), null),
  };
  return SshIdentities(
    agentSocket: socket,
    agentProblem: problem,
    files: [for (final file in host.identityFiles) (configured: file, path: expand(file))],
    identitiesOnly: host.identitiesOnly,
  );
}

String _expandPath(String path, String home, Map<String, String> tokens, Map<String, String> environment) {
  final withVariables = path.replaceAllMapped(RegExp(r'\$\{([A-Za-z_][A-Za-z0-9_]*)\}'), (match) {
    final name = match.group(1)!;
    return environment[name] ?? (throw FormatException('environment variable $name in "$path" is not set'));
  });
  final expanded = withVariables.replaceAllMapped(RegExp('%(.?)'), (match) {
    final token = match.group(1)!;
    return tokens[token] ?? (throw FormatException('unsupported token %$token in "$path"'));
  });
  return expandHome(expanded, home);
}

/// Host aliases from an OpenSSH client config and the files it `Include`s, in file order.
/// Patterns (`*`, `?`, `!`) are skipped: they are defaults, not machines.
Future<List<String>> listSshConfigAliases({String? configPath, String? home}) async {
  final homeDir = home ?? Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'];
  if (homeDir == null) throw StateError('no home directory in the environment');
  final aliases = <String>{};
  await _collectAliases(configPath ?? '$homeDir/.ssh/config', homeDir, aliases, 0);
  return aliases.toList();
}

// OpenSSH's READCONF_MAX_DEPTH.
const _maxIncludeDepth = 16;

Future<void> _collectAliases(String path, String home, Set<String> aliases, int depth) async {
  if (depth > _maxIncludeDepth) return;
  final file = File(path);
  if (!await file.exists()) return;
  for (final line in await file.readAsLines()) {
    final (keyword, args) = _splitConfigLine(line);
    switch (keyword) {
      case 'host':
        aliases.addAll(args.where((pattern) => !pattern.contains(RegExp(r'[*?!]'))));
      case 'include':
        for (final pattern in args) {
          // Relative includes in a user config are relative to ~/.ssh.
          final expanded = expandHome(pattern, home);
          final absolute = expanded.startsWith('/') || RegExp(r'^[A-Za-z]:[\\/]').hasMatch(expanded)
              ? expanded
              : '$home/.ssh/$expanded';
          for (final included in await _glob(absolute)) {
            await _collectAliases(included, home, aliases, depth + 1);
          }
        }
    }
  }
}

/// Keyword (lowercased) and arguments of one config line; `Keyword=value` and quotes allowed.
(String, List<String>) _splitConfigLine(String line) {
  final match = RegExp(r'^\s*([A-Za-z]+)\s*(?:=\s*|\s+)(.*)$').firstMatch(line);
  if (match == null) return ('', const []);
  final args = <String>[];
  for (final token in RegExp(r'"([^"]*)"|(\S+)').allMatches(match.group(2)!)) {
    final value = token.group(1) ?? token.group(2)!;
    if (token.group(2)?.startsWith('#') ?? false) break;
    args.add(value);
  }
  return (match.group(1)!.toLowerCase(), args);
}

/// Expands `*`, `?` and `[...]` in each path segment, sorted like glob(3).
Future<List<String>> _glob(String pattern) async {
  final segments = pattern.split('/');
  var matches = [segments.first];
  for (final segment in segments.skip(1)) {
    final next = <String>[];
    for (final base in matches) {
      if (!segment.contains(RegExp(r'[*?\[]'))) {
        next.add('$base/$segment');
        continue;
      }
      final dir = Directory(base.isEmpty ? '/' : base);
      if (!await dir.exists()) continue;
      final regex = _globRegExp(segment);
      final names = [
        await for (final entity in dir.list(followLinks: false)) entity.uri.pathSegments.lastWhere((s) => s.isNotEmpty),
      ]..sort();
      // Like glob(3), a wildcard does not match a leading dot.
      final hidden = segment.startsWith('.');
      next.addAll([
        for (final name in names)
          if ((hidden || !name.startsWith('.')) && regex.hasMatch(name)) '$base/$name',
      ]);
    }
    matches = next;
  }
  return [
    for (final path in matches)
      if (await File(path).exists()) path,
  ];
}

RegExp _globRegExp(String segment) {
  final buffer = StringBuffer('^');
  for (var i = 0; i < segment.length; i++) {
    final char = segment[i];
    switch (char) {
      case '*':
        buffer.write('.*');
      case '?':
        buffer.write('.');
      case '[':
        final close = segment.indexOf(']', i + 1);
        if (close < 0) {
          buffer.write(r'\[');
        } else {
          final body = segment.substring(i + 1, close);
          buffer.write('[${body.startsWith('!') ? '^${body.substring(1)}' : body}]');
          i = close;
        }
      default:
        buffer.write(RegExp.escape(char));
    }
  }
  return RegExp('$buffer\$');
}
