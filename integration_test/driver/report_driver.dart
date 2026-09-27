import 'package:integration_test/integration_test_driver.dart';

/// Host side of `flutter drive`: writes what a test reports (`binding.reportData`) to
/// `build/integration_response_data.json`.
Future<void> main() => integrationDriver();
