import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omp_app/database/app_database.dart';
import 'package:omp_app/i18n/strings.g.dart';
import 'package:omp_app/models/machine.dart';
import 'package:omp_app/providers/machines_provider.dart';
import 'package:omp_app/screens/machines/connect_dialogs.dart';
import 'package:omp_app/screens/shell/connect_prompt_host.dart';
import 'package:omp_app/services/known_hosts_store.dart';
import 'package:omp_app/services/machine_connector.dart';
import 'package:omp_app/services/secret_store.dart';
import 'package:omp_app/sessions/sessions_provider.dart';
import 'package:provider/provider.dart';

final _machine = SshMachine(
  id: 'm1',
  name: 'box',
  createdAt: DateTime(2026),
  updatedAt: DateTime(2026),
  target: const SshEndpoint(id: 'm1', host: 'box.example', user: 'me', auth: AuthMethod.password),
);

void main() {
  late AppDatabase db;
  late MachinesProvider machines;
  late SessionsProvider sessions;

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    db = AppDatabase(NativeDatabase.memory());
    final secrets = SecretStore();
    machines = MachinesProvider(db, secrets);
    sessions = SessionsProvider(
      connector: MachineConnector(secrets, KnownHostsStore(db)),
      machines: machines,
      deviceId: 'test',
      companionBytes: (_) async => const [],
    );
  });

  Future<void> pumpHost(WidgetTester tester) async {
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(() async {
        machines.dispose();
        await db.close();
      });
    });
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: sessions,
        child: TranslationProvider(
          child: const MaterialApp(home: ConnectPromptHost(child: SizedBox())),
        ),
      ),
    );
  }

  testWidgets('a password prompt cancelled while it shows closes its dialog', (tester) async {
    await pumpHost(tester);
    final password = sessions.prompts.promptsFor(_machine).password(_machine.target);
    await tester.pumpAndSettle();
    expect(find.byType(PasswordDialog), findsOneWidget);

    // The machine was deleted.
    sessions.prompts.cancelFor(_machine.id);
    await tester.pumpAndSettle();
    expect(find.byType(PasswordDialog), findsNothing);
    expect(await password, isNull);
  });

  testWidgets("a retry's identical question replaces the dialog and gets the answer", (tester) async {
    await pumpHost(tester);
    final prompts = sessions.prompts.promptsFor(_machine);
    final first = prompts.password(_machine.target);
    await tester.pumpAndSettle();
    final retry = prompts.password(_machine.target);
    String? answer;
    unawaited(retry.then((value) => answer = value));
    await tester.pumpAndSettle();
    expect(await first, isNull);
    expect(find.byType(PasswordDialog), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'secret');
    await tester.tap(find.widgetWithText(FilledButton, 'Continue'));
    await tester.pumpAndSettle();
    expect(answer, 'secret');
    expect(find.byType(PasswordDialog), findsNothing);
  });
}
