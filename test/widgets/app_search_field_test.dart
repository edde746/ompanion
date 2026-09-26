import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ompanion/app/theme.dart';
import 'package:ompanion/widgets/app_search_field.dart';

void main() {
  Future<List<String>> pump(WidgetTester tester, {List<String>? submitted}) async {
    final queries = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        theme: appTheme(Brightness.dark),
        home: Scaffold(
          body: AppSearchField(onChanged: queries.add, onSubmitted: submitted?.add),
        ),
      ),
    );
    return queries;
  }

  testWidgets('filters once typing pauses for the debounce', (tester) async {
    final queries = await pump(tester);
    await tester.enterText(find.byType(TextField), 'gi');
    await tester.pump(const Duration(milliseconds: 100));
    await tester.enterText(find.byType(TextField), 'git');
    await tester.pump(const Duration(milliseconds: 249));
    expect(queries, isEmpty);
    await tester.pump(const Duration(milliseconds: 1));
    expect(queries, ['git']);
  });

  testWidgets('Enter searches at once and does not fire again after the debounce', (tester) async {
    final submitted = <String>[];
    final queries = await pump(tester, submitted: submitted);
    await tester.enterText(find.byType(TextField), 'mcp');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pump();
    expect(queries, ['mcp']);
    expect(submitted, ['mcp']);
    await tester.pump(const Duration(seconds: 1));
    expect(queries, ['mcp']);
  });

  testWidgets('clear empties the query at once', (tester) async {
    final queries = await pump(tester);
    expect(find.byIcon(Icons.close), findsNothing);
    await tester.enterText(find.byType(TextField), 'x');
    await tester.pump();
    await tester.tap(find.byIcon(Icons.close));
    await tester.pump();
    expect(queries, ['']);
    expect(find.byIcon(Icons.close), findsNothing);
    await tester.pump(const Duration(seconds: 1));
    expect(queries, ['']);
  });
}
