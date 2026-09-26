import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ompanion/config/config_target.dart';
import 'package:ompanion/config/config_yaml.dart';
import 'package:ompanion/screens/config/settings_page.dart';
import 'package:omp_core/session.dart';

import '../../config/fake_machine.dart';

Map<String, Object?> _switch(String path, String label) => {
  'path': path,
  'type': 'boolean',
  'default': false,
  'isCredential': false,
  'ui': {'tab': 'general', 'label': label, 'description': ''},
};

final _values = {
  'settings': [
    for (final path in ['alpha.enabled', 'beta.enabled']) {'path': path, 'provenance': 'default', 'value': false},
  ],
  'conditions': <String, Object?>{},
};

Object? _replies(String verb, Map<String, Object?> args) => switch (verb) {
  'settings.schema' => {
    'tabs': ['general'],
    'settings': [_switch('alpha.enabled', 'Alpha'), _switch('beta.enabled', 'Beta')],
    'conditions': <String, Object?>{},
  },
  'settings.get' => _values,
  _ => throw StateError('unexpected $verb'),
};

Finder _switchOf(String rowKey) => find.descendant(of: find.byKey(ValueKey(rowKey)), matching: find.byType(Switch));

void main() {
  late MemoryFiles files;
  late MachineRuntime runtime;
  late FakeSession control;
  late FakeSessions sessions;

  Future<void> pumpPage(WidgetTester tester, {LiveSession? project}) async {
    files = MemoryFiles();
    runtime = await probedRuntime(FakeLink(files));
    control = FakeSession(reply: _replies);
    await control.attach();
    sessions = FakeSessions(testMachine, runtime)
      ..onControl = (() async => control)
      ..activeSession = project;
    await tester.pumpWidget(configHost(SettingsPage(target: ConfigTarget(machine: testMachine, sessions: sessions))));
    await tester.pump();
  }

  testWidgets('project edits made one after another all reach .omp/config.yml', (tester) async {
    final project = FakeSession(cwd: '/work/p', runId: 'run', reply: _replies);
    await project.attach();
    await pumpPage(tester, project: project);
    await tester.tap(find.text('Project'));
    await tester.pump();

    // The first edit's write is still on its way when the second edit starts.
    files.writeGate = Completer();
    await tester.tap(_switchOf('project:alpha.enabled'));
    await tester.pump();
    await tester.tap(_switchOf('project:beta.enabled'));
    await tester.pump();
    files.writeGate!.complete();
    await tester.pump();

    final written = ConfigLayer.parse(files.texts['/work/p/.omp/config.yml']!);
    expect(written.lookup(['alpha', 'enabled'])?.value, isTrue);
    expect(written.lookup(['beta', 'enabled'])?.value, isTrue);
    await runtime.dispose();
  });

  testWidgets('a reload that ends after the page closed leaves no listener behind', (tester) async {
    await pumpPage(tester);
    final reload = Completer<LiveSession>();
    sessions.onControl = () => reload.future;
    await tester.tap(find.byTooltip('Refresh'));
    await tester.pump();
    await tester.pumpWidget(const SizedBox());

    reload.complete(control);
    await tester.pump();
    control.omp.emit({'kind': 'event', 'event': 'settings.changed', 'data': _values});
    await tester.pump();
    await runtime.dispose();
  });
}
