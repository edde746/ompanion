import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ompanion/config/omp_cli.dart';
import 'package:omp_core/host.dart';
import 'package:omp_core/transport.dart';

/// The one-shot `omp` calls behind the settings, roles, skills and plugin pages: the process must see the
/// login shell's PATH in front of the link's own, and nothing must change when the probe read none.
void main() {
  late Directory home;
  late LocalLink link;

  setUp(() async {
    home = await Directory.systemTemp.createTemp('omp-cli-');
    link = LocalLink(environment: {'HOME': home.path, 'PATH': '/usr/bin:/bin'});
  });

  tearDown(() async {
    await link.close();
    await home.delete(recursive: true);
  });

  /// A probe of this computer whose "omp" is `/bin/sh`, so the arguments can ask the process for its PATH.
  HostProbe probe({String? loginPath}) => HostProbe(
    commandShell: CommandShell.posix,
    os: Platform.isMacOS ? HostOs.macos : HostOs.linux,
    kernel: Platform.isMacOS ? 'Darwin' : 'Linux',
    arch: 'arm64',
    home: home.path,
    agentDir: '${home.path}/.omp/agent',
    ompPath: '/bin/sh',
    loginPath: loginPath,
  );

  test('the login shell PATH is in front, verbatim, the link PATH behind it', () async {
    const login = r"/opt/homebrew/bin:/Users/me/it's here/$(exit 7)/`exit 8`/\x";
    final result = await runOmp(link, probe(loginPath: login), ['-c', r'printf %s "$PATH"']);
    expect(result.stdout, '$login:/usr/bin:/bin');
  });

  test('without a login PATH the process keeps the link PATH', () async {
    final result = await runOmp(link, probe(), ['-c', r'printf %s "$PATH"']);
    expect(result.stdout, '/usr/bin:/bin');
  });
}
