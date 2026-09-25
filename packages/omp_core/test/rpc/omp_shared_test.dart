@Tags(['omp'])
library;

import 'dart:async';
import 'dart:io';

import 'package:omp_core/rpc.dart';
import 'package:omp_core/transport.dart';
import 'package:test/test.dart';

import 'omp_process.dart';

/// PLAN.md §5's detached launch in miniature: omp reads `in.jsonl` through `tail -f` and appends to
/// `out.jsonl`; `tail.pid` and `omp.pid` let the test stop it. Arguments: work dir, run dir, omp.
const String _launch = r'''
cd "$1" || exit 1
{ tail -c +1 -f "$2/in.jsonl" & echo $! > "$2/tail.pid"; wait; } |
  sh -c 'echo $$ > "$0/omp.pid"; exec env -i HOME="$HOME" PATH="$PATH" TMPDIR="${TMPDIR:-/tmp}" USER="$USER" LANG="${LANG:-C.UTF-8}" "$1" --mode rpc-ui --no-session --model fake/fake-1' "$2" "$3" \
  >> "$2/out.jsonl" 2>> "$2/err.log"
''';

/// Serializes appends to `in.jsonl`, standing in for the app's `in.lock`.
final class _Inbox {
  _Inbox(this._file);

  final File _file;
  Future<void> _last = Future.value();

  Future<void> append(String line) =>
      _last = _last.then((_) => _file.writeAsString('$line\n', mode: FileMode.append, flush: true));
}

/// One device on the run directory: tails `out.jsonl` from [offset], appends to `in.jsonl`.
final class _DeviceChannel implements LineChannel {
  _DeviceChannel._(this._tail, this._inbox) : lines = decodeLines(_tail.stdout);

  static Future<_DeviceChannel> open(LocalLink link, String run, int offset, _Inbox inbox) async =>
      _DeviceChannel._(await link.exec('exec tail -c +${offset + 1} -f ${shellQuote('$run/out.jsonl')}'), inbox);

  final HostProcess _tail;
  final _Inbox _inbox;

  @override
  final Stream<String> lines;

  @override
  Future<void> send(String line) => _inbox.append(line);

  @override
  Future<void> close() async {
    _tail.kill();
    await _tail.exit;
  }
}

void main() {
  late OmpHome home;
  late LocalLink link;
  late String run;
  late HostProcess omp;
  final clients = <RpcClient>[];

  setUpAll(() async {
    home = await OmpHome.create();
    link = LocalLink(environment: {'HOME': home.home});
    run = '${home.root.path}/run';
    await Directory(run).create();
    await File('$run/in.jsonl').create();
    await File('$run/out.jsonl').create();
    omp = await link.exec(
      'sh -c ${shellQuote(_launch)} launch ${shellQuote(home.work)} ${shellQuote(run)} ${shellQuote(ompBinary)}',
    );
  });

  tearDownAll(() async {
    for (final client in clients) {
      await client.close();
    }
    // Killing the feeding tail closes omp's stdin, its graceful stop.
    Process.killPid(int.parse(File('$run/tail.pid').readAsStringSync().trim()));
    final exit = await omp.exit.timeout(
      const Duration(seconds: 20),
      onTimeout: () {
        Process.killPid(int.parse(File('$run/omp.pid').readAsStringSync().trim()), ProcessSignal.sigkill);
        return omp.exit;
      },
    );
    await link.close();
    final errors = File('$run/err.log').readAsStringSync();
    await home.delete();
    expect(exit.code, 0, reason: 'omp exits 0 when its input ends; stderr:\n$errors');
  });

  Future<(RpcClient, List<RpcFrame>)> device(String deviceId, int offset, _Inbox inbox) async {
    final client = RpcClient(await _DeviceChannel.open(link, run, offset, inbox), deviceId: deviceId);
    clients.add(client);
    final frames = <RpcFrame>[];
    client.frames.listen(frames.add);
    return (client, frames);
  }

  test('two devices share one detached omp: each gets its own answers and sees the other’s', () async {
    final inbox = _Inbox(File('$run/in.jsonl'));
    final (phone, phoneFrames) = await device('phone', 0, inbox);
    await phone.start().timeout(const Duration(seconds: 60));
    final sessionId = (await phone.getState()).sessionId;

    // The desk joins mid-stream at a line boundary, as a device with a stored offset does.
    final bytes = await File('$run/out.jsonl').readAsBytes();
    final (desk, deskFrames) = await device('desk', bytes.lastIndexOf(10) + 1, inbox);
    await desk.attach().timeout(const Duration(seconds: 30));
    expect(deskFrames.whereType<ReadyFrame>(), isEmpty);

    final answers = await Future.wait([
      phone.getState().then((state) => state.sessionId),
      desk.getState().then((state) => state.sessionId),
      phone.getAvailableThinkingLevels().then((levels) => levels.join()),
      desk.getAvailableThinkingLevels().then((levels) => levels.join()),
      desk.getLastAssistantText().then((text) => '$text'),
    ]);
    expect(answers.sublist(0, 2), [sessionId, sessionId]);
    expect(answers[2], answers[3]);

    // The desk's answer is chunked; the phone reassembles it too and leaves it uncorrelated.
    final seenByPhone = phone.frames.firstWhere((frame) => frame is ResponseFrame && frame.command == 'set_todos');
    final content = 'shared ✓ ' * 200000;
    final phases = await desk.setTodos([
      {
        'name': 'Shared',
        'tasks': [
          {'content': content, 'status': 'pending'},
        ],
      },
    ]);
    expect(((phases.single['tasks']! as List<Object?>).single! as Map<String, Object?>)['content'], content);
    final echoed = await seenByPhone.timeout(const Duration(seconds: 10)) as ResponseFrame;
    expect(echoed.id, startsWith('desk:'));
    expect(phoneFrames.whereType<ResponseFrame>().map((frame) => frame.id), containsAll([echoed.id, startsWith('phone:')]));
  });
}
