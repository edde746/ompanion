import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ompanion/app/theme.dart';
import 'package:ompanion/i18n/strings.g.dart';
import 'package:ompanion/screens/settings/about_section.dart';
import 'package:package_info_plus/package_info_plus.dart';

void main() {
  const channel = MethodChannel('plugins.flutter.io/url_launcher');
  late List<String> launched;

  setUp(() {
    launched = [];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'launch') launched.add((call.arguments as Map<Object?, Object?>)['url']! as String);
      return true;
    });
    // ignore: invalid_use_of_visible_for_testing_member
    PackageInfo.setMockInitialValues(
      appName: 'ompanion',
      packageName: 'com.edde746.ompanion',
      version: '0.1.0',
      buildNumber: '1',
      buildSignature: '',
    );
  });

  tearDown(
    () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null),
  );

  Future<void> pumpAbout(WidgetTester tester) async {
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          theme: appTheme(Brightness.dark),
          // The settings pane's own padding, so the phone test measures the width the app gives the section.
          home: const Scaffold(
            body: SingleChildScrollView(padding: EdgeInsets.all(24), child: AboutSection()),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('shows the app mark, its name and the version the platform reports', (tester) async {
    await pumpAbout(tester);

    expect(find.text('ompanion'), findsOneWidget);
    expect(find.image(const AssetImage('assets/ompanion.png')), findsOneWidget);
    expect(find.text('Version 0.1.0 (build 1)'), findsOneWidget);
  });

  testWidgets('drops the build number on a platform that reports none', (tester) async {
    // ignore: invalid_use_of_visible_for_testing_member
    PackageInfo.setMockInitialValues(
      appName: 'ompanion',
      packageName: 'com.edde746.ompanion',
      version: '0.1.0',
      buildNumber: '',
      buildSignature: '',
    );
    await pumpAbout(tester);

    expect(find.text('Version 0.1.0'), findsOneWidget);
  });

  testWidgets('every link hands its URL to the launcher', (tester) async {
    await pumpAbout(tester);

    const expected = {
      'A client for omp, the oh-my-pi coding agent': 'https://github.com/can1357/oh-my-pi',
      'Privacy policy': 'https://github.com/edde746/ompanion/blob/main/store/privacy-policy.md',
      'Source code': 'https://github.com/edde746/ompanion',
      'Report an issue': 'https://github.com/edde746/ompanion/issues',
      'License': 'https://github.com/edde746/ompanion/blob/main/LICENSE-EXCEPTION.md',
    };
    for (final MapEntry(key: label, value: url) in expected.entries) {
      await tester.tap(find.text(label));
      await tester.pumpAndSettle();
      expect(launched, [url], reason: label);
      launched.clear();
    }

    expect(find.text('GPL-3.0 with an app-store exception'), findsOneWidget);
  });

  testWidgets('open-source licenses opens the license page of the bundled packages', (tester) async {
    await pumpAbout(tester);

    await tester.tap(find.text('Open-source licenses'));
    await tester.pumpAndSettle();

    expect(find.byType(LicensePage), findsOneWidget);
    expect(launched, isEmpty);
  });

  testWidgets('a phone keeps every label whole', (tester) async {
    // The client line and the licence value wrap at this width; the rows grow instead of cutting them, so
    // pumping the section throws no overflow.
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await pumpAbout(tester);

    expect(find.text('A client for omp, the oh-my-pi coding agent'), findsOneWidget);
    expect(find.text('GPL-3.0 with an app-store exception'), findsOneWidget);
    expect(find.text('Report an issue'), findsOneWidget);
    // The client line wraps over more than one line box here, and the row grew with it: a fixed-height row
    // would have thrown an overflow instead.
    expect(tester.getSize(find.text('A client for omp, the oh-my-pi coding agent')).height, greaterThan(20));
  });
}
