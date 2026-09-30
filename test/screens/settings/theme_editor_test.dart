import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ompanion/app/palette.dart';
import 'package:ompanion/app/theme.dart';
import 'package:ompanion/database/app_database.dart';
import 'package:ompanion/i18n/strings.g.dart';
import 'package:ompanion/providers/settings_provider.dart';
import 'package:ompanion/screens/settings/color_picker.dart';
import 'package:ompanion/screens/settings/theme_editor_screen.dart';
import 'package:provider/provider.dart';

void main() {
  late AppDatabase db;
  late SettingsProvider settings;

  Future<void> pumpEditor(WidgetTester tester) async {
    tester.view.physicalSize = const Size(700, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    db = AppDatabase(NativeDatabase.memory());
    settings = (await tester.runAsync(() => SettingsProvider.load(db)))!;
    await tester.runAsync(() => settings.set(Prefs.customTheme, AppPalette.dark));
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: settings,
        child: TranslationProvider(
          child: MaterialApp(theme: darkAppTheme, home: const ThemeEditorScreen()),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> tearDownEditor(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(db.close);
  }

  final accentRow = find.text('Primary buttons, switches that are on, progress');
  final hexField = find.descendant(of: find.byType(ColorPicker), matching: find.byType(TextField));

  testWidgets('a hex applied in a row is saved; the row and Reset all take picks back', (tester) async {
    await pumpEditor(tester);
    await tester.tap(accentRow);
    await tester.pumpAndSettle();

    await tester.enterText(hexField, '3366ff');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(settings.get(Prefs.customTheme).picks, {ThemeToken.accent: const Color(0xFF3366FF)});

    await tester.enterText(hexField, 'not a colour');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(settings.get(Prefs.customTheme).picks, {ThemeToken.accent: const Color(0xFF3366FF)});
    expect(tester.widget<TextField>(hexField).controller!.text, '#3366FF', reason: 'a bad hex puts the colour back');

    await tester.tap(find.byTooltip('Reset to the base color'));
    await tester.pumpAndSettle();
    expect(settings.get(Prefs.customTheme), AppPalette.dark);

    await tester.enterText(hexField, '#102030');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Reset all'));
    await tester.pumpAndSettle();
    expect(settings.get(Prefs.customTheme), AppPalette.dark);
    await tearDownEditor(tester);
  });

  testWidgets('a vertical drag on the colour area picks a colour instead of scrolling the list', (tester) async {
    await pumpEditor(tester);
    await tester.tap(accentRow);
    await tester.pumpAndSettle();
    final list = tester.state<ScrollableState>(
      find.descendant(of: find.byType(ListView), matching: find.byType(Scrollable)).first,
    );
    final offset = list.position.pixels;
    final area = find.descendant(of: find.byType(ColorPicker), matching: find.byType(CustomPaint)).first;
    final box = tester.getRect(area);

    // From the top right corner (full saturation and value) straight down, the way a list is scrolled.
    await tester.dragFrom(box.topRight + const Offset(-1, 1), const Offset(0, 120));
    await tester.pumpAndSettle();

    expect(list.position.pixels, offset);
    final picked = HSVColor.fromColor(settings.get(Prefs.customTheme)[ThemeToken.accent]);
    expect(picked.saturation, greaterThan(0.95));
    expect(picked.value, closeTo(1 - 121 / box.height, 0.02));
    await tearDownEditor(tester);
  });
}
