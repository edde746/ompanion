/// Captures the App Review path in the real app against a running store/review-demo stack: add the
/// machine with the generated password, trust its host key, see it connect with omp 18.3.1, open a session
/// in the demo project, send a prompt and wait for the demo provider's canned reply. Each step writes a
/// PNG of the app's widget tree (its own RepaintBoundary, so the shot is the app, not the desktop).
///
/// Needs a live stack (store/review-demo/up.sh, then ./reset.sh for a fresh rotation) and the stack's
/// password, from the repository root:
///
///   REVIEW_DEMO_PASSWORD="$(sed -n 's/^REVIEW_PASSWORD=//p' store/review-demo/.env)" \
///     flutter drive --driver=test_driver/integration_test.dart \
///       --target=store/review-demo/verify/capture_test.dart -d macos
///
/// `flutter drive`, not `flutter test`: a `flutter test` run renders the app's text with the test font,
/// which makes the screenshots unreadable.
///
/// REVIEW_DEMO_HOST (127.0.0.1), REVIEW_DEMO_PORT (22222), REVIEW_DEMO_USER (review),
/// REVIEW_DEMO_PROJECT (/data/review/work/notes-api) and REVIEW_DEMO_SHOTS
/// (/tmp/ompanion-store/ReviewDemo) override the rest. The app's own data directory is in memory and its
/// secure storage is mocked, so nothing lands in the keychain and no real machine is touched.
library;

import 'dart:io';
import 'dart:ui' as ui;

import 'package:drift/native.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:omp_core/session.dart' show MachineConnecting, MachineFailed, MachineNeedsOmp, MachineOnline;
import 'package:ompanion/app/app.dart';
import 'package:ompanion/database/app_database.dart';
import 'package:ompanion/screens/machines/machine_editor.dart';
import 'package:ompanion/sessions/machine_images.dart';
import 'package:ompanion/sessions/sessions_provider.dart';
import 'package:ompanion/models/machine.dart';
import 'package:ompanion/providers/machines_provider.dart';
import 'package:ompanion/providers/settings_provider.dart';
import 'package:ompanion/services/secret_store.dart';
import 'package:ompanion/widgets/labeled_field.dart';
import 'package:provider/provider.dart';

const _shot = ValueKey('review-demo-shot');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('the reviewer path: add machine, trust, connect, prompt, reply', (tester) async {
    final environment = Platform.environment;
    final password = environment['REVIEW_DEMO_PASSWORD'];
    if (password == null || password.isEmpty) throw StateError('REVIEW_DEMO_PASSWORD is required');
    final host = environment['REVIEW_DEMO_HOST'] ?? '127.0.0.1';
    final port = environment['REVIEW_DEMO_PORT'] ?? '22222';
    final user = environment['REVIEW_DEMO_USER'] ?? 'review';
    final project = environment['REVIEW_DEMO_PROJECT'] ?? '/data/review/work/notes-api';
    final shots = Directory(environment['REVIEW_DEMO_SHOTS'] ?? '/tmp/ompanion-store/ReviewDemo')
      ..createSync(recursive: true);

    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    // Keeps the reviewer's password out of this Mac's keychain: the app's storage is mocked, as in the
    // widget tests. Nothing this run saves survives it.
    // ignore: invalid_use_of_visible_for_testing_member
    FlutterSecureStorage.setMockInitialValues({});
    final db = AppDatabase(NativeDatabase.memory());
    final secrets = SecretStore();
    final settings = (await tester.runAsync(() => SettingsProvider.load(db)))!;
    await tester.runAsync(() => settings.set(Prefs.deviceId, 'review-demo-capture'));
    final images = MachineImages(cacheDir: machineImageCacheDir);
    final machines = MachinesProvider(db, secrets, images: images);
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(() async {
        machines.dispose();
        await db.close();
      });
    });

    await tester.pumpWidget(
      RepaintBoundary(
        key: _shot,
        child: OmpanionApp(db: db, settings: settings, secrets: secrets, machines: machines, images: images),
      ),
    );
    await tester.pumpAndSettle();

    // 1. Add machine, as the review notes describe it.
    await tester.tap(find.byTooltip('Add machine'));
    await tester.pumpAndSettle();
    if (find.text('SSH').evaluate().isNotEmpty) {
      await tester.tap(find.text('SSH'));
      await tester.pumpAndSettle();
    }
    await tester.enterText(_field('Name'), 'Review demo host');
    await tester.enterText(_field('Host'), host);
    await tester.enterText(_field('Port'), port);
    await tester.enterText(_field('User'), user);
    await tester.tap(
      find.descendant(of: find.widgetWithText(LabeledField, 'Authentication'), matching: find.byType(FilledButton)),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.descendant(of: find.byType(MenuItemButton), matching: find.text('Password')));
    await tester.pumpAndSettle();
    await tester.enterText(_field('Password'), password);
    await tester.pumpAndSettle();
    await _shoot(tester, shots, '1-add-machine');

    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await _pump(tester);

    if (machines.machines.isEmpty) fail('the machine was not saved; on screen: ${_texts(tester)}');
    final machine = machines.machines.single;
    final sessions = Provider.of<SessionsProvider>(tester.element(find.byType(MaterialApp)), listen: false);

    // 2. Saving opens the machine's page. An SSH machine does not dial on its own: the reviewer taps
    // Connect, and the app asks about the host key it has never seen before.
    final connect = find.widgetWithText(FilledButton, 'Connect');
    await _until(tester, () => connect.evaluate().isNotEmpty, what: "the machine page's Connect button");
    await tester.tap(connect);
    await _pump(tester);
    await _until(
      tester,
      () => find.text('Trust this host?').evaluate().isNotEmpty || sessions.runtimeFor(machine).status is MachineOnline,
      what: 'the host key dialog or a connected machine',
      diagnostics: () => _state(tester, sessions, machine),
    );
    if (find.text('Trust this host?').evaluate().isNotEmpty) {
      await _shoot(tester, shots, '2-trust-host');
      await tester.tap(find.widgetWithText(FilledButton, 'Trust'));
      await _pump(tester);
    }

    // 3. Connected: the machine's page lists what the probe found, omp 18.3.1 and the uploaded companion.
    await _until(
      tester,
      () => sessions.runtimeFor(machine).status is MachineOnline,
      what: 'the machine to come online',
      diagnostics: () => _state(tester, sessions, machine),
    );
    await _shoot(tester, shots, '3-connected');

    // 4. A new session in the demo project, then a prompt and the demo's canned reply.
    final row = find.byKey(ValueKey('machine:${machine.id}'));
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    await mouse.moveTo(tester.getCenter(row));
    await _pump(tester);
    await tester.tap(find.byKey(ValueKey('new-session-${machine.id}')));
    await _pump(tester);
    await _until(
      tester,
      () => find.byKey(const ValueKey('new-session-cwd')).evaluate().isNotEmpty,
      what: 'the new session dialog',
    );
    await tester.enterText(find.byKey(const ValueKey('new-session-cwd')), project);
    await _pump(tester);
    final start = find.byKey(const ValueKey('new-session-create'));
    await _until(tester, () => tester.widget<FilledButton>(start).onPressed != null, what: 'the directory check');
    await tester.tap(start);
    await _until(tester, () => find.byKey(const ValueKey('composer')).evaluate().isNotEmpty, what: 'the session');

    await tester.enterText(find.byKey(const ValueKey('composer')), 'Show me what this demo can render.');
    await _pump(tester);
    await tester.tap(find.byKey(const ValueKey('send')));
    await _until(
      tester,
      () =>
          find.byKey(const ValueKey('steer')).evaluate().isNotEmpty ||
          find.byKey(const ValueKey('stop')).evaluate().isNotEmpty,
      what: 'the turn to start',
    );
    await _until(
      tester,
      () =>
          find.byKey(const ValueKey('send')).evaluate().isNotEmpty &&
          find.byKey(const ValueKey('steer')).evaluate().isEmpty &&
          find.byKey(const ValueKey('stop')).evaluate().isEmpty,
      what: 'the answer to finish',
      timeout: const Duration(minutes: 5),
    );
    await _pump(tester);
    await _shoot(tester, shots, '4-chat-reply');

    stdout.writeln('screenshots in ${shots.path}');
  });
}

/// Pumps until [done], letting the real event loop (SSH, SFTP, omp) run in between.
Future<void> _until(
  WidgetTester tester,
  bool Function() done, {
  required String what,
  Duration timeout = const Duration(seconds: 120),
  String Function()? diagnostics,
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!done()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('timed out after ${timeout.inSeconds}s waiting for $what; ${diagnostics?.call() ?? ''}');
    }
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pump();
  }
  await _pump(tester);
}

/// What the app is showing and what the machine's connection is doing, for a timeout message.
String _state(WidgetTester tester, SessionsProvider sessions, Machine machine) {
  final status = switch (sessions.runtimeFor(machine).status) {
    MachineOnline(:final probe) => 'online, omp ${probe.ompVersion}',
    MachineNeedsOmp(:final reason) => 'needs omp: $reason',
    MachineFailed(:final cause) => 'failed: $cause',
    MachineConnecting() => 'connecting',
    _ => 'offline',
  };
  return 'machine $status, listingError=${sessions.listingOf(machine).error}, '
      'editor open=${find.byType(MachineEditor).evaluate().isNotEmpty}, on screen: ${_texts(tester)}';
}

/// The visible Text widgets' contents, for a timeout message.
String _texts(WidgetTester tester) => [
  for (final element in find.byType(Text).evaluate())
    if (element.widget case Text(:final data?) when data.trim().isNotEmpty) data,
].take(24).join(' | ');

/// A few frames, without waiting for animations to settle: the sidebar spinner never settles while a machine
/// connects.
Future<void> _pump(WidgetTester tester) async {
  for (var i = 0; i < 4; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
    await tester.pump(const Duration(milliseconds: 30));
  }
}

Future<void> _shoot(WidgetTester tester, Directory directory, String name) async {
  final boundary = tester.renderObject<RenderRepaintBoundary>(find.byKey(_shot));
  final image = await boundary.toImage(pixelRatio: 1);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  File('${directory.path}/$name.png').writeAsBytesSync(data!.buffer.asUint8List());
  stdout.writeln('shot $name');
}

Finder _field(String label) =>
    find.descendant(of: find.widgetWithText(LabeledField, label), matching: find.byType(TextFormField));
