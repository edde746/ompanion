import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omp_app/config/config_target.dart';
import 'package:omp_app/screens/config/roles_page.dart';
import 'package:omp_core/session.dart';

import '../../config/fake_machine.dart';

void main() {
  testWidgets('closing the page before the control process answers leaves no listener behind', (tester) async {
    final roles = jsonDecode(File('test/config/fixtures/roles-get.json').readAsStringSync());
    final control = FakeSession(reply: (verb, _) => verb == 'roles.get' ? roles : throw StateError('unexpected $verb'));
    await control.attach();
    final started = Completer<LiveSession>();
    final sessions = FakeSessions(testMachine)..onControl = () => started.future;
    await tester.pumpWidget(configHost(RolesPage(target: ConfigTarget(machine: testMachine, sessions: sessions))));
    await tester.pumpWidget(const SizedBox());

    started.complete(control);
    await tester.pump();
    control.omp.emit({'kind': 'event', 'event': 'roles.changed', 'data': roles});
    await tester.pump();
  });
}
