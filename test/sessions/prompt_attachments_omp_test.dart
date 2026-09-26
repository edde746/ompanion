@Tags(['omp'])
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ompanion/database/app_database.dart';
import 'package:ompanion/models/machine.dart';
import 'package:ompanion/providers/machines_provider.dart';
import 'package:ompanion/services/known_hosts_store.dart';
import 'package:ompanion/services/machine_connector.dart';
import 'package:ompanion/services/secret_store.dart';
import 'package:ompanion/sessions/composer_attachments.dart';
import 'package:ompanion/sessions/prompt_attachments.dart';
import 'package:ompanion/sessions/sessions_provider.dart';
import 'package:omp_core/channel.dart';
import 'package:omp_core/host.dart';
import 'package:omp_core/rpc.dart';
import 'package:omp_core/session.dart';
import 'package:omp_core/store.dart';
import 'package:omp_core/transport.dart';

/// Tests run from the repository root.
final String _root = Directory.current.path;

final class _Connector extends MachineConnector {
  _Connector(super.secrets, super.knownHosts, this.environment);

  final Map<String, String> environment;

  @override
  Future<HostLink> open(Machine machine, ConnectPrompts prompts) async => LocalLink(environment: environment);

  @override
  bool searchSystemPaths(Machine machine) => false;
}

/// The session's machine seen as another machine: its files go there over [HostFiles], as over SFTP.
final class _Elsewhere implements HostLink {
  _Elsewhere(this._link);

  final LocalLink _link;

  @override
  Future<HostFiles> files() => _link.files();

  @override
  Object? noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _Network extends HttpOverrides {}

final _machine = SshMachine(
  id: 'm1',
  name: 'dev',
  createdAt: DateTime(2026),
  updatedAt: DateTime(2026),
  target: const SshEndpoint(id: 'm1', host: 'dev.example', user: 'me', auth: AuthMethod.agent),
);

/// A 2×2 PNG.
const _png = 'iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAIAAAD91JpzAAAAEUlEQVR4nGP4z8DA8B+MgBgAHfAD/dPQfSYAAAAASUVORK5CYII=';

/// [text] as it appears inside a JSON string.
String _inJson(String text) {
  final encoded = jsonEncode(text);
  return encoded.substring(1, encoded.length - 1);
}

/// omp 18.3.1 against the fake provider: what a prompt with an uploaded file, a paste, a large paste and an image
/// makes omp send to the model.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Process provider;
  late int port;
  late Directory root;
  late Map<String, String> environment;
  late AppDatabase db;
  late MachinesProvider machines;
  late SessionsProvider sessions;

  setUpAll(() async {
    provider = await Process.start('bun', ['$_root/testing/fake-provider/server.ts', '--port', '0']);
    final listening = Completer<int>();
    provider.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen((line) {
      final match = RegExp(r'^listening (\d+)$').firstMatch(line);
      if (match != null && !listening.isCompleted) listening.complete(int.parse(match.group(1)!));
    });
    unawaited(provider.stderr.drain<void>());
    port = await listening.future.timeout(const Duration(seconds: 30));
    root = await Directory.systemTemp.createTemp('ompanion-attachments-omp-');
    final home = '${root.path}/home';
    final result = await Process.run('sh', ['$_root/testing/dev-machine.sh', home, '$port']);
    expect(result.exitCode, 0, reason: '${result.stderr}');
    // The fake models take text only, and omp sends no image to such a model; fake-1 takes images here.
    final models = File('$home/.omp/agent/models.yml');
    models.writeAsStringSync(models.readAsStringSync().replaceFirst('input: [text]', 'input: [text, image]'));
    environment = {
      'HOME': home,
      'PATH': '/usr/bin:/bin:/usr/sbin:/sbin',
      'PI_CODING_AGENT_DIR': '',
      'OMP_PROFILE': '',
      'PI_PROFILE': '',
      'PI_CONFIG_DIR': '',
      'XDG_DATA_HOME': '',
      'XDG_STATE_HOME': '',
      'XDG_CACHE_HOME': '',
    };
    FlutterSecureStorage.setMockInitialValues({});
    db = AppDatabase(NativeDatabase.memory());
    final secrets = SecretStore();
    machines = MachinesProvider(db, secrets);
    sessions = SessionsProvider(
      connector: _Connector(secrets, KnownHostsStore(db), environment),
      machines: machines,
      deviceId: 'test',
      companionBytes: (_) => File('$_root/companion/dist/ompx.js').readAsBytes(),
    );
    await machines.save(_machine);
    for (var i = 0; i < 200 && machines.byId(_machine.id) == null; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
  });

  tearDownAll(() async {
    sessions.dispose();
    machines.dispose();
    await db.close();
    final link = LocalLink(environment: environment);
    final probe = await probeHost(link, searchSystemPaths: false);
    for (final run in await listRuns(link, probe)) {
      if (run.live) await stopRun(link, probe, run, force: true, timeout: const Duration(seconds: 10));
    }
    await link.close();
    provider.kill();
    await provider.exitCode;
    await root.delete(recursive: true);
  });

  Future<List<String>> modelRequests() async {
    // The test binding answers every HttpClient request with 400; the fake provider needs a real one.
    final client = HttpOverrides.runWithHttpOverrides(HttpClient.new, _Network());
    try {
      final request = await client.getUrl(Uri.parse('http://127.0.0.1:$port/control/requests'));
      final body = await (await request.close()).transform(utf8.decoder).join();
      return [for (final recorded in jsonDecode(body) as List<Object?>) jsonEncode((recorded as Map)['body'])];
    } finally {
      client.close();
    }
  }

  test('omp reads the uploaded file, and the model gets it with the pastes and the image', () async {
    final session = await sessions.open(_machine, NewSession('${environment['HOME']}/demo-project'));
    final device = await Directory('${root.path}/device').create();
    final notes = File('${device.path}/release notes.txt')..writeAsStringSync('uploaded body 4b7e\n');
    final big = 'large paste line\n' * 20000;
    final progress = <(int, int)>[];

    final prepared = await preparePrompt(
      text: 'Summarize these.',
      attachments: [
        FileAttachment.path(name: 'release notes.txt', size: 19, path: notes.path),
        const TextAttachment('pasted body 91d0'),
        TextAttachment(big),
        const ImageAttachment(RpcImage(data: _png, mimeType: 'image/png')),
      ],
      session: session,
      link: () async => _Elsewhere(LocalLink(environment: environment)),
      onUploadProgress: (sent, total) => progress.add((sent, total)),
    );

    final local = '${session.sessionPath!.substring(0, session.sessionPath!.length - '.jsonl'.length)}/local';
    final uploaded = '$local/release notes.txt';
    expect(prepared.message, 'Summarize these. @"$uploaded" pasted body 91d0 local://paste-1.md');
    expect(File(uploaded).readAsStringSync(), 'uploaded body 4b7e\n');
    expect(File('$local/paste-1.md').readAsStringSync(), big);
    final total = 19 + utf8.encode(big).length;
    expect(progress.first, (0, total));
    expect(progress.last, (total, total));

    await session.rpc.prompt(prepared.message, images: prepared.images);
    await session.views
        .firstWhere((view) => !view.run.running && view.transcript.any((item) => item is AssistantItem))
        .timeout(const Duration(seconds: 30));

    final request = (await modelRequests()).last;
    // omp wraps a mentioned file as `<file path="…">` with its lines numbered (hashline display).
    expect(request, contains(_inJson('<file path="$uploaded">')));
    expect(request, contains('1:uploaded body 4b7e'));
    // The image follows the message text as image content; omp re-encodes it on the way (image-loading.ts).
    expect(request, contains('${_inJson(prepared.message)}"},{"type":"image_url","image_url":{"url":"data:image/'));
    expect(request, isNot(contains('large paste line')));
    await sessions.stop(session);
  });
}
