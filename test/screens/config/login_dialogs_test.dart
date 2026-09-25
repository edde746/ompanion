import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omp_app/config/config_target.dart';
import 'package:omp_app/screens/config/login_dialogs.dart';

import '../../config/fake_machine.dart';

void main() {
  testWidgets('system back ends the pending login as Cancel does', (tester) async {
    final control = FakeSession();
    await control.attach();
    final target = ConfigTarget(machine: testMachine, sessions: FakeSessions(testMachine));
    await tester.pumpWidget(
      configHost(
        Builder(
          builder: (context) => TextButton(
            onPressed: () => showDialog<void>(
              context: context,
              barrierDismissible: false,
              builder: (_) => RpcLoginDialog(target: target, control: control, providerId: 'openai-codex', providerName: 'OpenAI'),
            ),
            child: const Text('log in'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('log in'));
    await tester.pump();
    expect(find.byType(RpcLoginDialog), findsOneWidget);

    // Android's back button.
    await tester.binding.handlePopRoute();
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    expect(control.detached, isTrue);
    expect(find.byType(RpcLoginDialog), findsNothing);
  });
}
