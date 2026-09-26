@Tags(['omp'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:omp_core/host.dart';
import 'package:omp_core/session.dart';
import 'package:test/test.dart';

import 'support.dart';

/// A machine where omp finds no usable model refuses rpc mode. The control session comes up in bootstrap mode, and a
/// key stored through it turns the machine into a normal one. Every process runs behind a proxy that forwards
/// nothing, so no request leaves this computer.
void main() {
  test('without a usable model the control runs in bootstrap mode until a key is stored', () async {
    final fake = await FakeProvider.start();
    final proxy = await ProxyRecorder.start();
    final machine = await DevMachine.create(fake.port);
    addTearDown(() async {
      await machine.dispose();
      await proxy.close();
      await fake.stop();
    });
    // The fake provider without a credential: `auth: oauth` needs none in models.yml, and omp has none stored.
    final models = File('${machine.home}/.omp/agent/models.yml');
    models.writeAsStringSync(models.readAsStringSync().replaceFirst('    apiKey: fake-key\n', '    auth: oauth\n'));
    final runtime = machine.runtime('device-a', extraEnvironment: proxy.environment);
    addTearDown(runtime.dispose);

    final bootstrap = await runtime.control();
    expect(runtime.controlIsBootstrap, isTrue);
    expect((await bootstrap.rpc.getState()).model?.id, 'MiniMax-M2');
    final settings = await bootstrap.companion.call('settings.get', {
      'paths': ['speech.enabled'],
    });
    expect((settings! as Map<String, Object?>)['settings'], [
      {'path': 'speech.enabled', 'value': false, 'provenance': 'overlay'},
    ]);
    await expectLater(bootstrap.rpc.prompt('Hello?'), throwsStateError, reason: 'no model call in bootstrap mode');
    await expectLater(bootstrap.companion.call('btw', {'prompt': 'Hello?'}), throwsStateError);
    // The provider models.yml configures has no credential, yet the accounts list names it, so the app offers its
    // key field; the placeholder provider is the current one.
    final before = (await bootstrap.companion.call('accounts.list'))! as Map<String, Object?>;
    expect(before['currentProvider'], 'minimax');
    final keyless = (before['providers']! as List<Object?>).cast<Map<String, Object?>>().singleWhere(
      (row) => row['provider'] == 'fake',
    );
    expect([keyless['source'], keyless['credentials']], [null, isEmpty]);

    final files = await runtime.link.files();
    final String keyFile;
    try {
      keyFile = '${await ensureAppDir(files, 'tmp')}/${newMarker()}.secret';
      await files.write(keyFile, utf8.encode('fake-key\n'), mode: 0x180);
    } finally {
      await files.close();
    }
    final stored = await bootstrap.companion.call('accounts.setKey', {'provider': 'fake', 'keyFile': hostPath(keyFile)});
    expect((stored! as Map<String, Object?>)['provider'], 'fake');
    expect(File(hostPath(keyFile)).existsSync(), isFalse, reason: 'the companion deletes the key file');

    final control = await runtime.control();
    expect(control, isNot(same(bootstrap)));
    expect(runtime.controlIsBootstrap, isFalse, reason: 'a new omp found the stored key');
    expect(bootstrap.linkState, isA<LinkClosed>());
    final accounts = (await control.companion.call('accounts.list'))! as Map<String, Object?>;
    final fakeRow = (accounts['providers']! as List<Object?>).cast<Map<String, Object?>>().singleWhere(
      (row) => row['provider'] == 'fake',
    );
    expect((fakeRow['credentials']! as List<Object?>).cast<Map<String, Object?>>().single['type'], 'api_key');

    await fake.enqueue([
      {
        'steps': [
          {'text': 'Answered with the stored key.'},
        ],
      },
    ]);
    final session = await runtime.open(NewSession(machine.project, model: 'fake/fake-1'));
    await session.rpc.prompt('Hello?');
    final done = await viewWhere(session, (view) => idle(view) && answers(view).isNotEmpty);
    expect(answers(done), ['Answered with the stored key.']);
    // omp's startup fetches public model catalogs (kilo, venice, zenmux, …); they came here and were refused.
    expect(proxy.requests, isNotEmpty, reason: 'omp honours the proxy variables');
    expect(proxy.requests.where((request) => request.contains('minimax')), isEmpty);
    expect(proxy.requests.where((request) => !request.startsWith('CONNECT ')), isEmpty, reason: 'only HTTPS, all refused');
  });
}
