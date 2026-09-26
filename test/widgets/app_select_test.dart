import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ompanion/app/theme.dart';
import 'package:ompanion/widgets/app_select.dart';

void main() {
  testWidgets('shows the current label and reports the chosen option', (tester) async {
    var value = 'high';
    await tester.pumpWidget(
      MaterialApp(
        theme: appTheme(Brightness.light),
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) => AppSelect<String>(
              value: value,
              options: const [('low', 'Low'), ('high', 'High')],
              onChanged: (v) => setState(() => value = v),
            ),
          ),
        ),
      ),
    );
    expect(find.text('High'), findsOneWidget);
    expect(find.text('Low'), findsNothing);

    await tester.tap(find.text('High'));
    await tester.pumpAndSettle();
    final checked = find.ancestor(of: find.byIcon(Icons.check), matching: find.byType(MenuItemButton));
    expect(find.descendant(of: checked, matching: find.text('High')), findsOneWidget);

    await tester.tap(find.text('Low'));
    await tester.pumpAndSettle();
    expect(value, 'low');
    expect(find.text('Low'), findsOneWidget);
    expect(find.text('High'), findsNothing);
  });
}
