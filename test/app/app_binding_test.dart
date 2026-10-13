import 'dart:ui' show ViewFocusDirection, ViewFocusEvent, ViewFocusState;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ompanion/app/app_binding.dart';

final class _Binding extends AutomatedTestWidgetsFlutterBinding with FocusAfterResume {}

void main() {
  _Binding();

  testWidgets('a field keeps its caret when the window gets the focus back before the app resumes, as on Windows', (
    tester,
  ) async {
    final controller = TextEditingController(text: 'hello');
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Material(child: TextField(controller: controller, autofocus: true)),
      ),
    );
    controller.selection = const TextSelection.collapsed(offset: 5);
    ViewFocusEvent focus(ViewFocusState state) =>
        ViewFocusEvent(viewId: tester.view.viewId, state: state, direction: ViewFocusDirection.undefined);

    tester.binding.handleViewFocusChanged(focus(ViewFocusState.unfocused));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    expect(FocusManager.instance.primaryFocus, FocusManager.instance.rootScope);
    tester.binding.handleViewFocusChanged(focus(ViewFocusState.focused));
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();

    expect(tester.state<EditableTextState>(find.byType(EditableText)).widget.focusNode.hasPrimaryFocus, isTrue);
    expect(controller.selection, const TextSelection.collapsed(offset: 5));
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));
}
