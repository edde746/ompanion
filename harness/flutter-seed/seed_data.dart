// The Flutter seed's data set (README.md). main_seed.dart writes it through the Flutter app; fixtures.dart derives
// expected.json and the schema-v1/v2 fixtures from it. Plain Dart without Flutter or app imports, so fixtures.dart runs
// on the Dart VM alone.
//
// Instants are UTC. The app keeps createdAt, updatedAt, addedAt and pinnedAt as local times (main_seed.dart passes
// them through toLocal()) and seenModified in UTC, so the epoch milliseconds do not depend on the machine's zone. The
// private keys and host keys were generated for this fixture and open nothing.
library;

final class SeedKey {
  SeedKey({
    required this.id,
    required this.name,
    required this.type,
    required this.publicKey,
    required this.fingerprint,
    required this.createdAt,
    required this.pem,
    this.passphrase,
  });

  final String id;
  final String name;
  final String type;

  /// The `authorized_keys` line the app derives from [pem] (its comment is the key's own).
  final String publicKey;
  final String fingerprint;
  final DateTime createdAt;
  final String pem;
  final String? passphrase;
}

/// One SSH hop. A target's [id] is its machine's, a jump's its row's: the owner of the hop's saved password.
final class SeedHop {
  const SeedHop({
    required this.id,
    required this.host,
    this.port = 22,
    required this.user,
    required this.auth,
    this.keyId,
  });

  final String id;
  final String host;
  final int port;
  final String user;

  /// An `AuthMethod` name.
  final String auth;
  final String? keyId;
}

final class SeedMachine {
  SeedMachine({
    required this.id,
    required this.name,
    required this.createdAt,
    required this.updatedAt,
    this.target,
    this.jumps = const [],
    this.sshConfigAlias,
    this.tailscale = false,
  });

  final String id;
  final String name;
  final DateTime createdAt;
  final DateTime updatedAt;

  /// Null for this computer.
  final SeedHop? target;

  /// In dial order.
  final List<SeedHop> jumps;
  final String? sshConfigAlias;
  final bool tailscale;
}

final class SeedHostKey {
  SeedHostKey({
    required this.host,
    this.port = 22,
    required this.line,
    required this.fingerprint,
    required this.addedAt,
    this.fromTailnetOf,
  });

  final String host;
  final int port;

  /// `<type> <base64 wire format>`.
  final String line;
  final String fingerprint;
  final DateTime addedAt;

  /// The Tailscale machine whose save trusted the key (from the tailnet's control plane, added at the machine's
  /// createdAt); null for a key the user trusted at a prompt.
  final String? fromTailnetOf;

  String get keyType => line.split(' ')[0];
  String get keyBlob => line.split(' ')[1];
}

final class SeedReadMarker {
  SeedReadMarker({required this.machineId, required this.path, required this.seenModified});

  final String machineId;
  final String path;
  final DateTime seenModified;
}

final class SeedPin {
  SeedPin({
    required this.machineId,
    required this.sessionId,
    required this.path,
    required this.cwd,
    this.title,
    this.firstMessage,
    required this.pinnedAt,
  });

  final String machineId;
  final String sessionId;
  final String path;
  final String cwd;
  final String? title;
  final String? firstMessage;
  final DateTime pinnedAt;
}

const keyMacBook = '0e86cdbfe9fe8179c0b1bc27faf3d87d';
const keyWork = '8433aa4fe2e3281379f134a79f0f5c32';
const keyDeploy = 'b63ddd376055657744d822dcc9f968da';
const machineStudio = 'fc401b40150b4adbcb99269dc6794527';
const machineBuero = 'baa0ce5c31af5f4d4750ed445071822a';
const machineNas = 'df62567e423e5b887214e42af007fecf';
const machineRouter = '4911a8e41d27ca507e7c8e56f8e986c0';
const machinePi = '24a14d1ef2f10a3ea4fe1a0ced45d76a';
const machineArchive = '85c06c10ca5ed7cab0233ef816a69bfa';
const jumpBastion = '7114be72a9a5de5cf989d895a9b58574';
const jumpOps = '19a9c791e3f2193512334b68af76d453';
const jumpGateway = '7f903f8e333080dfd6a59727e71d255e';
const deviceId = '8f9f009f2dc0f866da755c5a317b78ef';

/// In the order the seed stores them.
final seedKeys = [
  SeedKey(
    id: keyMacBook,
    name: 'MacBook ed25519',
    type: 'ssh-ed25519',
    publicKey: 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIE/5XRbJEaQkPuCA4lLhiFW88Pcx4j72hHAiR9mSyN7W MacBook ed25519',
    fingerprint: 'SHA256:hHyLGmYC5EmHyb5iEo02ODXcXIImlX3wu3UvHcYPpao',
    createdAt: DateTime.utc(2025, 11, 3, 8, 14, 22, 531, 407),
    pem: r'''-----BEGIN OPENSSH PRIVATE KEY-----
b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtzc2gtZW
QyNTUxOQAAACBP+V0WyRGkJD7ggOJS4YhVvPD3MeI+9oRwIkfZksje1gAAAJiflISwn5SE
sAAAAAtzc2gtZWQyNTUxOQAAACBP+V0WyRGkJD7ggOJS4YhVvPD3MeI+9oRwIkfZksje1g
AAAEDpF+gTNhOCwky9YUBSiIJ5oaZEgydYyzuAFoZLGwiOlU/5XRbJEaQkPuCA4lLhiFW8
8Pcx4j72hHAiR9mSyN7WAAAAD01hY0Jvb2sgZWQyNTUxOQECAwQFBg==
-----END OPENSSH PRIVATE KEY-----
''',
  ),
  SeedKey(
    id: keyWork,
    name: 'Work laptop',
    type: 'ssh-ed25519',
    publicKey: 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFHdLvJT979jmwvVrUskPLVdbLL2rpCD/WHGn18v6HAP edde@work-laptop',
    fingerprint: 'SHA256:/VLTFlZY3UY8HMIKNKt8XFrcsG5Q7nZKQdz4+1JpvqY',
    createdAt: DateTime.utc(2026, 2, 17, 19, 3, 41, 8, 250),
    pem: r'''-----BEGIN OPENSSH PRIVATE KEY-----
b3BlbnNzaC1rZXktdjEAAAAACmFlczI1Ni1jdHIAAAAGYmNyeXB0AAAAGAAAABDsJ7MUq2
zlkKHVL8KtXFJ7AAAAGAAAAAEAAAAzAAAAC3NzaC1lZDI1NTE5AAAAIFHdLvJT979jmwvV
rUskPLVdbLL2rpCD/WHGn18v6HAPAAAAoBNTsBdm0zduw5gkA7b/7+zVfZi1WP7U4Je99L
VxGs4Rb8O6OrD9Pj++F8EAhCxbFeOBjW+WdXIqtYNNOQwuUU3D3rqbLHNAPC5APjZh13Oa
FvIUBopRbJxioQlqACO0CLDfFFVm26r3S9CZg7qJjOhFCzcKV5YWzjaARy2QdXYMkhDoZX
MxN4QK+nBhKHLS+XbOisKtGfINCLjNEMxEHZA=
-----END OPENSSH PRIVATE KEY-----
''',
    passphrase: 'correct horse battery staple',
  ),
  // Over 2560 bytes: Windows Credential Manager's limit for one value.
  SeedKey(
    id: keyDeploy,
    name: 'deploy RSA 4096',
    type: 'ssh-rsa',
    publicKey: 'ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAACAQC3//haLzXuAdSUOfneySBMhco6iroBjHSydongCrWvPMw83oxbVXtKkllcbuxSe263g/lv0JfZVfLQgHDTIdLeF32wNBULeeoylh3XRyOHCXsn5rbkHShibrYZgjOOeglO3t9rhtIMiPwbW4zmHZpvG/PoUfFT/6qZ3b6lGSBD08ZiqheAN4cLGZkG1wVrwGNAjTm9ZJPDfZWPXs2G8+aO7w4E00eGBeBvfwmz9bv1Sfc5k6V7rYJhLvZZgwKBV5elOViprjI4LD8qnSJp/rPQBmlhniB40z+gqSaG5rS8CQP49Y2H8KzzMRfnO0aF051ia9oWzSyWaR9CcZ8cerazOBX86MsUQoDu5rC+zmUVR5PJQ4QrnJ62SECljupwhSyFKJuBET46QLXE49aeNgSzc0vThwyssVkNBWEcniC7FxbRqmzZDDvA5DJf8zp94znHP4SU17SJ/VdpcA2GVkDTAZcLrfsdDcFf8l7PnzhLraz86LtyMnyFAw/oWVMv5CRAz2OHJzEvVvlFKPRXbG1Q+OU4eIS1cwSb/FlLuxqWjfsc/CRruUnKFhTWn4AjtA26eLj1YbAKyJZKWvzA1Z51LyoTmS3isCiUJ2W3r87uudOd0X35udVVDbQkXQmJoQgWLNUBMHE1AIkqT3IXFyb1NZTAdFYq2RztGpxawqcLTw==',
    fingerprint: 'SHA256:ZdNxDlrdF5p9T7uEjDFGWq647lQMg6T7MIoFL3ulDe4',
    createdAt: DateTime.utc(2026, 4, 2, 6, 55, 9, 770, 1),
    pem: r'''-----BEGIN RSA PRIVATE KEY-----
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
-----END RSA PRIVATE KEY-----
''',
  ),
];

/// In the order the seed saves them.
final seedMachines = [
  SeedMachine(
    id: machineStudio,
    name: 'Studio',
    createdAt: DateTime.utc(2025, 11, 3, 8, 12, 5, 112, 233),
    updatedAt: DateTime.utc(2025, 11, 3, 8, 12, 5, 112, 233),
  ),
  SeedMachine(
    id: machineBuero,
    name: "Büro – Zoë's 服务器",
    createdAt: DateTime.utc(2025, 12, 1, 10),
    updatedAt: DateTime.utc(2026, 7, 21, 22, 47, 13, 999, 999),
    target: const SeedHop(
      id: machineBuero,
      host: 'build.example.org',
      port: 2222,
      user: 'deploy',
      auth: 'key',
      keyId: keyDeploy,
    ),
    jumps: const [
      SeedHop(id: jumpBastion, host: 'bastion.example.org', user: 'jump', auth: 'password'),
      SeedHop(id: jumpOps, host: '10.20.0.5', port: 2200, user: 'ops', auth: 'agent'),
    ],
  ),
  SeedMachine(
    id: machineNas,
    name: 'Home NAS',
    createdAt: DateTime.utc(2026, 1, 9, 15, 30, 12, 345, 678),
    updatedAt: DateTime.utc(2026, 1, 9, 15, 30, 12, 345, 678),
    target: const SeedHop(id: machineNas, host: 'nas.home.arpa', user: 'admin', auth: 'keyboardInteractive'),
    sshConfigAlias: 'nas',
  ),
  // Saved half a second before and after the EU's switch to summer time (01:00 UTC).
  SeedMachine(
    id: machineRouter,
    name: 'Router',
    createdAt: DateTime.utc(2026, 3, 29, 0, 59, 59, 500),
    updatedAt: DateTime.utc(2026, 3, 29, 1, 0, 0, 500),
    target: const SeedHop(id: machineRouter, host: '192.168.1.1', user: 'root', auth: 'password'),
  ),
  SeedMachine(
    id: machinePi,
    name: 'raspberrypi',
    createdAt: DateTime.utc(2026, 6, 15, 18, 20, 31, 42, 137),
    updatedAt: DateTime.utc(2026, 6, 15, 18, 20, 31, 42, 137),
    target: const SeedHop(id: machinePi, host: 'raspberrypi.tail1a2b3c.ts.net', user: 'pi', auth: 'none'),
    tailscale: true,
  ),
  SeedMachine(
    id: machineArchive,
    name: 'Archive',
    createdAt: DateTime.utc(2026, 8, 30, 7, 7, 7, 70, 707),
    updatedAt: DateTime.utc(2026, 10, 26, 11, 11, 11, 111, 111),
    target: const SeedHop(id: machineArchive, host: 'archive.example.net', user: 'edde', auth: 'key', keyId: keyWork),
    jumps: const [SeedHop(id: jumpGateway, host: 'gw.example.net', user: 'edde', auth: 'key', keyId: keyMacBook)],
  ),
];

/// In the order the seed stores them: the tailnet's keys come with their machine's save, before the others.
final seedKnownHosts = [
  SeedHostKey(
    host: 'raspberrypi.tail1a2b3c.ts.net',
    line: 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDEkMInaSBpuvegtS7v56Ht+nLpoHm5q9i2IDPot/u6y',
    fingerprint: 'SHA256:3XAXZrhMqDpHilc11uQagv8IeNRZ+JO+Pr3o9E77MRw',
    addedAt: DateTime.utc(2026, 6, 15, 18, 20, 31, 42, 137),
    fromTailnetOf: machinePi,
  ),
  SeedHostKey(
    host: 'raspberrypi.tail1a2b3c.ts.net',
    line: 'ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBH440N0bIzckwilNLdiyJf0zYzNbHGo17GRrn06u91A/l/ErAEUqJsYsiMetUxGAk+vV3oqe8QlhU4OYdRkaB7Q=',
    fingerprint: 'SHA256:3QgcoEMhUERr35/0mCNCMk8aJ5WOHKlrTlBx8OcVOx8',
    addedAt: DateTime.utc(2026, 6, 15, 18, 20, 31, 42, 137),
    fromTailnetOf: machinePi,
  ),
  SeedHostKey(
    host: 'raspberrypi.tail1a2b3c.ts.net',
    line: 'ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQDG32ziP0EA0+0nwQCJuXO5U4dxgc804PPfroyzBwBDPbloHjhzpC3SHpleqMKAH0CX1RMfLxBl2NqdRl5HGM/8QnRCG4qvnOrLQn4ZBjrI+5JfFhpEfbeQ6Z1BIjPfyG6lLda+HLQm1Y2zWuHqw04VeKyfERajHtiEMeKv0lMZKJC2GP28pay7h+DCJoawl7C+ameFGOYmtaCJus8d1FB+NF5M+eZpscKPBLYcTeq2ZktXLs7o/K5hulqRQ9ZraxNV2eAKO5mOsuUQrZI6qpR+9eYoUs+eZJ/sf8t7X14cx42iM7xPgdHlpqc/SxNcCXJZfyAcc+y25pN/19xrivCLUP9e4eHq7erXQAIOPOkyF1AXVtbac792sSAQ54xunTQ/ecSEZiTvt/TZHklRU7yg6dMYIJtzGYsmdoEo8BMlmuEGY5EuPG1B1UR2gOBX60jxT/vbSjRPUm3sfUcU+fvSOWdaZTXT/liDHpqtc3wN9bpWsH8GtikBEt283pu5EG0=',
    fingerprint: 'SHA256:KKM6ungclzRWUTKl+mtNN9/rR48ViWpIm2xHurLIRWs',
    addedAt: DateTime.utc(2026, 6, 15, 18, 20, 31, 42, 137),
    fromTailnetOf: machinePi,
  ),
  SeedHostKey(
    host: 'bastion.example.org',
    line: 'ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBOy9fD9//kG3UJAA0ygU0MhV9QftgG0bYN5pnHC68GFM9ZWSoHs2nskFMjsSz6qnAV/WIoFQ4EvbmRn531tAOqk=',
    fingerprint: 'SHA256:JhBJpHaIBeFBu3xIQYCW4ruvvLG4scZpgiI1M/ni7oo',
    addedAt: DateTime.utc(2025, 12, 1, 10, 1, 44, 4, 4),
  ),
  SeedHostKey(
    host: '10.20.0.5',
    port: 2200,
    line: 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMmi9dan+2Mq0gurJvpTDatQ/Tz+EmeYO9/UzjtJ4U/y',
    fingerprint: 'SHA256:BSsdhySruia2OFDO4GjqCxmDVYNM6vkSHFkJGiEYYpk',
    addedAt: DateTime.utc(2025, 12, 1, 10, 1, 59, 900, 100),
  ),
  SeedHostKey(
    host: 'build.example.org',
    port: 2222,
    line: 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOxN91g4VLassTG/sQVscnPcO+VFZrkvTiwHLdxBG6Kj',
    fingerprint: 'SHA256:DdYc7lcLbeooQH561qPbc1TbFdgZta0sRfoQ6MDGBSU',
    addedAt: DateTime.utc(2025, 12, 1, 10, 2, 17, 250, 918),
  ),
  SeedHostKey(
    host: 'nas.home.arpa',
    line: 'ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQCktLEymMNBcv1kK193LlHZzw3bU4Ie7IrYzXbuZvqVnwuJ3TLCZltKahIKYERaeCfU1J2NN+EP79zitxZFfEWfkKnB0v/yojeWmWCvwf36NJ0BwjP8jRexjDfqowYkfoRAbVSDtH0fN0LKPRnDMMpfbr1LootWCaclMNg7YHGq7fX2QRMMRnQMm84ZBG8IgV7vd3/3R0CHZ0CvZPMId4ATOtNIkY3gt5nzasuTAjLC20L8i0TXMK+ul9MQtP5CfXuncXFQDjSKPXMMIOqy0aaWewU+4JaV3kyc584MFvVM/rcIW2mXp+mLDOl2FUgXMN5/U0ZtXBwsF8J3synJ7OJCZ3LUXCjNvz5e+kCVi286un5xHjAplZDIhEz3VmbQB6991WbvjuhvDVQpVYVB/aPrG4Ea0pLC+Qc6+2+cXBpJZ6Tr/28AEdKCJI8zIEobDG2wijkErr4unm+O+GnqQCifLyPhSMQ3ovlnw3OC6LonLtbo43q5BcL8nbPgbUT/c1M=',
    fingerprint: 'SHA256:3GGRLcmY9gInJVgHV918oD1jkqR1Hm5w/uff6r8Gx0Y',
    addedAt: DateTime.utc(2026, 1, 9, 15, 31, 0, 0, 1),
  ),
  SeedHostKey(
    host: '192.168.1.1',
    line: 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMBPEXmFy0KMVQ3yi1zs8ir34SWiGv+3zR0C5EmPILyd',
    fingerprint: 'SHA256:hi44Vi4skoXldPVjgNTBMPWylbEQsTIBOQ28F2+Ymuw',
    addedAt: DateTime.utc(2026, 3, 29, 1, 2, 3, 456, 789),
  ),
  // A second key type for the same host and port.
  SeedHostKey(
    host: 'bastion.example.org',
    line: 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIA7kywjCpPGDnx+JRt6XWeaTfpQUSCNc+fvPIXabH7bn',
    fingerprint: 'SHA256:WbNwqB/z/BIFnSSm5IAA1aVGaPdnlJeYbXTfIOL5TJc',
    addedAt: DateTime.utc(2026, 5, 5, 5, 5, 5, 555, 555),
  ),
  SeedHostKey(
    host: 'gw.example.net',
    line: 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGJI/ZLUjD11Bfa40iJftBc7RIdJr+2EDLhOqHSii9t6',
    fingerprint: 'SHA256:mi2g22nwNBOz3Va3eYWjKnJ/HGKDD4wNCPxe3Ed9aFU',
    addedAt: DateTime.utc(2026, 8, 30, 7, 7, 59, 999),
  ),
  SeedHostKey(
    host: 'archive.example.net',
    line: 'ecdsa-sha2-nistp384 AAAAE2VjZHNhLXNoYTItbmlzdHAzODQAAAAIbmlzdHAzODQAAABhBPqbBpP+D88e5ayN41Z9JwqMl+Z2+AQFuNHJz+jewqXjIb8Gqe4QqV2bGtmydKXM3ktCuImC6FcKOMqnZZJIZdR5+ywy0Fd8nUyjoM1fboOZ8tLRPmX22jnpONU58/uTcw==',
    fingerprint: 'SHA256:5IIxlFX8RnMlgNmWNY8Yzb+TZ+a51gzZMlEAZZRwNT8',
    addedAt: DateTime.utc(2026, 8, 30, 7, 8, 0, 123, 456),
  ),
];

/// Settings as the JSON values the app stores (`jsonEncode` of `Pref.encode`), in the order the seed sets them.
const seedSettings = <(String, Object?)>[
  ('local_machine_seeded', true),
  ('device_id', deviceId),
  ('language', 'de'),
  ('theme_mode', 'custom'),
  (
    'custom_theme',
    {
      'base': 'dark',
      'colors': {'background': '#0B1020', 'accent': '#FF8800', 'ansiBlue': '#5C9DFF'},
    },
  ),
  ('sidebar_width', 312.5),
  ('dock_width', 400.0),
  ('dock_open', false),
  ('dock_tab', 'files'),
  ('desktop_notifications', false),
  ('notify_done', false),
  ('push_removals', [machineNas]),
  (
    'usage_reminders',
    [
      {
        'provider': 'anthropic',
        'account': 'edde@example.com',
        'limit': 'five_hour',
        'mode': 'once',
        'label': 'edde@example.com',
        'title': '5-hour limit',
        'at': 1793640600000, // 2026-11-02T17:30:00Z
      },
      {
        'provider': 'openai-codex',
        'account': 'acct-7Hq2xP',
        'limit': null,
        'mode': 'always',
        'label': null,
        'title': null,
        'at': null,
      },
    ],
  ),
  ('project_collapsed:$machineStudio:/Users/edde/Projects/ompanion', true),
  ('project_collapsed:$machineBuero:/home/deploy/Prüfstand', false),
];

final seedReadMarkers = [
  SeedReadMarker(
    machineId: machineStudio,
    path:
        '/Users/edde/.omp/agent/sessions/--Users-edde-Projects-ompanion--/'
        '2026-10-28T08-12-44-901Z_019a2a0b-3c4d-7e5f-8a9b-0c1d2e3f4a5b.jsonl',
    seenModified: DateTime.utc(2026, 10, 30, 9, 47, 11),
  ),
  SeedReadMarker(
    machineId: machineBuero,
    path:
        '/home/deploy/.omp/agent/sessions/--home-deploy-Prüfstand--/'
        '2026-10-29T16-58-01-204Z_019a2f1c-55d0-7e41-9c3b-6a1f0e2d4b87.jsonl',
    seenModified: DateTime.utc(2026, 10, 29, 17, 2, 58),
  ),
  SeedReadMarker(
    machineId: machinePi,
    path:
        '/home/pi/.omp/agent/sessions/--home-pi-sensors--/'
        '2026-10-30T19-40-12-008Z_019a3a7e-0c11-7f02-a1b2-c3d4e5f60718.jsonl',
    seenModified: DateTime.utc(2026, 10, 31, 23, 59, 59),
  ),
];

/// In the order the seed pins them, which is not their pinnedAt order.
final seedPins = [
  SeedPin(
    machineId: machineBuero,
    sessionId: '019a2f1c-55d0-7e41-9c3b-6a1f0e2d4b87',
    path:
        '/home/deploy/.omp/agent/sessions/--home-deploy-Prüfstand--/'
        '2026-10-29T16-58-01-204Z_019a2f1c-55d0-7e41-9c3b-6a1f0e2d4b87.jsonl',
    cwd: '/home/deploy/Prüfstand',
    title: 'Fix the flaky deploy 🚀',
    firstMessage: 'Why does the deploy fail every other run?\nThe logs are in ./logs.',
    pinnedAt: DateTime.utc(2026, 10, 31, 12, 0, 0, 0, 123),
  ),
  SeedPin(
    machineId: machineStudio,
    sessionId: '019a2a0b-3c4d-7e5f-8a9b-0c1d2e3f4a5b',
    path:
        '/Users/edde/.omp/agent/sessions/--Users-edde-Projects-ompanion--/'
        '2026-10-28T08-12-44-901Z_019a2a0b-3c4d-7e5f-8a9b-0c1d2e3f4a5b.jsonl',
    cwd: '/Users/edde/Projects/ompanion',
    pinnedAt: DateTime.utc(2026, 10, 28, 8, 30),
  ),
  SeedPin(
    machineId: machinePi,
    sessionId: '019a3a7e-0c11-7f02-a1b2-c3d4e5f60718',
    path:
        '/home/pi/.omp/agent/sessions/--home-pi-sensors--/'
        '2026-10-30T19-40-12-008Z_019a3a7e-0c11-7f02-a1b2-c3d4e5f60718.jsonl',
    cwd: '/home/pi/sensors',
    title: 'Sensor logger',
    firstMessage: 'Write a script that logs the DHT22 every minute',
    pinnedAt: DateTime.utc(2026, 10, 30, 19, 45, 10, 500),
  ),
];

/// Saved passwords by hop id.
const seedPasswords = {jumpBastion: 'jump-host-s3cret', machineRouter: 'Pässwörd 日本語 🔑'};

/// Kept passphrases of `~/.ssh/config` identity files, by the key's fingerprint.
const seedKeyFilePassphrases = {'SHA256:e1CRmGTBhKEC7gzErFuG5E/XIEuE6i1a/O+UXIp/+64': 'old Mac ecdsa'};

/// Every secure-storage entry the seed writes, by key (lib/services/secret_store.dart's names).
Map<String, String> get seedSecrets => {
  for (final key in seedKeys) ...{
    'ssh-key.${key.id}.private': key.pem,
    if (key.passphrase case final passphrase?) 'ssh-key.${key.id}.passphrase': passphrase,
  },
  for (final MapEntry(:key, :value) in seedPasswords.entries) 'password.$key': value,
  for (final MapEntry(:key, :value) in seedKeyFilePassphrases.entries) 'ssh-key-file.$key.passphrase': value,
};
