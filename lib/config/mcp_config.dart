import 'dart:convert';

import 'package:omp_core/rpc.dart';

/// Which `mcp.json` a server lives in: `<agentDir>/mcp.json` or `<project>/.omp/mcp.json`.
enum McpScope { user, project }

/// An MCP server as omp's `/mcp list` shows it.
final class McpServer {
  const McpServer({
    required this.name,
    required this.scope,
    required this.transport,
    required this.target,
    required this.enabled,
  });

  final String name;
  final McpScope scope;

  /// `stdio`, `http` or `sse`.
  final String transport;

  /// The command line of a stdio server, the URL of an http/sse one (without credentials in it).
  final String? target;
  final bool enabled;
}

/// Servers of both files in `/mcp list` order: user servers, then project servers whose name the user file
/// does not already use. A server is enabled unless its entry says `enabled: false` or the user file lists it
/// in `disabledServers`. [user] and [project] are the files' text, null when a file does not exist.
List<McpServer> parseMcpServers({required String? user, required String? project}) {
  final userJson = _config(user, 'user mcp.json');
  final projectJson = _config(project, 'project mcp.json');
  final disabled = {...?userJson.optStrings('disabledServers')};
  final servers = <McpServer>[];
  for (final (scope, json) in [(McpScope.user, userJson), (McpScope.project, projectJson)]) {
    for (final MapEntry(key: name, :value) in (json.optObject('mcpServers') ?? const {}).entries) {
      if (servers.any((server) => server.name == name)) continue;
      final entry = asJsonObject(value, 'mcp server $name');
      final transport = entry.optString('type') ?? 'stdio';
      servers.add(
        McpServer(
          name: name,
          scope: scope,
          transport: transport,
          target: transport == 'stdio' ? _commandLine(entry) : _safeUrl(entry.optString('url')),
          enabled: entry['enabled'] != false && !disabled.contains(name),
        ),
      );
    }
  }
  return servers;
}

Map<String, Object?> _config(String? text, String what) {
  if (text == null || text.trim().isEmpty) return const {};
  return asJsonObject(jsonDecode(text), what);
}

String? _commandLine(Map<String, Object?> entry) {
  final command = entry.optString('command');
  if (command == null) return null;
  final args = entry.optStrings('args') ?? const [];
  return [command, ...args].join(' ');
}

/// Origin and path only, as `/mcp list` prints it: query strings and user info may carry tokens.
String? _safeUrl(String? url) {
  if (url == null) return null;
  final uri = Uri.tryParse(url);
  if (uri == null || !uri.hasScheme) return null;
  final path = uri.path == '/' ? '' : uri.path;
  return '${uri.origin}$path';
}

/// Why omp's `validateServerName` refuses a server name.
enum McpNameProblem { empty, tooLong, invalidCharacters }

/// omp's server name rule (`validateServerName`); null when [name] passes.
McpNameProblem? mcpNameProblem(String name) {
  if (name.isEmpty) return McpNameProblem.empty;
  if (name.length > 100) return McpNameProblem.tooLong;
  if (!RegExp(r'^[a-zA-Z0-9_.:-]+(?: [a-zA-Z0-9_.:-]+)*$').hasMatch(name)) return McpNameProblem.invalidCharacters;
  return null;
}

/// `/mcp add` for a stdio server: `/mcp add <name> --scope <scope> -- <command…>`.
String mcpAddStdio(String name, McpScope scope, String commandLine) =>
    '/mcp add $name --scope ${scope.name} -- ${commandLine.trim()}';

/// `/mcp add` for a remote server. [token] becomes a bearer header in `mcp.json`.
String mcpAddRemote(String name, McpScope scope, {required String url, required String transport, String? token}) => [
  '/mcp add $name --scope ${scope.name} --url $url --transport $transport',
  if (token != null && token.isNotEmpty) '--token $token',
].join(' ');
