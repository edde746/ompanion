import 'package:omp_core/host.dart';
import 'package:omp_core/session.dart';
import 'package:test/test.dart';

void main() {
  test('the run overlay nests dotted keys and always turns speech off', () {
    expect(
      renderOverlay({'tools.approvalMode': 'always-ask', 'speech.enabled': 'true', 'a.b.c': '[1, 2]', 'odd key': '"x"'}),
      'tools:\n'
      '  approvalMode: always-ask\n'
      'speech:\n'
      '  enabled: false\n'
      'a:\n'
      '  b:\n'
      '    c: [1, 2]\n'
      '"odd key": "x"\n',
    );
    expect(renderOverlay(const {}), 'speech:\n  enabled: false\n');
    expect(() => renderOverlay({'tools': 'x', 'tools.approvalMode': 'y'}), throwsArgumentError);
    expect(() => renderOverlay({'tools.approvalMode': 'a\nb: c'}), throwsArgumentError);
  });

  test('omp older than 18.3.1, a pre-release of it, or none at all needs an install', () {
    HostProbe probe({String? path = '/usr/bin/omp', String? version}) => HostProbe(
      commandShell: CommandShell.posix,
      os: HostOs.linux,
      kernel: 'Linux',
      arch: 'x64',
      home: '/home/me',
      agentDir: '/home/me/.omp/agent',
      ompPath: path,
      ompVersion: version,
    );
    expect(ompProblem(probe(version: '18.3.1')), isNull);
    expect(ompProblem(probe(version: '18.10.0')), isNull);
    expect(ompProblem(probe(version: '19.0.0-beta.1')), isNull);
    expect(ompProblem(probe(version: '18.3.0')), 'omp 18.3.0 is older than 18.3.1');
    expect(ompProblem(probe(version: '18.3.1-rc.2')), 'omp 18.3.1-rc.2 is older than 18.3.1');
    expect(ompProblem(probe(path: null)), 'omp is not installed');
    expect(ompProblem(probe(version: null)), 'omp at /usr/bin/omp did not report its version');
  });
}
