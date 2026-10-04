import '../transport/host_link.dart';
import 'scripts.dart';

/// `~/.ompanion/keep-awake`: while it exists, the companion in each of the machine's runs holds a Mac awake while omp
/// works (docs/contracts/host-launch.md, "Keep awake"). One switch per machine, shared by every device.
const _keepAwakeName = 'keep-awake';

/// Whether the machine's keep-awake file exists.
Future<bool> keepAwake(HostLink link) async {
  final files = await link.files();
  try {
    return await files.stat('${await files.home()}/$appDirName/$_keepAwakeName', followLinks: false) != null;
  } finally {
    await files.close();
  }
}

/// Creates the machine's keep-awake file, or removes it; one already in the asked state is left alone. Runs read it
/// when omp starts to work and, while they hold the machine awake, every few seconds.
Future<void> setKeepAwake(HostLink link, bool on) async {
  final files = await link.files();
  try {
    final dir = await ensureAppDir(files, '');
    final path = '$dir/$_keepAwakeName';
    final exists = await files.stat(path, followLinks: false) != null;
    if (on && !exists) await files.write(path, const [], mode: 0x180);
    if (!on && exists) await files.remove(path);
  } finally {
    await files.close();
  }
}
