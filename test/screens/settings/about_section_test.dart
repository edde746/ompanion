import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ompanion/app/theme.dart';
import 'package:ompanion/i18n/strings.g.dart';
import 'package:ompanion/screens/settings/about_section.dart';
import 'package:package_info_plus/package_info_plus.dart';

void main() {
  testWidgets('a phone keeps every label whole', (tester) async {
    // ignore: invalid_use_of_visible_for_testing_member
    PackageInfo.setMockInitialValues(
      appName: 'ompanion',
      packageName: 'com.edde746.ompanion',
      version: '0.1.0',
      buildNumber: '1',
      buildSignature: '',
    );
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          theme: appTheme(Brightness.dark),
          // The settings pane's own padding, so the section gets the width the app gives it.
          home: const Scaffold(
            body: SingleChildScrollView(padding: EdgeInsets.all(24), child: AboutSection()),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // The client line wraps over more than one line box at this width, and its row grew with it: a fixed-height
    // row would have cut it and thrown an overflow.
    expect(tester.getSize(find.text('A client for omp, the oh-my-pi coding agent')).height, greaterThan(20));
  });
}
