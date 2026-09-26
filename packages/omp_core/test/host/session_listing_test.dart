import 'dart:io';

import 'package:omp_core/host.dart';
import 'package:omp_core/transport.dart';
import 'package:test/test.dart';

import 'fixtures.dart';

void main() {
  late Directory root;

  setUp(() async => root = await Directory.systemTemp.createTemp('listing-'));

  tearDown(() => root.delete(recursive: true));

  test('lists every profile and directory from the first 16 KiB of each file, newest first', () async {
    final home = '${root.path}/home';
    await writeSessionFixtures(home, root.path);
    final link = LocalLink(
      environment: {'HOME': home, 'PI_CODING_AGENT_DIR': '${root.path}/custom agent', 'PI_CONFIG_DIR': ''},
    );
    addTearDown(link.close);
    final listed = await listSessions(link, macArm, sessionDirs: ['${root.path}/session dir']);
    expectFixtureSessions(listed, '$home/.omp/agent/sessions');
  });
}
