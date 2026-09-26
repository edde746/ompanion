import 'package:drift/native.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ompanion/database/app_database.dart';
import 'package:ompanion/models/machine.dart';
import 'package:ompanion/services/known_hosts_store.dart';
import 'package:ompanion/services/machine_connector.dart';
import 'package:ompanion/services/secret_store.dart';
import 'package:omp_core/session.dart' show PermanentConnectFailure;
import 'package:omp_core/ssh.dart';

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
    passphrase: (_) async => null,
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

  group('identity file passphrases', () {
    final key = generateEd25519Key().publicKey;
    KeyPassphraseRequest request({bool wrong = false}) =>
        KeyPassphraseRequest(hop: 'me@box.example', path: '~/.ssh/id_ed25519', publicKey: key, wrong: wrong);

    test('a passphrase is kept only when the user asks to, and then used without asking', () async {
      final secrets = SecretStore();
      var asked = 0;
      KeyPassphraseHandler answering(bool remember) => keptPassphrases(secrets, (_) async {
        asked++;
        return (passphrase: 'secret', remember: remember);
      });

      expect(await answering(false)(request()), 'secret');
      expect(await secrets.keyFilePassphrase(key.fingerprint), isNull);
      expect(await answering(true)(request()), 'secret');
      expect(await answering(true)(request()), 'secret');
      expect(asked, 2);
    });

    test('a kept passphrase that no longer decrypts the key is forgotten, and the user is asked', () async {
      final secrets = SecretStore();
      await secrets.saveKeyFilePassphrase(key.fingerprint, 'old');
      final asked = <bool>[];
      final passphrases = keptPassphrases(secrets, (request) async {
        asked.add(request.wrong);
        return (passphrase: 'new', remember: false);
      });

      expect(await passphrases(request()), 'old');
      expect(await passphrases(request(wrong: true)), 'new');
      expect(asked, [true]);
      expect(await secrets.keyFilePassphrase(key.fingerprint), isNull);
    });

    test('dismissing the prompt cancels the connection for good', () async {
      await expectLater(
        keptPassphrases(SecretStore(), (_) async => null)(request()),
        throwsA(isA<ConnectCancelled>().having((e) => e, 'marker', isA<PermanentConnectFailure>())),
      );
    });
  });
}
