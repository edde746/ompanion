import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// The companion extension the app uploads to every machine (docs/PLAN.md §6). A build artifact:
/// `scripts/build_companion.sh` builds `companion/` and copies the bundle here before `flutter build`.
const companionAsset = 'assets/companion/ompx.js';

/// The companion bundle is not in this build.
final class CompanionMissing implements Exception {
  const CompanionMissing();

  @override
  String toString() => 'This build has no companion ($companionAsset). Run scripts/build_companion.sh, then rebuild the app.';
}

/// The bundled companion for a machine running omp [ompVersion]. One build serves every supported omp
/// release (18.3.1 onward); the companion feature-checks what it uses. Throws [CompanionMissing], which the
/// machine runtime reports as its status.
Future<List<int>> bundledCompanion(String ompVersion) async {
  final ByteData data;
  try {
    data = await rootBundle.load(companionAsset);
  } on FlutterError {
    throw const CompanionMissing();
  }
  if (data.lengthInBytes == 0) throw const CompanionMissing();
  return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
}
