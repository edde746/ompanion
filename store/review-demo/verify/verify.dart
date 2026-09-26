/// Smoke-checks a running store/review-demo stack through omp_core: the same SSH link, probe, companion
/// upload, session runtime and view reducer the app uses, minus the widgets. Run it from the repository
/// root (it belongs to the app package, whose `flutter pub get` provides omp_core), after `./reset.sh`: the
/// demo rotation is a cycle, and the checks below expect its first three scenarios.
///
///   dart run store/review-demo/verify/verify.dart \
///     --password "$(sed -n 's/^REVIEW_PASSWORD=//p' store/review-demo/.env)"
///
/// Steps, each printing one OK line: connect with the generated password, probe the machine and find omp,
/// check the uploaded companion, open a session, send three prompts and check the demo rotation's canned
/// answers (markdown, a bash call, a read and edit that changes the project's README on the machine), run
/// a command over the SSH link and one through the companion's `exec.bash`, browse and edit files over
/// SFTP, and list the machine's sessions as the sidebar does. Exits non-zero on the first failure.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:omp_core/host.dart';
import 'package:omp_core/session.dart';
import 'package:omp_core/ssh.dart';
import 'package:omp_core/store.dart';
import 'package:omp_core/transport.dart';

Future<void> main(List<String> arguments) async {
  final _Options options;
  try {
    options = _Options.parse(arguments);
  } on FormatException catch (error) {
    stderr
      ..writeln('verify: ${error.message}')
      ..writeln()
      ..write(_usage);
    exit(64);
  }

  final target = SshTarget(
    target: SshHop(host: options.host, port: options.port, user: options.user, auth: SshPasswordAuth(options.password)),
  );
  // What the app's "Trust this host?" dialog decides: the key of the first connection is trusted (like the
  // reviewer tapping Trust), and a key that changes afterwards is refused.
  String? trustedFingerprint;
  final runtime = MachineRuntime(
    connect: () => SshLink.open(
      target,
      verifyHostKey: (check) async {
        final known = trustedFingerprint;
        trustedFingerprint ??= check.sha256Fingerprint;
        if (known == null) _step('host key ${check.keyType} ${check.sha256Fingerprint} (trusted on first use)');
        return check.sha256Fingerprint == trustedFingerprint;
      },
    ),
    deviceId: 'review-demo-verify',
    companionBytes: (_) => File(options.companion).readAsBytes(),
  );

  var failed = false;
  LiveSession? session;
  try {
    final probe = await runtime.connectAndProbe();
    final status = runtime.status;
    if (status is MachineNeedsOmp) {
      throw StateError('omp is missing or too old on the machine: ${status.reason}');
    }
    if (status is! MachineOnline) throw StateError('unexpected machine status $status');
    _ok(
      'probe: ${probe.os.name}/${probe.arch} libc=${probe.libc} home=${probe.home} '
      'omp=${probe.ompPath} ${probe.ompVersion}',
    );

    final link = runtime.link;
    final version = probe.ompVersion ?? 'unknown';
    final companion = await _companionFiles(link, probe.home, version);
    _ok('companion uploaded: ${companion.join(', ')}');

    final project = options.project ?? '${probe.home}/work/notes-api';
    final listing = await _list(link, project);
    _ok('file browser: $project lists ${listing.length} entries: ${listing.take(5).join(', ')}');

    final before = await _read(link, '$project/README.md');
    _ok('file browser read: $project/README.md is ${before.length} chars, first line "${_firstLine(before)}"');

    session = await runtime.open(NewSession(project));
    final model = session.view.config.model;
    _ok(
      'session: run ${session.runId} cwd ${session.cwd} file ${session.sessionPath ?? "(not written yet)"} model ${model?.provider}/${model?.id}',
    );
    if (session.companionHello == null) throw StateError('the companion did not load in the session');
    _ok('companion loaded: ${session.companionHello!.companionVersion} for omp ${session.companionHello!.ompVersion}');

    // The demo rotation: one scenario per prompt.
    final markdown = await _prompt(session, 'Hello from the review-demo smoke test.', expect: 'Renderer demo');
    _ok('reply 1 (markdown, ${markdown.text.length} chars): "${_firstLine(markdown.text)}"');

    final bash = await _prompt(session, 'Second prompt: a shell command.', expect: 'ls -la');
    final bashCalls = [
      for (final item in bash.items.whereType<AssistantItem>())
        for (final call in item.toolCalls)
          if (call.name == 'bash') call,
    ];
    final bashResults = bash.items.whereType<ToolResultItem>().where((item) => item.toolName == 'bash').toList();
    if (bashCalls.isEmpty || bashResults.isEmpty) throw StateError('the bash scenario made no bash call');
    _ok('reply 2 (bash): call `ls -la`, result "${_firstLine(bashResults.last.text)}"');

    final edit = await _prompt(session, 'Third prompt: read and edit the README.', expect: 'README.md');
    final editCalls = [
      for (final item in edit.items.whereType<AssistantItem>())
        for (final call in item.toolCalls)
          if (call.name == 'edit') call,
    ];
    if (editCalls.isEmpty) throw StateError('the read scenario made no edit call');
    final after = await _read(link, '$project/README.md');
    if (after == before) throw StateError('the read/edit scenario did not change $project/README.md');
    _ok('reply 3 (read+edit): $project/README.md changed on the machine, first line "${_firstLine(after)}"');

    final command = await runCommand(link, 'id -un; uname -m; ls "\$HOME/work/notes-api"');
    if (command.exit.code != 0) throw command.failure('the SSH command failed');
    _ok('ssh exec: ${command.stdout.trim().replaceAll('\n', ' | ')}');

    final exec = await session.companion
        .call('exec.bash', {'command': 'echo review-demo-exec'})
        .timeout(const Duration(seconds: 60));
    _ok('companion exec.bash: ${jsonEncode(exec).replaceAll('\n', ' ')}');

    final files = await link.files();
    try {
      final probePath = '${probe.home}/browser-probe.txt';
      await files.write(probePath, utf8.encode('written by verify.dart\n'));
      final written = utf8.decode(await files.read(probePath));
      await files.remove(probePath);
      if (written.trim() != 'written by verify.dart') throw StateError('the file browser wrote back "$written"');
      _ok('file browser write: wrote and removed $probePath');
    } finally {
      await files.close();
    }

    final sessions = await runtime.listSessions();
    final opened = session;
    if (!sessions.any((summary) => summary.path == opened.sessionPath || summary.runId == opened.runId)) {
      throw StateError('the new session is not in the session list of the machine (${sessions.length} sessions)');
    }
    _ok('session list: ${sessions.length} session(s), newest "${sessions.first.title ?? "(untitled)"}"');

    // What the machine's Configure pane and its model picker read: omp's own model list and the
    // companion's settings schema, both from the machine's control process.
    final control = await runtime.control();
    if (control.companionHello == null) throw StateError('the companion did not load in the control session');
    final models = await control.rpc.getAvailableModels();
    final ids = [for (final model in models) '${model.provider}/${model.id}'];
    for (final expected in ['demo/fast', 'demo/reasoning']) {
      if (!ids.contains(expected)) throw StateError('get_available_models lacks $expected: ${ids.take(10).join(', ')}');
    }
    final names = [
      for (final model in models)
        if (model.provider == 'demo') '${model.id} "${model.name}"',
    ];
    _ok('configure: get_available_models lists ${models.length} model(s): ${names.join(', ')}');

    final schema = await control.companion.call('settings.schema');
    final tabs = schema is Map<String, Object?> && schema['tabs'] is List ? (schema['tabs'] as List).length : 0;
    final settings = schema is Map<String, Object?> && schema['settings'] is List
        ? (schema['settings'] as List)
        : const [];
    if (tabs == 0 || settings.isEmpty) throw StateError('settings.schema returned $schema');
    _ok('configure: settings.schema has $tabs tab(s) and ${settings.length} setting(s)');

    final values = await control.companion.call('settings.get');
    final effective = values is Map<String, Object?> && values['settings'] is List
        ? (values['settings'] as List)
        : const [];
    final lsp = [
      for (final value in effective)
        if (value is Map<String, Object?> && value['path'] == 'lsp.enabled') value,
    ];
    if (lsp.isEmpty) throw StateError('settings.get does not report lsp.enabled: ${_clip(jsonEncode(values))}');
    _ok('configure: settings.get reports ${effective.length} value(s), lsp.enabled ${jsonEncode(lsp.first['value'])}');

    // The app detaches and leaves the run alive on the machine; reset.sh stops it there.
    await session.detach();
    session = null;
    _ok('detach: the run keeps running on the machine');
  } on Object catch (error, stack) {
    failed = true;
    stderr.writeln('FAILED: $error');
    stderr.writeln(stack);
  } finally {
    if (session != null) {
      try {
        await session.detach();
      } on Object {
        // The link is already gone.
      }
    }
    await runtime.dispose();
  }

  if (failed) exit(1);
  stdout.writeln('all steps OK');
}

/// Prompts and waits for the demo's canned answer, which the rotation picks per prompt.
Future<({String text, List<TranscriptItem> items})> _prompt(
  LiveSession session,
  String prompt, {
  required String expect,
  Duration timeout = const Duration(minutes: 4),
}) async {
  final from = session.view.transcript.length;
  await session.rpc.prompt(prompt);
  final deadline = DateTime.now().add(timeout);
  while (true) {
    final view = session.view;
    final added = view.transcript.skip(from).toList();
    final text = [
      for (final item in added)
        if (item is AssistantItem) item.text,
    ].join('\n').trim();
    final settled = !view.run.running && view.run.outcome is RunIdle;
    if (settled && text.isNotEmpty && text.contains(expect)) return (text: text, items: added);
    if (view.run.outcome case RunFailed(:final message)) throw StateError('the run failed: $message');
    if (DateTime.now().isAfter(deadline)) {
      throw StateError(
        'no answer containing "$expect" within ${timeout.inSeconds}s '
        '(status ${view.status}, ${added.length} new items, text "${_clip(text)}")',
      );
    }
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
}

/// The companion files the app uploads for [version], relative to the home.
Future<List<String>> _companionFiles(HostLink link, String home, String version) async {
  final files = await link.files();
  try {
    final dir = '$home/.ompanion/companion/$version';
    final entries = await files.list(dir);
    final names = [for (final entry in entries) entry.name];
    if (!names.any((name) => name.endsWith('.js'))) {
      throw StateError('no companion build under $dir (found ${names.join(', ')})');
    }
    return names;
  } finally {
    await files.close();
  }
}

Future<List<String>> _list(HostLink link, String path) async {
  final files = await link.files();
  try {
    return [for (final entry in await files.list(path)) '${entry.name}${entry.stat.isDirectory ? '/' : ''}'];
  } finally {
    await files.close();
  }
}

Future<String> _read(HostLink link, String path) async {
  final files = await link.files();
  try {
    return utf8.decode(await files.read(path));
  } finally {
    await files.close();
  }
}

String _firstLine(String text) =>
    text.split('\n').firstWhere((line) => line.trim().isNotEmpty, orElse: () => '').trim();

String _clip(String text) => text.length <= 200 ? text : '${text.substring(0, 200)}…';

void _step(String message) => stdout.writeln('  $message');

void _ok(String message) => stdout.writeln('OK $message');

const _usage = '''
verify: smoke-checks a running store/review-demo stack.

  dart run store/review-demo/verify/verify.dart [--host HOST] [--port PORT] [--user USER]
                                                --password PASSWORD [--project DIR] [--companion FILE]

Defaults: host 127.0.0.1, port 22222, user review, project <home>/work/notes-api, companion the app's
bundled assets/companion/ompx.js. The password is in store/review-demo/.env after setup.sh. Run
./reset.sh first: the three prompts below expect the demo rotation to start at its first scenario.
''';

final class _Options {
  _Options({
    required this.host,
    required this.port,
    required this.user,
    required this.password,
    required this.project,
    required this.companion,
  });

  final String host;
  final int port;
  final String user;
  final String password;
  final String? project;
  final String companion;

  static _Options parse(List<String> arguments) {
    String? value(String name) {
      final at = arguments.indexOf('--$name');
      if (at < 0) return null;
      if (at + 1 >= arguments.length) throw FormatException('--$name needs a value');
      return arguments[at + 1];
    }

    final script = File.fromUri(Platform.script).parent.path;
    final port = value('port') ?? '22222';
    final parsed = int.tryParse(port);
    if (parsed == null || parsed < 1 || parsed > 65535) throw FormatException('--port must be 1..65535, got $port');
    final password = value('password') ?? Platform.environment['REVIEW_PASSWORD'];
    if (password == null || password.isEmpty) {
      throw const FormatException('--password (or REVIEW_PASSWORD in the environment) is required');
    }
    return _Options(
      host: value('host') ?? '127.0.0.1',
      port: parsed,
      user: value('user') ?? 'review',
      password: password,
      project: value('project'),
      companion: value('companion') ?? _bundledCompanion(script),
    );
  }

  /// The app's bundled companion build, found by walking up from this script to the repository root; the
  /// app uploads it to the machine, and without it every companion feature (pause, queue, `exec.bash`) is
  /// unavailable.
  static String _bundledCompanion(String from) {
    var directory = Directory(from);
    for (var depth = 0; depth < 6; depth++) {
      final candidate = File('${directory.path}/assets/companion/ompx.js');
      if (candidate.existsSync()) return candidate.path;
      directory = directory.parent;
    }
    throw FormatException('no assets/companion/ompx.js above $from; build it with scripts/build_companion.sh');
  }
}
