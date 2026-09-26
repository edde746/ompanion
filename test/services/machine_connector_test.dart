import 'package:drift/native.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ompanion/database/app_database.dart';
import 'package:ompanion/models/machine.dart';
import 'package:ompanion/services/known_hosts_store.dart';
import 'package:ompanion/services/machine_connector.dart';
import 'package:ompanion/services/secret_store.dart';
import 'package:omp_core/session.dart' show PermanentConnectFailure;

SshMachine _machine(AuthMethod auth, {String? keyId}) => SshMachine(
  id: 'm1',
  name: 'box',
  createdAt: DateTime(2026),
  updatedAt: DateTime(2026),
  target: SshEndpoint(id: 'm1', host: 'box.example', user: 'me', auth: auth, keyId: keyId),
);

void main() {
  late AppDatabase db;
  late MachineConnector connector;

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    db = AppDatabase(NativeDatabase.memory());
    connector = MachineConnector(SecretStore(), KnownHostsStore(db));
  });

  tearDown(() => db.close());

  ConnectPrompts prompts() => ConnectPrompts(
    password: (_) async => null,
    keyboardInteractive: (_) async => null,
    hostKey: (_, _) async => false,
  );

  // A session that reconnects in the background stops on these instead of retrying (and prompting) forever.
  group('failures a retry cannot fix are permanent', () {
    test('the user cancels the password prompt', () async {
      await expectLater(
        connector.open(_machine(AuthMethod.password), prompts()),
        throwsA(isA<ConnectCancelled>().having((e) => e, 'marker', isA<PermanentConnectFailure>())),
      );
    });

    test("the hop's key was deleted from this device", () async {
      await expectLater(
        connector.open(_machine(AuthMethod.key, keyId: 'gone'), prompts()),
        throwsA(isA<MissingCredential>().having((e) => e, 'marker', isA<PermanentConnectFailure>())),
      );
    });
  });
}
