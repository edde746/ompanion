import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ompanion/database/app_database.dart';
import 'package:ompanion/i18n/strings.g.dart';
import 'package:ompanion/providers/keys_provider.dart';
import 'package:ompanion/providers/machines_provider.dart';
import 'package:ompanion/providers/shell_provider.dart';
import 'package:ompanion/screens/machines/machine_editor.dart';
import 'package:ompanion/services/secret_store.dart';
import 'package:ompanion/widgets/app_select.dart';
import 'package:ompanion/widgets/labeled_field.dart';
import 'package:provider/provider.dart';

void main() {
  late AppDatabase db;
  late SecretStore secrets;
  late MachinesProvider machines;

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    db = AppDatabase(NativeDatabase.memory());
    secrets = SecretStore();
    machines = MachinesProvider(db, secrets);
  });

  /// The app's providers, with a fresh [KeysProvider] that nothing has read yet, and a button that opens the
  /// editor for a new machine.
  Future<void> pumpApp(WidgetTester tester) async {
    // The database opens on the real event loop, which the fake clock's pumps do not run.
    await tester.runAsync(() => db.select(db.machines).get());
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          Provider.value(value: secrets),
          ChangeNotifierProvider.value(value: machines),
          ChangeNotifierProvider(create: (_) => KeysProvider(db, secrets)),
          ChangeNotifierProvider(create: (_) => ShellProvider()),
        ],
        child: TranslationProvider(
          child: MaterialApp(
            home: Scaffold(
              body: Builder(
                builder: (context) => TextButton(onPressed: () => showMachineEditor(context), child: const Text('add')),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('add'));
    await tester.pumpAndSettle();
    // "This computer" is offered first on a desktop without one.
    if (find.text('SSH').evaluate().isNotEmpty) {
      await tester.tap(find.text('SSH'));
      await tester.pumpAndSettle();
    }
  }

  Future<void> tearDownApp(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    // The disposed KeysProvider's drift query ends on a timer of the fake clock; db.close() waits for it.
    await tester.pump(const Duration(seconds: 1));
    await tester.runAsync(() async {
      machines.dispose();
      await db.close();
    });
  }

  Finder field(String label) => find.descendant(of: find.widgetWithText(LabeledField, label), matching: find.byType(TextFormField));

  testWidgets('a new machine uses key auth when keys are stored', (tester) async {
    await tester.runAsync(
      () => db
          .into(db.sshKeys)
          .insert(
            SshKeyRow(
              id: 'k',
              name: 'laptop',
              type: 'ssh-ed25519',
              publicKey: 'ssh-ed25519 AAAA laptop',
              fingerprint: 'SHA256:k',
              createdAt: DateTime(2026),
            ),
          ),
    );
    await pumpApp(tester);

    final auth = tester.widget<AppSelect<AuthMethod>>(find.byType(AppSelect<AuthMethod>));
    expect(auth.value, AuthMethod.key);
    await tearDownApp(tester);
  });

  testWidgets('Save checks every hop, also those scrolled out of view', (tester) async {
    await pumpApp(tester);
    final form = find.descendant(of: find.byType(MachineEditor), matching: find.byType(Scrollable)).first;
    Future<void> reveal(Finder finder, {bool up = false}) async {
      await tester.scrollUntilVisible(finder, up ? -200 : 200, scrollable: form);
      await tester.pumpAndSettle();
    }

    await tester.enterText(field('Name'), 'box');
    await tester.enterText(field('Host'), 'box.example');
    await tester.enterText(field('User'), 'me');
    for (var i = 0; i < 2; i++) {
      await reveal(find.text('Add jump host'));
      await tester.tap(find.text('Add jump host'));
      await tester.pumpAndSettle();
    }
    Finder jump(int n, String label) => find.descendant(
      of: find.ancestor(of: find.text('Jump host $n'), matching: find.byType(Card)),
      matching: field(label),
    );
    await reveal(jump(1, 'User'));
    await tester.enterText(jump(1, 'Host'), 'relay.example');
    await tester.enterText(jump(1, 'User'), 'me');
    // The second jump host: no host, no user, a port that is no number.
    await reveal(jump(2, 'Port'));
    await tester.enterText(jump(2, 'Port'), 'x');
    await reveal(field('Name').hitTestable(), up: true);
    await tester.tap(field('Name'));
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();

    // The second jump host's port was checked and is shown to the user.
    expect(jump(2, 'Port').hitTestable(), findsOneWidget);
    expect(find.text('Between 1 and 65535'), findsOneWidget);
    expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Save')).onPressed, isNotNull);
    expect(await tester.runAsync(() => db.select(db.machines).get()), isEmpty);
    await tearDownApp(tester);
  });
}
