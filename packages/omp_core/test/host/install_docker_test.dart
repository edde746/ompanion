@Tags(['docker'])
library;

import 'dart:io';

import 'package:omp_core/host.dart';
import 'package:omp_core/ssh.dart';
import 'package:test/test.dart';

import '../omp_binary.dart';
import '../ssh/docker_env.dart';

/// The download install route on the Linux test machine, as user `pw`, whose home has no omp. The machine
/// fetches release assets from a server on this computer, which containers reach at `host.docker.internal`.
void main() {
  late SshLink link;
  late HostProbe probe;
  late HttpServer server;
  final requests = <(String, String)>[];

  setUpAll(() async {
    server = await HttpServer.bind(await hostGatewayAddress(), 0);
    server.listen((request) async {
      requests.add((request.uri.path, request.headers.value(HttpHeaders.userAgentHeader) ?? ''));
      final response = request.response;
      final asset = File(ompAsset(request.uri.pathSegments.last));
      if (request.uri.pathSegments.first == 'tampered') {
        // The expected version and a trace: only the digest check keeps it from running and being installed.
        response.write('#!/bin/sh\ntouch "\$HOME/tampered-ran"\necho omp/$testedOmpVersion\n');
      } else if (request.uri.pathSegments.first == 'release' && asset.existsSync()) {
        response.contentLength = asset.lengthSync();
        await response.addStream(asset.openRead());
      } else {
        response.statusCode = HttpStatus.notFound;
      }
      await response.close();
    });
    link = await SshLink.open(
      SshTarget(
        target: targetHop(user: passwordUser, auth: const SshPasswordAuth(password)),
      ),
      verifyHostKey: trustTestHosts,
    );
    probe = await probeHost(link);
  });

  tearDownAll(() async {
    await runPosixScript(link, 'rm -rf "\$HOME"/path-without-* "\$HOME/.local" "\$HOME/.omp" "\$HOME/tampered-ran"');
    await link.close();
    await server.close(force: true);
  });

  /// A directory for PATH with links to every command of the machine except [hidden].
  Future<String> pathWithout(List<String> hidden) async {
    final result = await runPosixScript(link, '''
d="\$HOME/path-without-${hidden.join('-')}"; hide=${shQuote(' ${hidden.join(' ')} ')}
rm -rf "\$d" && mkdir "\$d" || exit 1
for f in /usr/local/sbin/* /usr/local/bin/* /usr/sbin/* /usr/bin/* /sbin/* /bin/*; do
  n=\${f##*/}
  [ -e "\$f" ] || continue
  case \$hide in *" \$n "*) continue ;; esac
  [ -e "\$d/\$n" ] || ln -s "\$f" "\$d/\$n"
done
printf '%s' "\$d"
''');
    expect(result.exit.code, 0, reason: result.stderr);
    return result.stdout;
  }

  String withPath(String path, String script) => 'PATH=${shQuote(path)}; export PATH\n$script';

  Uri base(String kind) => Uri.parse('http://host.docker.internal:${server.port}/$kind/');

  test('a machine with neither curl nor wget, like stock Debian and Ubuntu, gets the upload route', () async {
    expect((probe.curl, probe.wget, installRoute(probe)), (true, true, InstallRoute.download));
    final marker = newMarker();
    final result = await runPosixScript(link, withPath(await pathWithout(['curl', 'wget']), posixProbeScript(marker)));
    final bare = parsePosixProbe(result.payload(marker));
    expect((bare.curl, bare.wget, installRoute(bare)), (false, false, InstallRoute.upload));
    expect(bare.releaseAsset, probe.releaseAsset, reason: 'the probe itself still works on that PATH');
  });

  for (final tool in ['curl', 'wget']) {
    test('$tool downloads the release asset, which is checked and installed', () async {
      requests.clear();
      final script = posixInstallCommand(probe, testedOmpVersion, assetBase: base('release'));
      final result = await runPosixScript(
        link,
        tool == 'curl' ? script : withPath(await pathWithout(['curl']), script),
      );
      expect(result.exit.code, 0, reason: result.stderr);
      expect(requests.single.$1, '/release/${probe.releaseAsset}');
      expect(requests.single.$2.toLowerCase(), startsWith(tool));
      final installed = await runPosixScript(link, 'ls -A "\$HOME/.local/bin"; "\$HOME/.local/bin/omp" --version');
      expect(
        installed.stdout,
        'omp\nomp/$testedOmpVersion\n',
        reason: 'the download was moved into place, nothing left beside it',
      );
    }, timeout: const Timeout(Duration(minutes: 5)));
  }

  test('a tampered download is refused before it runs, and removed', () async {
    final dir = '${probe.home}/tampered';
    final result = await runPosixScript(
      link,
      posixInstallCommand(probe, testedOmpVersion, installDir: dir, assetBase: base('tampered')),
    );
    expect(result.exit.code, 1);
    expect(result.stderr, contains('SHA-256 mismatch'));
    final left = await runPosixScript(
      link,
      'ls -A ${shQuote(dir)}; ls "\$HOME/tampered-ran" 2>/dev/null; rm -rf ${shQuote(dir)}',
    );
    expect(left.stdout, isEmpty);
  });
}
