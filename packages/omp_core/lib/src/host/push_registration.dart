import 'dart:convert';

import '../transport/host_link.dart';
import 'scripts.dart';

/// Where a machine's companion posts phone notifications (docs/contracts/push.md, "Relay").
const pushRelayUrl = 'https://push.ompanion.app/v1/send';

/// What a notification is about. The companion also sends `test`, which no registration lists.
enum NotificationKind { input, done, failed }

enum PushPlatform { android, ios }

/// A phone's registration file on one machine, `<home>/.ompanion/push/<deviceId>.json` (docs/contracts/push.md,
/// "Registration file").
final class PushRegistration {
  PushRegistration({
    required this.deviceId,
    required this.machineId,
    required this.machineName,
    required this.platform,
    required this.fid,
    required this.key,
    required this.kinds,
  }) {
    if (!_deviceIdPattern.hasMatch(deviceId)) throw ArgumentError.value(deviceId, 'deviceId', 'not 32 lowercase hex');
  }

  /// The app's device id, which names the file.
  final String deviceId;
  final String machineId;
  final String machineName;
  final PushPlatform platform;

  /// The phone's Firebase installation ID, registered for messaging.
  final String fid;

  /// Base64 of the 32-byte AES-256-GCM key.
  final String key;
  final Set<NotificationKind> kinds;

  /// The file's bytes: the contract's fields in the contract's order, so an unchanged registration encodes to the
  /// same bytes and is not written again.
  List<int> encode() {
    final json = {
      'v': 1,
      'deviceId': deviceId,
      'machineId': machineId,
      'machineName': machineName,
      'platform': platform.name,
      'fid': fid,
      'key': key,
      'kinds': [
        for (final kind in NotificationKind.values)
          if (kinds.contains(kind)) kind.name,
      ],
      'relay': pushRelayUrl,
    };
    return utf8.encode('${jsonEncode(json)}\n');
  }
}

final _deviceIdPattern = RegExp(r'^[0-9a-f]{32}$');

/// Puts [registration] on the machine: mode 0600 in a 0700 directory, through a temporary name so the companion never
/// reads half a file. A file with the same bytes is left alone. The temporary file holds the key, so a failed write
/// removes it; one a lost link leaves behind goes with [removePushRegistration].
Future<void> writePushRegistration(HostLink link, PushRegistration registration) async {
  final bytes = registration.encode();
  final files = await link.files();
  try {
    final dir = await ensureAppDir(files, _pushDir);
    final path = '$dir/${registration.deviceId}.json';
    final existing = await files.stat(path, followLinks: false);
    if (existing != null && existing.size == bytes.length && _equal(await files.read(path), bytes)) return;
    // Not `.json`: the companion reads every `push/*.json`.
    final temp = '$dir/${registration.deviceId}.${newMarker()}.part';
    try {
      await files.write(temp, bytes, mode: 0x180);
      await _replace(files, temp, path);
    } on Object {
      await _removeIfPresent(files, temp);
      rethrow;
    }
  } finally {
    await files.close();
  }
}

/// Deletes the registration of [deviceId] from the machine, and temporary files an interrupted write left; none there
/// is not an error.
Future<void> removePushRegistration(HostLink link, String deviceId) async {
  if (!_deviceIdPattern.hasMatch(deviceId)) throw ArgumentError.value(deviceId, 'deviceId', 'not 32 lowercase hex');
  final files = await link.files();
  try {
    final dir = '${await files.home()}/$appDirName/$_pushDir';
    if (await files.stat(dir) == null) return;
    for (final HostDirEntry(:name) in await files.list(dir)) {
      if (name == '$deviceId.json' || (name.startsWith('$deviceId.') && name.endsWith('.part'))) {
        await _removeIfPresent(files, '$dir/$name');
      }
    }
  } finally {
    await files.close();
  }
}

/// Moves [temp] over [path]. dartssh2 renames with `posix-rename@openssh.com`, which replaces [path] atomically, when
/// the server offers it, and dart:io's rename replaces too; plain SFTP rename refuses an existing target, which is then
/// removed first. The companion may delete [path] at any moment (a `410` from the relay).
Future<void> _replace(HostFiles files, String temp, String path) async {
  try {
    await files.rename(temp, path);
    return;
  } on Object {
    if (await files.stat(path, followLinks: false) == null) rethrow;
  }
  await _removeIfPresent(files, path);
  await files.rename(temp, path);
}

/// Removes [path]; one that is gone already is fine.
Future<void> _removeIfPresent(HostFiles files, String path) async {
  try {
    await files.remove(path);
  } on Object {
    if (await files.stat(path, followLinks: false) != null) rethrow;
  }
}

const _pushDir = 'push';

bool _equal(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
