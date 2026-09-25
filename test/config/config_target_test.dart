import 'package:flutter_test/flutter_test.dart';
import 'package:omp_app/config/config_target.dart';

import 'fake_machine.dart';

void main() {
  // omp 18.3.1 reads the profile's config.yml, else config.yaml (MAIN_CONFIG_FILENAMES), but a project's
  // .omp/config.yml only (settings.ts #readProjectSettings, the native settings provider in builtin.ts).
  test('the settings files are the ones omp reads', () async {
    final files = MemoryFiles()
      ..texts['/home/u/.omp/agent/config.yaml'] = 'theme: {}\n'
      ..texts['/work/p/.omp/config.yaml'] = 'theme: {}\n';
    final runtime = await probedRuntime(FakeLink(files));
    addTearDown(runtime.dispose);
    final target = ConfigTarget(machine: testMachine, sessions: FakeSessions(testMachine, runtime));

    expect(await target.globalConfigPath(), '/home/u/.omp/agent/config.yaml');
    expect(target.projectConfigPath('/work/p'), '/work/p/.omp/config.yml');
    files.texts['/home/u/.omp/agent/config.yml'] = '';
    expect(await target.globalConfigPath(), '/home/u/.omp/agent/config.yml');
  });
}
