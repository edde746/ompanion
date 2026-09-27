// Store screenshots: drives the real app against real SSH machines (the `harness/sshd` target container, the
// second machine through the bastion) with a real omp and the fake provider, and asks the host to photograph
// the screen at each step.
//
//   store/screenshots/capture.sh ios-phone     # simulator, emulator and defines handled for you
//
// By hand:
//
//   flutter drive -d <device> \
//     --driver=integration_test/driver/store_driver.dart \
//     --target=integration_test/store_screenshots_test.dart \
//     --dart-define=OMPANION_SHOT_CLASS=ios-phone \
//     --dart-define=OMPANION_SHOT_KEY_B64=<base64 of .tools/ssh-test/id_ed25519> \
//     --dart-define=OMPANION_SHOT_HOSTKEYS=<host|port|type|base64 blob;…>
//
// Machines, the key and the trusted host keys are seeded through the app's own providers; everything else is
// tapped, typed and swiped. Screenshots come from the host (`integration_test/driver/store_driver.dart`), so the real
// status bar is in the picture. Progress: `<system temp>/ompanion-shots.log` on the device, which is
// `<app data container>/tmp/ompanion-shots.log` on this Mac for a simulator and
// `/data/user/0/com.edde746.ompanion/cache/ompanion-shots.log` for an emulator.
//
// The model output is scripted by `store/screenshots/demo/turns.ts`, which runs beside this test; the prompts
// below must stay in step with the ones there.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:ompanion/app/app.dart';
import 'package:ompanion/database/app_database.dart';
import 'package:ompanion/models/dock_tab.dart';
import 'package:ompanion/models/machine.dart';
import 'package:ompanion/providers/keys_provider.dart';
import 'package:ompanion/providers/machines_provider.dart';
import 'package:ompanion/providers/settings_provider.dart';
import 'package:ompanion/screens/chat/transcript/transcript_view.dart';
import 'package:ompanion/screens/config/machine_config_screen.dart';
import 'package:ompanion/screens/dock/dock_controller.dart';
import 'package:ompanion/screens/dock/tree/tree_tab.dart';
import 'package:ompanion/screens/shell/layout.dart';
import 'package:ompanion/screens/shell/shell_screen.dart';
import 'package:ompanion/sessions/machine_images.dart';
import 'package:ompanion/sessions/sessions_provider.dart';
import 'package:ompanion/services/secret_store.dart';
import 'package:ompanion/widgets/activity_mark.dart';
import 'package:omp_core/session.dart' show MachineOnline;
import 'package:omp_core/ssh.dart' show sha256Fingerprint;
import 'package:provider/provider.dart';

const _shotClass = String.fromEnvironment('OMPANION_SHOT_CLASS', defaultValue: 'ios-phone');
const _keyB64 = String.fromEnvironment('OMPANION_SHOT_KEY_B64');

/// How this device reaches the demo host: `localhost` from an iOS simulator, `10.0.2.2` from an emulator.
const _sshHost = String.fromEnvironment('OMPANION_SHOT_SSH_HOST', defaultValue: 'localhost');
const _hostKeys = String.fromEnvironment('OMPANION_SHOT_HOSTKEYS');

/// Prompt text; `store/screenshots/demo/turns.ts` matches on it.
const _heroPrompt =
    'Add rate limiting to the upload endpoint so one client cannot exhaust the put path, then run the tests.';
const _deployPrompt = 'Rotate the deploy token in deploy.sh and smoke-test the staging deploy.';

const _apiServer = '/home/omp/code/api-server';
const _pipeline = '/home/omp/work/pipeline';

/// Progress, readable from this Mac while the run is going (see the header).
final _logFile = File('${Directory.systemTemp.path}/ompanion-shots.log');

void _log(String message) {
  _logFile.writeAsStringSync('${DateTime.now().toIso8601String()} $message\n', mode: FileMode.append, flush: true);
  // The same line in the app's stdout, which `flutter drive` prints, so a failed run explains itself.
  debugPrint('[shots] $message');
}

/// Every string on screen, for a failed step's own explanation.
void _dumpScreen(WidgetTester tester, String why) {
  final texts = <String>[];
  for (final element in find.byType(Text).evaluate()) {
    final data = (element.widget as Text).data;
    if (data != null && data.trim().isNotEmpty) texts.add(data.trim());
  }
  _log('$why | on screen: ${texts.take(45).join(" ¶ ")}');
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('store screenshots', (tester) async {
    // The tablet classes are composed landscape, so ask for it before anything is rendered.
    if (_shotClass == 'ios-ipad' || _shotClass == 'play-7in' || _shotClass == 'play-10in') {
      await SystemChrome.setPreferredOrientations([DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight]);
      await Future<void>.delayed(const Duration(seconds: 2));
    }
    _log(
      'start $_shotClass (${Platform.operatingSystem} ${tester.view.physicalSize.width.toInt()}x${tester.view.physicalSize.height.toInt()})',
    );
    // Where `_shot` parks its requests. The Android driver cannot know the sandbox path, so it reads it here.
    _log('channel ${Directory.systemTemp.path}/ompanion-shots');

    // The real app graph, as `main()` builds it, with secure storage mocked in memory so no keychain or
    // keystore entry survives the run.
    FlutterSecureStorage.setMockInitialValues({});
    final db = AppDatabase.open();
    final settings = await SettingsProvider.load(db);
    await settings.set(Prefs.themeMode, ThemeMode.dark);
    final secrets = SecretStore();
    final images = MachineImages(cacheDir: machineImageCacheDir);
    final machines = MachinesProvider(db, secrets, images: images);
    final keys = KeysProvider(db, secrets);
    await _seed(machines: machines, keys: keys);

    await tester.pumpWidget(
      OmpanionApp(db: db, settings: settings, secrets: secrets, machines: machines, images: images),
    );
    await tester.pump(const Duration(seconds: 2));

    final devBox = machines.byId('dev-box')!;
    final buildServer = machines.byId('build-server')!;
    final sessions = _provider<SessionsProvider>(tester);
    final dock = _provider<DockController>(tester);

    try {
      // 1. The hero session on dev-box: a finished task with a diff, a test run and an answer.
      await _connect(tester, sessions, devBox, 'dev-box');
      await _newSession(tester, 'dev-box', _apiServer);
      await _send(tester, _heroPrompt);
      await _hideKeyboard(tester);
      // The composer's hint is the run's state: it reads "Steer the running turn" while the agent works and
      // "Message omp" again once the turn is done. The transcript builds rows lazily, so the folded summary is
      // not necessarily in the tree yet.
      await _pumpUntil(
        tester,
        () => find.text('Steer the running turn').evaluate().isNotEmpty,
        timeout: 120,
        what: 'the run to start',
      );
      await _pumpUntil(
        tester,
        () => find.text('Message omp').evaluate().isNotEmpty,
        timeout: 300,
        what: 'the run to settle',
      );
      final transcript = find.byType(TranscriptView);
      for (var attempt = 0; attempt < 10 && !_visible(find.textContaining('tool call')); attempt++) {
        await tester.drag(transcript, const Offset(0, 320));
        await tester.pump(const Duration(milliseconds: 250));
      }
      _log('hero: folded summary found ${_visible(find.textContaining('tool call'))}');
      if (_visible(find.textContaining('tool call'))) {
        await _tap(tester, find.textContaining('tool call').first);
        await _settle(tester);
      }
      await _hideKeyboard(tester);
      // Opening the fold reveals its rows below the row that was tapped, so first go to the end of the
      // transcript, then back up far enough for the edit card and the test run to sit above the answer.
      for (var attempt = 0; attempt < 8 && !_visible(find.textContaining('What changed')); attempt++) {
        await tester.drag(transcript, const Offset(0, -620));
        await tester.pump(const Duration(milliseconds: 200));
      }
      _log('hero: answer on screen ${_visible(find.textContaining('What changed'))}');
      // Photograph the true bottom of the transcript: the answer is the last item and the jump-to-latest
      // button stays hidden, while the end of the card above (the diff or the test run) is still in frame.
      await tester.drag(transcript, const Offset(0, -4000));
      await tester.pump(const Duration(milliseconds: 500));
      _log(
        'hero: answer on screen ${_visible(find.textContaining('What changed'))}, '
        'card above ${_visible(find.textContaining('npm test'))}',
      );
      await _shot(tester, '01-chat');

      // 2. The Agent Hub with the running review subagent, and the todo list it works from.
      dock.show(DockTab.agents);
      await _pumpUntil(
        tester,
        () => find.text('contract').evaluate().isNotEmpty,
        timeout: 60,
        what: 'the subagent roster',
      );
      // Open the agent: its own transcript, next to the roster.
      await _tap(tester, find.text('contract').first);
      await tester.pump(const Duration(seconds: 6));
      _log('agents: roster ${find.textContaining('Agents:').evaluate().isNotEmpty}');
      await _shot(tester, '07-agents');

      // 3. A real SSH terminal on the machine.
      dock.show(DockTab.terminal);
      await _pumpUntil(
        tester,
        () => find.text('New terminal').evaluate().isNotEmpty,
        timeout: 60,
        what: 'the terminal panel',
      );
      // The panels page slides in; a tap that lands during the transition hits the page underneath, so press
      // until the deck holds a terminal.
      for (var attempt = 0; attempt < 8; attempt++) {
        if (find.textContaining('No terminal open on').evaluate().isEmpty) break;
        final plus = find.byTooltip('New terminal');
        await _tap(tester, plus.evaluate().isNotEmpty ? plus.first : find.text('New terminal').first);
        await tester.pump(const Duration(seconds: 3));
      }
      await _pumpUntil(
        tester,
        () => find.textContaining('No terminal open on').evaluate().isEmpty,
        timeout: 90,
        what: 'the terminal to open',
      );
      await tester.pump(const Duration(seconds: 6));
      // No _hideKeyboard here: it would take the focus the terminal needs for the key events.
      await _type(tester, 'git status');
      await tester.pump(const Duration(seconds: 4));
      await _shot(tester, '05-terminal');

      // 4. The file the task edited, with its diff against HEAD.
      // Opening a file needs the Files tab's listing over SFTP first, which is occasionally slow on a cold
      // session, so ask again until the editor is there.
      for (var attempt = 0; attempt < 3; attempt++) {
        dock.openFile('$_apiServer/src/routes/upload.ts');
        try {
          await _pumpUntil(
            tester,
            () => find.byIcon(Symbols.difference).evaluate().isNotEmpty,
            timeout: 60,
            what: 'the file editor',
          );
          break;
        } on Object catch (error) {
          _log('the file editor did not appear (attempt ${attempt + 1}): $error');
        }
      }
      await _pumpUntil(
        tester,
        () => find.byIcon(Symbols.difference).evaluate().isNotEmpty,
        timeout: 120,
        what: 'the file editor',
      );
      // The editor and the diff paint their own text, so no finder can read them. The toggle's tooltip does
      // flip, and a reload of the document resets the diff, so keep pressing until it stays on.
      for (var attempt = 0; attempt < 6; attempt++) {
        if (find.byTooltip('Show file').evaluate().isNotEmpty) break;
        await _tap(tester, find.byIcon(Symbols.difference).first);
        await tester.pump(const Duration(milliseconds: 900));
      }
      _log('files: diff on ${find.byTooltip('Show file').evaluate().isNotEmpty}');
      await tester.pump(const Duration(seconds: 1));
      await tester.pump(const Duration(seconds: 2));
      await _shot(tester, '06-files');

      // 5. Machine configuration and the model list the machine serves (neutral names only).
      await _leavePanels(tester);
      await tester.runAsync(() async {
        unawaited(openMachineConfig(tester.element(find.byType(ShellScreen)), devBox));
      });
      await _pumpUntil(
        tester,
        () => find.text('Model roles').evaluate().isNotEmpty,
        timeout: 60,
        what: 'the config screen',
      );
      await _tap(tester, find.text('Model roles'));
      await _pumpUntil(
        tester,
        () => find.textContaining('Fast').evaluate().isNotEmpty,
        timeout: 60,
        what: 'the model roles',
      );
      final setRole = find.byWidgetPredicate(
        (widget) => widget.key is ValueKey<String> && (widget.key! as ValueKey<String>).value.endsWith('-global'),
      );
      if (setRole.evaluate().isNotEmpty) {
        await _tap(tester, setRole.first);
        await _pumpUntil(
          tester,
          () => find.textContaining('Reasoning').evaluate().isNotEmpty,
          timeout: 60,
          what: 'the model picker',
        );
      }
      await _shot(tester, '08-config');
      // The picker is a modal dialog: leave it before touching anything behind it.
      if (find.text('Cancel').evaluate().isNotEmpty) await _tap(tester, find.text('Cancel').first);
      await _settle(tester);
      await _back(tester);
      await _settle(tester);
      _log('back in the chat: ${find.byKey(const ValueKey('composer')).evaluate().isNotEmpty}');

      // 6. The agent's question, inline above the composer.
      // 3. The session tree: branches, labels and compactions of the same session.
      dock.show(DockTab.tree);
      final tree = find.byType(TreeTab);
      await _pumpUntil(
        tester,
        () =>
            find.descendant(of: tree, matching: find.byType(ListView)).evaluate().isNotEmpty &&
            find.descendant(of: tree, matching: find.byType(ActivityMark)).evaluate().isEmpty,
        timeout: 60,
        what: 'the session tree',
      );
      await tester.pump(const Duration(seconds: 1));
      await _shot(tester, '03-tree');
      await _leavePanels(tester);

      // 7. The deploy machine, reached through the bastion: its project asks for approval on every tool call, so
      // the last one stays pending for the picture. If that hop fails, the machine list still gets its shot.
      try {
        await _goHome(tester);
        await _connect(tester, sessions, buildServer, 'build-server');
        await _newSession(tester, 'build-server', _pipeline);
        await _send(tester, '/rename Rotate the deploy token');
        await tester.pump(const Duration(seconds: 3));
        await _send(tester, _deployPrompt);
        await _approveUntil(tester, keep: 'scripts/smoke.sh', timeout: 240);
        await _shot(tester, '02-approval');
      } catch (error) {
        _dumpScreen(tester, 'the deploy machine failed: $error');
        await _goHome(tester);
      }

      // 8. Machines and sessions: both machines, their projects and their sessions. A machine row starts
      // collapsed, and its chevron expands it without selecting the machine (which a phone would navigate to).
      await _goHome(tester);
      for (final machine in [devBox, buildServer]) {
        await tester.runAsync(() => sessions.refresh(machine));
        final chevron = find.descendant(
          of: find.byKey(ValueKey('machine:${machine.id}')),
          matching: find.byIcon(Symbols.chevron_right),
        );
        if (chevron.evaluate().isNotEmpty) await _tap(tester, chevron.first);
      }
      // Project rows hide their sessions the same way, so open whatever is still collapsed.
      for (var attempt = 0; attempt < 6; attempt++) {
        if (find.textContaining('rate limiting').evaluate().isNotEmpty) break;
        final chevron = find.byIcon(Symbols.chevron_right);
        if (chevron.evaluate().isEmpty) break;
        await _tap(tester, chevron.first);
        await tester.pump(const Duration(milliseconds: 300));
      }
      // Leave the hero session working: its slow turn outlives the photograph, so its row keeps its spinner
      // while the deploy session shows that it waits for an answer. Refresh first, so the click is on the
      // sessions that are actually listed after the projects were opened above.
      await tester.runAsync(() => sessions.refresh(devBox));
      await tester.pump(const Duration(seconds: 1));
      final heroRow = find.textContaining('rate limiting');
      if (heroRow.evaluate().isNotEmpty) {
        await _tap(tester, heroRow.first);
        await _settle(tester);
        await _send(tester, 'Run the long check and summarize it.');
        await _goHome(tester);
        // The sidebar lists the run's own state, so give the spinner a frame to appear.
        await tester.pump(const Duration(seconds: 2));
      }
      await tester.pump(const Duration(seconds: 3));
      _log('machines: session rows ${find.textContaining('rate limiting').evaluate().length}');
      await _shot(tester, '04-machines');
    } catch (error) {
      _dumpScreen(tester, 'failed: $error');
      rethrow;
    }

    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() async {
      machines.dispose();
      await db.close();
    });
    _log('end');
  });
}

/// Inserts the SSH key, the machines and their trusted host keys through the app's own APIs.
Future<void> _seed({required MachinesProvider machines, required KeysProvider keys}) async {
  if (_keyB64.isEmpty) throw StateError('OMPANION_SHOT_KEY_B64 is empty; run store/screenshots/capture.sh');
  await keys.ready;
  SshKeyRow? key;
  for (final row in keys.keys) {
    if (row.name == 'store-capture') key = row;
  }
  key ??= await keys.importKey(name: 'store-capture', pem: utf8.decode(base64.decode(_keyB64)));
  final keyId = key.id;

  final now = DateTime.now();
  final trusted = <KnownHostRow>[];
  for (final entry in _hostKeys.split(';')) {
    if (entry.isEmpty) continue;
    final parts = entry.split('|');
    final blob = parts[3];
    trusted.add(
      KnownHostRow(
        host: parts[0],
        port: int.parse(parts[1]),
        keyType: parts[2],
        keyBlob: blob,
        fingerprint: sha256Fingerprint(base64.decode(blob)),
        addedAt: now,
      ),
    );
  }

  await machines.save(
    SshMachine(
      id: 'dev-box',
      name: 'dev-box',
      createdAt: now,
      updatedAt: now,
      target: SshEndpoint(id: 'dev-box', host: _sshHost, port: 22221, user: 'omp', auth: AuthMethod.key, keyId: keyId),
    ),
    hostKeys: trusted,
  );
  // The second machine is the same host reached through the bastion, so the jump chain shows up in its path.
  await machines.save(
    SshMachine(
      id: 'build-server',
      name: 'build-server',
      createdAt: now,
      updatedAt: now,
      target: SshEndpoint(
        id: 'build-server',
        host: 'target',
        port: 22,
        user: 'omp',
        auth: AuthMethod.key,
        keyId: keyId,
      ),
      jumps: [
        SshEndpoint(
          id: 'build-server-jump-0',
          host: _sshHost,
          port: 22220,
          user: 'omp',
          auth: AuthMethod.key,
          keyId: keyId,
        ),
      ],
    ),
    hostKeys: trusted,
  );
}

T _provider<T>(WidgetTester tester) => Provider.of<T>(tester.element(find.byType(ShellScreen)), listen: false);

/// Selects a machine and waits for its probe. A phone shows the machine list as its home page and the new
/// session dialog probes for itself, so only the wide layouts select the machine first.
Future<void> _connect(WidgetTester tester, SessionsProvider sessions, Machine machine, String label) async {
  if (_narrow(tester)) return;
  await _tap(tester, find.byKey(ValueKey('machine:${machine.id}')));
  await _pumpUntil(
    tester,
    () {
      final runtime = sessions.runtimeFor(machine);
      return runtime.status is MachineOnline;
    },
    timeout: 120,
    what: '$label to come online',
  );
  _log('$label online');
}

/// Opens a session in [cwd] on the machine whose sidebar row was just used.
Future<void> _newSession(WidgetTester tester, String machineId, String cwd) async {
  // A pointer shows the row's own add button; a wide layout repeats it in the title bar; a touch screen keeps
  // both behind the row's More menu.
  final direct = find.byKey(ValueKey('new-session-$machineId'));
  final titleBar = find.widgetWithText(TextButton, 'New session');
  if (direct.evaluate().isNotEmpty) {
    await _tap(tester, direct.first);
  } else if (titleBar.evaluate().isNotEmpty) {
    await _tap(tester, titleBar.first);
  } else {
    await _tap(
      tester,
      find.descendant(of: find.byKey(ValueKey('machine:$machineId')), matching: find.byIcon(Symbols.more_horiz)).first,
    );
    await _pumpUntil(
      tester,
      () => find.widgetWithText(MenuItemButton, 'New session').evaluate().isNotEmpty,
      timeout: 30,
      what: 'the machine menu',
    );
    await _tap(tester, find.widgetWithText(MenuItemButton, 'New session').first);
  }
  await _pumpUntil(
    tester,
    () => find.byKey(const ValueKey('new-session-cwd')).evaluate().isNotEmpty,
    timeout: 120,
    what: 'the new session dialog',
  );
  await _enterText(tester, find.byKey(const ValueKey('new-session-cwd')), cwd);
  // Start stays disabled until the dialog has probed the machine, so press it until the chat is up.
  for (var attempt = 0; attempt < 60; attempt++) {
    if (find.byKey(const ValueKey('composer')).evaluate().isNotEmpty) {
      _log('session open in $cwd');
      return;
    }
    final start = find.byKey(const ValueKey('new-session-create'));
    if (start.evaluate().isNotEmpty) await _tap(tester, start.first);
    await tester.pump(const Duration(seconds: 2));
  }
  throw StateError('the session in $cwd never opened');
}

/// Types a prompt into the composer and sends it.
Future<void> _send(WidgetTester tester, String prompt) async {
  await _pumpUntil(
    tester,
    () => find.byKey(const ValueKey('send')).evaluate().isNotEmpty,
    timeout: 60,
    what: 'the composer',
  );
  // A prompt typed while the session is still running becomes a steer; wait for the idle composer's hint.
  await _pumpUntil(
    tester,
    () => find.text('Message omp').evaluate().isNotEmpty,
    timeout: 180,
    what: 'the session to go idle',
  );
  await _enterText(tester, find.byKey(const ValueKey('composer')), prompt);
  await _tap(tester, find.byKey(const ValueKey('send')));
  _log('prompt sent: ${prompt.split(" ").take(4).join(" ")}…');
}

/// Answers every approval whose card does not mention [keep], and leaves that one waiting.
Future<void> _approveUntil(WidgetTester tester, {required String keep, required int timeout}) async {
  final deadline = DateTime.now().add(Duration(seconds: timeout));
  var answered = 0;
  while (DateTime.now().isBefore(deadline)) {
    await tester.pump(const Duration(milliseconds: 200));
    if (find.text('Approve').evaluate().isEmpty) continue;
    if (find.textContaining(keep).evaluate().isNotEmpty) {
      _log('keeping the approval for $keep after $answered answer(s)');
      return;
    }
    await _tap(tester, find.text('Approve').first);
    answered += 1;
    await tester.pump(const Duration(milliseconds: 500));
  }
  throw StateError('no approval for $keep arrived');
}

/// Twice the phone number of taps, once per attempt.
Future<void> _tap(WidgetTester tester, Finder finder) async {
  await tester.tap(finder, warnIfMissed: false);
  await tester.pump(const Duration(milliseconds: 400));
}

/// Pumps frames until [done] holds, the way the widget tests do, but with real time.
Future<void> _pumpUntil(WidgetTester tester, bool Function() done, {required int timeout, required String what}) async {
  final deadline = DateTime.now().add(Duration(seconds: timeout));
  while (DateTime.now().isBefore(deadline)) {
    await tester.pump(const Duration(milliseconds: 120));
    if (done()) return;
  }
  _log('timed out waiting for $what');
  throw StateError('timed out after ${timeout}s waiting for $what');
}

/// Pumps until the app stops scheduling frames, without `pumpAndSettle`'s fixed timeout.
Future<void> _settle(WidgetTester tester, {int timeout = 30}) async {
  final deadline = DateTime.now().add(Duration(seconds: timeout));
  while (DateTime.now().isBefore(deadline)) {
    await tester.pump(const Duration(milliseconds: 100));
    if (!tester.binding.hasScheduledFrame) return;
  }
}

/// Types [text] into the focused terminal through hardware key events.
Future<void> _type(WidgetTester tester, String text) async {
  for (final unit in text.codeUnits) {
    final key = _logicalKey(String.fromCharCode(unit));
    if (key == null) continue;
    await tester.sendKeyEvent(key);
    await tester.pump(const Duration(milliseconds: 40));
  }
  await tester.sendKeyEvent(LogicalKeyboardKey.enter);
}

LogicalKeyboardKey? _logicalKey(String character) {
  const punctuation = {
    ' ': LogicalKeyboardKey.space,
    '-': LogicalKeyboardKey.minus,
    '.': LogicalKeyboardKey.period,
    '/': LogicalKeyboardKey.slash,
    '_': LogicalKeyboardKey.minus,
  };
  if (punctuation.containsKey(character)) return punctuation[character];
  final code = character.toLowerCase().codeUnitAt(0);
  if (code >= 0x61 && code <= 0x7a) return LogicalKeyboardKey(0x61 + code - 0x61);
  if (code >= 0x30 && code <= 0x39) return LogicalKeyboardKey(0x30 + code - 0x30);
  return null;
}

/// Whether a finder matches something the transcript has actually built and laid out.
bool _visible(Finder finder) {
  for (final element in finder.evaluate()) {
    final box = element.renderObject;
    if (box is RenderBox && box.hasSize && box.size.height > 0) return true;
  }
  return false;
}

/// Puts the software keyboard away; a full screen shot with it up loses half the picture.
/// [`WidgetTester.enterText`] with a bound: the platform channel behind it can stall a run.
Future<void> _enterText(WidgetTester tester, Finder finder, String text) async {
  await tester.enterText(finder, text).timeout(const Duration(seconds: 8), onTimeout: () {});
  await tester.pump(const Duration(milliseconds: 200));
}

Future<void> _hideKeyboard(WidgetTester tester) async {
  FocusManager.instance.primaryFocus?.unfocus();
  // A platform channel that never answers would hang the whole run, so the call is bounded.
  await SystemChannels.textInput
      .invokeMethod<void>('TextInput.hide')
      .timeout(const Duration(seconds: 3), onTimeout: () => null);
  await tester.pump(const Duration(milliseconds: 400));
}

/// Asks the host to photograph the screen and waits for it, through a file channel in this app's own temporary
/// directory: `integration_test/driver/store_driver.dart` watches it and runs `xcrun simctl`/`adb` there. A screenshot the
/// app takes itself renders only the Flutter view, without the system status bar.
Future<void> _shot(WidgetTester tester, String name) async {
  await _hideKeyboard(tester);
  final dir = Directory('${Directory.systemTemp.path}/ompanion-shots')..createSync(recursive: true);
  final done = File('${dir.path}/$name.done');
  if (done.existsSync()) done.deleteSync();
  File('${dir.path}/$name.request').writeAsStringSync('go');
  final started = DateTime.now();
  final deadline = started.add(const Duration(seconds: 30));
  while (DateTime.now().isBefore(deadline)) {
    await tester.pump(const Duration(milliseconds: 120));
    if (done.existsSync()) {
      done.deleteSync();
      _log('shot $name (${DateTime.now().difference(started).inMilliseconds} ms)');
      await tester.pump(const Duration(milliseconds: 300));
      return;
    }
  }
  throw StateError('the host never captured $name');
}

bool _narrow(WidgetTester tester) => tester.view.physicalSize.width / tester.view.devicePixelRatio < compactWidthBelow;

/// Leaves the dock: on a phone the panels are a pushed page, on a tablet an inline panel or a drawer.
Future<void> _leavePanels(WidgetTester tester) async {
  if (!_narrow(tester)) return;
  await _back(tester);
}

/// Returns to the machine list.
Future<void> _goHome(WidgetTester tester) async {
  for (var attempt = 0; attempt < 4; attempt++) {
    if (_narrow(tester)) {
      if (find.byTooltip('Add machine').evaluate().isNotEmpty) return;
      await _back(tester);
    } else {
      return;
    }
  }
}

Future<void> _back(WidgetTester tester) async {
  for (final finder in [
    find.byType(BackButton),
    find.byTooltip('Back'),
    find.byIcon(Symbols.arrow_back),
    find.byIcon(Symbols.arrow_back_ios),
    find.byIcon(Symbols.arrow_back_ios_new),
    find.byTooltip('Close'),
  ]) {
    if (finder.evaluate().isEmpty) continue;
    await _tap(tester, finder.first);
    await tester.pump(const Duration(milliseconds: 500));
    return;
  }
  // A pushed route whose app bar offers no back button still pops.
  Navigator.of(tester.element(find.byType(ShellScreen))).pop();
  await tester.pump(const Duration(milliseconds: 600));
}
