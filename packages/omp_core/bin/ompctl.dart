import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:omp_core/channel.dart';
import 'package:omp_core/session.dart';
import 'package:omp_core/ssh.dart';
import 'package:omp_core/store.dart';
import 'package:omp_core/transport.dart';

const _usage = '''
ompctl: drives omp sessions on a machine through omp_core's MachineRuntime (smoke tests, debugging).

  dart run omp_core:ompctl <machine> [options] <command> [arguments]

Machine, one of:
  --local [--home DIR]      this computer; --home DIR runs everything with HOME=DIR, a system-only PATH and omp's
                            directory variables cleared, so omp is found at DIR/.local/bin/omp
  --ssh USER@HOST[:PORT] --key FILE [--jump USER@HOST[:PORT] ...] [--known-hosts FILE] [--accept-new]
                            every hop authenticates with the key; host keys are checked against the known_hosts
                            file (default ~/.ssh/known_hosts); --accept-new appends keys of unknown hosts

Options:
  --companion FILE          companion build (default: companion/dist/ompx.js in the working directory or above)
  --device ID               device id (default ompctl-<hostname>)

Commands:
  probe                     connect, probe, upload the companion; print the probe
  sessions                  session files, newest first, with the runs holding them
  runs                      run directories
  open --cwd DIR [--model PROVIDER/ID] [--thinking LEVEL]
  resume SESSION_PATH
  attach RUN_ID             open, resume and attach end in a line mode:
                              text        prompt when idle, steer while a turn runs; answers an open dialog
                              /follow T   follow-up         /pause, /resume   the companion's pause gate
                              /abort      abort the turn    /queue            queued messages
                              /state      session state     /quit             detach (omp keeps running)
                              /stop       stop omp and exit
  stop RUN_ID               stop a run gracefully
  gc                        remove the directories of dead runs
''';

Future<void> main(List<String> arguments) async {
  final _Options options;
  try {
    options = _Options.parse(arguments);
  } on FormatException catch (error) {
    stderr
      ..writeln('ompctl: ${error.message}')
      ..writeln()
      ..write(_usage);
    exit(64);
  }
  final runtime = MachineRuntime(
    connect: options.connect,
    deviceId: options.device,
    companionBytes: (_) => File(options.companion).readAsBytes(),
  );
  var code = 0;
  try {
    code = await _run(runtime, options);
  } on Object catch (error) {
    stderr.writeln('ompctl: $error');
    code = 1;
  } finally {
    await runtime.dispose();
  }
  exit(code);
}

Future<int> _run(MachineRuntime runtime, _Options options) async {
  final probe = await runtime.connectAndProbe();
  final status = runtime.status;
  switch (options.command) {
    case 'probe':
      stdout
        ..writeln(const JsonEncoder.withIndent('  ').convert(probe.toJson()))
        ..writeln(switch (status) {
          MachineOnline() => 'status: online',
          MachineNeedsOmp(:final reason) => 'status: needs omp ($reason)',
          _ => 'status: $status',
        });
    case 'sessions':
      for (final session in await runtime.listSessions()) {
        final run = session.runId == null ? '' : '  [running ${session.runId}]';
        stdout.writeln('${session.modified.toLocal().toIso8601String().substring(0, 19)}  ${session.title ?? '(untitled)'}$run');
        stdout.writeln('    ${session.path}');
      }
    case 'runs':
      for (final run in await runtime.listRuns()) {
        final exit = run.exitCode == null ? '' : ' exit ${run.exitCode}';
        stdout.writeln('${run.id}  ${run.state.name}$exit  out ${run.outSize} B  in ${run.inSize} B');
        stdout.writeln('    cwd ${run.meta?.cwd ?? '?'}  session ${run.meta?.sessionPath ?? '(none yet)'}');
      }
    case 'open':
      final cwd = options.flag('cwd') ?? (throw const FormatException('open needs --cwd DIR'));
      return _interact(
        await runtime.open(NewSession(cwd, model: options.flag('model'), thinkingLevel: options.flag('thinking'))),
      );
    case 'resume':
      return _interact(await runtime.open(ResumeSession(options.argument('resume', 'SESSION_PATH'))));
    case 'attach':
      return _interact(await runtime.open(AttachRun(options.argument('attach', 'RUN_ID'))));
    case 'stop':
      final id = options.argument('stop', 'RUN_ID');
      final run = (await runtime.listRuns()).where((run) => run.id == id).firstOrNull;
      if (run == null) throw StateError('no run $id');
      stdout.writeln('exit code ${await stopRun(runtime.link, probe, run)}');
    case 'gc':
      final removed = await removeDeadRuns(runtime.link, probe);
      stdout.writeln(removed.isEmpty ? 'nothing to remove' : 'removed ${removed.join(', ')}');
    default:
      throw FormatException('unknown command ${options.command}');
  }
  return 0;
}

/// The line mode: prints what changes in the view, sends what is typed.
Future<int> _interact(LiveSession session) async {
  stdout.writeln('run ${session.runId}  cwd ${session.cwd}');
  stdout.writeln('session ${session.sessionPath ?? '(not written yet)'}');
  final printer = _Printer()..render(session.view);
  final closed = Completer<LinkClosed>();
  final views = session.views.listen(printer.render);
  final states = session.linkStates.listen((state) {
    switch (state) {
      case LinkReconnecting(:final attempt, :final nextTry, :final cause):
        final wait = nextTry.difference(DateTime.now()).inMilliseconds / 1000;
        printer.status('link lost ($cause); reconnect attempt $attempt in ${wait.toStringAsFixed(1)} s');
      case LinkLive():
        printer.status('link live');
      case LinkClosed():
        if (!closed.isCompleted) closed.complete(state);
      case LinkConnecting():
    }
  });
  // Lines run one after another; at the end of input the last ones (a /stop, say) still finish.
  var pending = Future<void>.value();
  final input = stdin.transform(utf8.decoder).transform(const LineSplitter()).listen((line) {
    pending = pending.then((_) async {
      try {
        await _command(session, printer, line);
      } on Object catch (error) {
        printer.status('error: $error');
      }
    });
  });
  await Future.any([closed.future, input.asFuture<void>()]);
  await pending;
  await input.cancel();
  if (!closed.isCompleted) await session.detach();
  final state = await closed.future;
  await views.cancel();
  await states.cancel();
  printer.status(switch (state) {
    LinkClosed(exitCode: final code?) => 'omp exited with code $code',
    LinkClosed(cause: final cause?) => 'closed: $cause',
    _ => 'detached; run ${session.runId} keeps running',
  });
  return state.cause == null ? 0 : 1;
}

Future<void> _command(LiveSession session, _Printer printer, String line) async {
  final text = line.trim();
  if (text.isEmpty) return;
  final request = session.view.requests.firstOrNull;
  if (!text.startsWith('/') && request != null && await _answer(session, request, text)) return;
  switch (text.split(' ').first) {
    case '/quit':
      await session.detach();
    case '/stop':
      await session.stop();
    case '/pause' || '/resume':
      final pause = await session.companion.call('pause.set', {'paused': text == '/pause'});
      printer.status('pause: ${jsonEncode(pause)}');
    case '/abort':
      await session.rpc.abort();
    case '/queue':
      printer.status('queue: ${jsonEncode(await session.companion.call('queue.get'))}');
    case '/state':
      final state = await session.rpc.getState();
      printer.status(
        'model ${state.model?.provider}/${state.model?.id}  streaming ${state.isStreaming}  settled ${state.isSettled}'
        '  queued ${state.queuedMessageCount}  file ${state.sessionFile}',
      );
    case '/follow':
      await session.rpc.followUp(text.substring('/follow'.length).trim());
    case final command when command.startsWith('/'):
      printer.status('unknown command $command');
    default:
      if (session.view.run.running) {
        await session.rpc.steer(text);
      } else {
        await session.rpc.prompt(text);
      }
  }
}

/// Answers [request] with [text]: an option number or label, `y`/`n`, or free text. False when [text] fits none.
Future<bool> _answer(LiveSession session, UiRequest request, String text) async {
  String? pick(List<String> options) {
    final index = int.tryParse(text);
    if (index != null && index >= 1 && index <= options.length) return options[index - 1];
    return options.where((option) => option.toLowerCase() == text.toLowerCase()).firstOrNull;
  }

  switch (request) {
    case ApprovalRequest(:final options) || SelectRequest(:final options):
      final choice = pick(options);
      if (choice == null) return false;
      await session.rpc.respondToUi(request.id, value: choice);
    case ConfirmRequest():
      await session.rpc.respondToUi(request.id, confirmed: text.toLowerCase().startsWith('y'));
    case InputRequest() || EditorRequest():
      await session.rpc.respondToUi(request.id, value: text);
    case CompanionRequest(method: 'ask', :final params):
      // The first question takes the typed answer (an option, else free text); the rest their recommended option.
      final results = <Map<String, Object?>>[];
      for (final (index, question) in _objects(params['questions']).indexed) {
        final choice = index == 0 ? pick(_labels(question)) : _recommended(question);
        results.add({
          'id': question['id'],
          'selectedOptions': [?choice],
          if (index == 0 && choice == null) 'customInput': text,
        });
      }
      await session.companion.respond(request.id, {'kind': 'submit', 'results': results});
    case CompanionRequest() || EditorTextRequest() || OpenUrlRequest():
      return false;
  }
  session.dismissRequest(request.id);
  return true;
}

String? _recommended(Map<String, Object?> question) {
  final labels = _labels(question);
  if (labels.isEmpty) return null;
  final index = question['recommended'];
  return index is int && index >= 0 && index < labels.length ? labels[index] : labels.first;
}

List<String> _labels(Map<String, Object?> question) => [
  for (final option in _objects(question['options']))
    if (option['label'] case final String label) label,
];

List<Map<String, Object?>> _objects(Object? list) => [
  if (list is List<Object?>)
    for (final item in list)
      if (item is Map<String, Object?>) item,
];

/// Prints what each new view adds: the text streamed since the last view, tool calls and results, dialogs, toasts,
/// run state changes.
final class _Printer {
  final _text = <String, String>{};
  final _seen = <String>{};
  final _requests = <String>{};
  final _notices = <int>{};
  String? _run;
  bool _midLine = false;

  void render(SessionView view) {
    for (final item in view.transcript) {
      switch (item) {
        case UserItem(:final text, :final synthetic) when !synthetic:
          _once(item.key, '> $text');
        case AssistantItem(:final content, :final streaming):
          for (final ThinkingBlock(:thinking) in content.whereType<ThinkingBlock>()) {
            if (thinking.isNotEmpty) _once('${item.key}/thinking', '(thinking) ${_clip(thinking)}');
          }
          _stream(item.key, item.text, done: !streaming);
          // Arguments stream too; a call prints once its message is complete.
          for (final ToolCallBlock(:id, :name, :arguments, :intent) in content.whereType<ToolCallBlock>()) {
            if (!streaming) _once('call/$id', '⚙ $name ${intent ?? ''} ${_clip(jsonEncode(arguments))}');
          }
        case ToolResultItem(:final toolCallId, :final state, :final text, :final isError)
            when state != ToolState.running:
          _once('result/$toolCallId', '  ↳ ${state.name}${isError ? ' (error)' : ''}: ${_clip(text)}');
        case ExecutionItem(:final command, :final output, :final exitCode):
          _once(item.key, '! $command → exit $exitCode: ${_clip(output)}');
        case CompactionItem(:final tokensBefore):
          _once(item.key, '── compacted ($tokensBefore tokens before) ──');
        case ModelChangeItem(:final model):
          _once(item.key, '── model $model ──');
        case ThinkingChangeItem(:final level):
          _once(item.key, '── thinking ${level ?? 'off'} ──');
        default:
      }
    }
    for (final request in view.requests) {
      if (_requests.add(request.id)) _line(_describe(request));
    }
    for (final notice in view.notices) {
      if (_notices.add(notice.seq)) _line('[${_notice(notice)}]');
    }
    final run = [
      switch (view.status) {
        RunStreaming() => 'running',
        RunCompacting() => 'compacting',
        RunRetrying(:final attempt, :final maxAttempts) => 'retrying $attempt/$maxAttempts',
        RunIdle() => 'idle',
        RunAborted() => 'aborted',
        RunFailed(:final message) => 'failed: $message',
      },
      if (view.run.paused) 'paused',
      if (view.queue.count > 0) 'queued ${view.queue.count}',
    ].join(', ');
    if (run != _run) {
      _run = run;
      _line('[$run]');
    }
  }

  void status(String text) => _line('[$text]');

  void _stream(String key, String text, {required bool done}) {
    final printed = _text[key] ?? '';
    if (text.length > printed.length && text.startsWith(printed)) {
      if (printed.isEmpty) _break();
      stdout.write(text.substring(printed.length));
      _midLine = !text.endsWith('\n');
      _text[key] = text;
    }
    if (done && _seen.add('done/$key')) _break();
  }

  void _once(String key, String text) {
    if (_seen.add(key)) _line(text);
  }

  void _line(String text) {
    _break();
    stdout.writeln(text);
  }

  void _break() {
    if (_midLine) stdout.writeln();
    _midLine = false;
  }

  static String _describe(UiRequest request) => switch (request) {
    ApprovalRequest(:final toolName, :final details, :final options) =>
      '? allow $toolName ${details.join(' ')}: ${_numbered(options)}',
    SelectRequest(:final title, :final options) => '? $title: ${_numbered(options)}',
    ConfirmRequest(:final title, :final message) => '? $title $message (y/n)',
    InputRequest(:final title) => '? $title (type the answer)',
    EditorRequest(:final title) => '? $title (type the text)',
    CompanionRequest(method: 'ask', :final params) =>
      '? ${[for (final question in _objects(params['questions'])) '${question['question']} ${_numbered(_labels(question))}'].join(' / ')}'
          ' (answers the first question; the rest take their recommended option)',
    CompanionRequest(:final method) => '? companion request $method (not answerable here)',
    EditorTextRequest(:final text) => '[omp sets the composer text: ${_clip(text)}]',
    OpenUrlRequest(:final url) => '[open $url]',
  };

  static String _numbered(List<String> options) => [for (final (i, o) in options.indexed) '${i + 1}) $o'].join('  ');

  static String _notice(Notice notice) => switch (notice) {
    MessageNotice(:final level, :final message) => '${level.name}: $message',
    ExtensionErrorNotice(:final extensionPath, :final error) => 'extension $extensionPath failed: $error',
    RetryFallbackNotice(:final to, :final succeeded) => 'fallback to $to${succeeded ? ' succeeded' : ''}',
    CompactionNotice(:final action, :final errorMessage) => 'compaction $action: ${errorMessage ?? 'cancelled'}',
    RulesNotice(:final rules) => 'rules ${rules.join(', ')} interrupted the response',
  };

  static String _clip(String text, [int max = 160]) {
    final flat = text.replaceAll('\n', ' ⏎ ').trim();
    return flat.length <= max ? flat : '${flat.substring(0, max)}…';
  }
}

final class _Options {
  _Options._(this.connect, this.device, this.companion, this.command, this._rest);

  /// Parses the machine flags and options; the command and its own flags stay in [_rest].
  factory _Options.parse(List<String> arguments) {
    final args = List.of(arguments);
    String? take(String flag) {
      final at = args.indexOf(flag);
      if (at < 0) return null;
      if (at + 1 >= args.length) throw FormatException('$flag needs a value');
      final value = args[at + 1];
      args.removeRange(at, at + 2);
      return value;
    }

    bool has(String flag) => args.remove(flag);

    final local = has('--local');
    final home = take('--home');
    final ssh = take('--ssh');
    final key = take('--key');
    final knownHosts = take('--known-hosts') ?? '${Platform.environment['HOME']}/.ssh/known_hosts';
    final acceptNew = has('--accept-new');
    final jumps = <String>[];
    for (String? jump; (jump = take('--jump')) != null;) {
      jumps.add(jump!);
    }
    final device = take('--device') ?? 'ompctl-${Platform.localHostname}';
    final companion = take('--companion') ?? _findCompanion();
    if (args.isEmpty) throw const FormatException('no command');
    final command = args.removeAt(0);

    final Future<HostLink> Function() connect;
    if (local == (ssh != null)) throw const FormatException('give exactly one of --local and --ssh');
    if (local) {
      final environment = home == null ? null : _isolated(home);
      connect = () async => LocalLink(environment: environment);
    } else {
      if (key == null) throw const FormatException('--ssh needs --key FILE');
      final auth = SshKeyAuth(File(key).readAsStringSync());
      final target = SshTarget(
        jumps: [for (final jump in jumps) _hop(jump, auth)],
        target: _hop(ssh!, auth),
      );
      connect = () => SshLink.open(target, verifyHostKey: (check) => _verify(check, knownHosts, acceptNew));
    }
    return _Options._(connect, device, companion, command, args);
  }

  final Future<HostLink> Function() connect;
  final String device;
  final String companion;
  final String command;
  final List<String> _rest;

  String? flag(String name) {
    final at = _rest.indexOf('--$name');
    return at >= 0 && at + 1 < _rest.length ? _rest[at + 1] : null;
  }

  String argument(String command, String name) =>
      _rest.firstOrNull ?? (throw FormatException('$command needs $name'));

  /// The environment of `omp_core`'s tests: only system directories on PATH, so the user's own omp is never found,
  /// and omp's directory variables explicitly empty (an empty value selects the default).
  static Map<String, String> _isolated(String home) => {
    'HOME': Directory(home).absolute.path,
    'PATH': '/usr/bin:/bin:/usr/sbin:/sbin',
    'PI_CODING_AGENT_DIR': '',
    'OMP_PROFILE': '',
    'PI_PROFILE': '',
    'PI_CONFIG_DIR': '',
    'XDG_DATA_HOME': '',
    'XDG_STATE_HOME': '',
    'XDG_CACHE_HOME': '',
  };

  static SshHop _hop(String spec, SshAuth auth) {
    final match = RegExp(r'^([^@]+)@([^:]+)(?::(\d+))?$').firstMatch(spec);
    if (match == null) throw FormatException('not USER@HOST[:PORT]: $spec');
    return SshHop(host: match[2]!, port: int.parse(match[3] ?? '22'), user: match[1]!, auth: auth);
  }

  static Future<bool> _verify(HostKeyCheck check, String knownHosts, bool acceptNew) async {
    final file = File(knownHosts);
    final text = file.existsSync() ? file.readAsStringSync() : '';
    switch (checkKnownHost(parseKnownHosts(text), check)) {
      case KnownHostStatus.match:
        return true;
      case KnownHostStatus.unknown when acceptNew:
        file.writeAsStringSync('${text.isEmpty || text.endsWith('\n') ? '' : '\n'}${knownHostsLine(check)}\n', mode: FileMode.append);
        stderr.writeln('ompctl: added ${knownHostName(check.host, check.port)} ${check.sha256Fingerprint} to $knownHosts');
        return true;
      case final status:
        stderr.writeln(
          'ompctl: host key of ${knownHostName(check.host, check.port)} is ${status.name} in $knownHosts '
          '(${check.keyType} ${check.sha256Fingerprint})',
        );
        return false;
    }
  }

  static String _findCompanion() {
    for (var dir = Directory.current.absolute; ; dir = dir.parent) {
      final file = File('${dir.path}/companion/dist/ompx.js');
      if (file.existsSync()) return file.path;
      if (dir.parent.path == dir.path) throw const FormatException('no companion/dist/ompx.js found; pass --companion');
    }
  }
}
