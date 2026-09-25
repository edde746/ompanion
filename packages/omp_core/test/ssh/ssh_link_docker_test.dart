@Tags(['docker'])
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:omp_core/ssh.dart';
import 'package:omp_core/transport.dart';
import 'package:test/test.dart';

import 'docker_env.dart';

Future<String> text(Stream<Uint8List> stream) => utf8.decoder.bind(stream).join();

Future<(String, String, HostExit)> run(HostLink link, String command) async {
  final process = await link.exec(command);
  await process.closeStdin();
  final (stdout, stderr) = await (text(process.stdout), text(process.stderr)).wait;
  return (stdout, stderr, await process.exit);
}

Future<void> eventually(FutureOr<bool> Function() condition, {Duration timeout = const Duration(seconds: 10)}) async {
  final deadline = DateTime.now().add(timeout);
  while (!await condition()) {
    if (DateTime.now().isAfter(deadline)) throw TimeoutException('condition not met', timeout);
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

/// True once sshd answers with its banner on [port].
Future<bool> answersSsh(int port) async {
  try {
    final socket = await Socket.connect('127.0.0.1', port, timeout: const Duration(seconds: 1));
    try {
      final first = await socket.first.timeout(const Duration(seconds: 1));
      return utf8.decode(first, allowMalformed: true).startsWith('SSH-');
    } finally {
      socket.destroy();
    }
  } on SocketException {
    return false;
  } on TimeoutException {
    return false;
  } on StateError {
    return false; // Closed before the banner: sshd is still starting behind the port forward.
  }
}

Matcher failsWith(SshFailure failure) =>
    throwsA(isA<SshConnectException>().having((error) => error.failure, 'failure', failure));

void main() {
  group('authentication', () {
    test('private key', () async {
      final link = await SshLink.open(SshTarget(target: targetHop()), verifyHostKey: trustTestHosts);
      addTearDown(link.close);
      expect((await run(link, 'id -un')).$1.trim(), 'omp');
    });

    test('RSA private key', () async {
      final link = await SshLink.open(SshTarget(target: targetHop(auth: testKeyAuth('id_rsa'))), verifyHostKey: trustTestHosts);
      addTearDown(link.close);
      expect((await run(link, 'id -un')).$1.trim(), 'omp');
    });

    test('password', () async {
      final hop = targetHop(user: passwordUser, auth: const SshPasswordAuth(password));
      final link = await SshLink.open(SshTarget(target: hop), verifyHostKey: trustTestHosts);
      addTearDown(link.close);
      expect((await run(link, 'id -un')).$1.trim(), passwordUser);
    });

    test('wrong password fails as authFailed', () async {
      final hop = targetHop(user: passwordUser, auth: const SshPasswordAuth('wrong'));
      await expectLater(SshLink.open(SshTarget(target: hop), verifyHostKey: trustTestHosts), failsWith(SshFailure.authFailed));
    });

    test('password is typed into the PAM prompt when the server offers only keyboard-interactive', () async {
      final hop = targetHop(user: 'kbd', auth: const SshPasswordAuth(password));
      final link = await SshLink.open(SshTarget(target: hop), verifyHostKey: trustTestHosts);
      addTearDown(link.close);
      expect((await run(link, 'id -un')).$1.trim(), 'kbd');
    });

    test('none authentication (Tailscale SSH)', () async {
      final hop = targetHop(user: 'nopw', auth: const SshNoneAuth());
      final link = await SshLink.open(SshTarget(target: hop), verifyHostKey: trustTestHosts);
      addTearDown(link.close);
      expect((await run(link, 'id -un')).$1.trim(), 'nopw');
    });

    test('a rejected key falls back to none', () async {
      final hop = targetHop(user: 'nopw', auth: SshKeyAuth(generateEd25519Key().privateKeyPem));
      final link = await SshLink.open(SshTarget(target: hop), verifyHostKey: trustTestHosts);
      addTearDown(link.close);
      expect((await run(link, 'id -un')).$1.trim(), 'nopw');
    });

    test('keyboard-interactive answers the PAM prompt', () async {
      final requests = <KeyboardInteractiveRequest>[];
      final hop = targetHop(
        user: passwordUser,
        auth: SshKeyboardInteractiveAuth((request) async {
          requests.add(request);
          return [for (final _ in request.prompts) password];
        }),
      );
      final link = await SshLink.open(SshTarget(target: hop), verifyHostKey: trustTestHosts);
      addTearDown(link.close);
      expect((await run(link, 'id -un')).$1.trim(), passwordUser);
      // PAM's closing round has no prompts and no text, so it never reaches the handler.
      expect(requests.map((request) => [for (final prompt in request.prompts) (prompt.text, prompt.echo)]), [
        [('Password: ', false)],
      ]);
    });

    test('key not in authorized_keys fails as authFailed', () async {
      final stranger = generateEd25519Key();
      final hop = targetHop(auth: SshKeyAuth(stranger.privateKeyPem));
      await expectLater(SshLink.open(SshTarget(target: hop), verifyHostKey: trustTestHosts), failsWith(SshFailure.authFailed));
    });

    test('encrypted key without its passphrase fails before dialing', () async {
      final locked = generateEd25519Key(passphrase: 'secret');
      final hop = SshHop(host: '127.0.0.1', port: 1, user: 'omp', auth: SshKeyAuth(locked.privateKeyPem));
      await expectLater(SshLink.open(SshTarget(target: hop), verifyHostKey: trustTestHosts), failsWith(SshFailure.keyUnavailable));
    });

    group('ssh-agent', () {
      late Directory dir;
      late Process agent;
      late String socket;

      setUp(() async {
        dir = await Directory.systemTemp.createTemp('omp-agent');
        socket = '${dir.path}/agent.sock';
        agent = await Process.start('ssh-agent', ['-D', '-a', socket]);
        unawaited(agent.stdout.drain<void>());
        unawaited(agent.stderr.drain<void>());
        await eventually(() => FileSystemEntity.typeSync(socket) != FileSystemEntityType.notFound);
      });

      tearDown(() async {
        agent.kill();
        await agent.exitCode;
        await dir.delete(recursive: true);
      });

      Future<void> add(String name) async {
        final result = await Process.run('ssh-add', ['$sshTestDir/$name'], environment: {'SSH_AUTH_SOCK': socket});
        expect(result.exitCode, 0, reason: '${result.stderr}');
      }

      for (final name in ['id_ed25519', 'id_rsa']) {
        test('signs with $name', () async {
          await add(name);
          final keys = await listAgentKeys(socket);
          expect(keys.single.blob, readPrivateKey(testPrivateKey(name)).blob);
          final link = await SshLink.open(SshTarget(target: targetHop(auth: SshAgentAuth(socket))), verifyHostKey: trustTestHosts);
          addTearDown(link.close);
          expect((await run(link, 'id -un')).$1.trim(), 'omp');
        });
      }

      test('empty agent fails as keyUnavailable', () async {
        await expectLater(
          SshLink.open(SshTarget(target: targetHop(auth: SshAgentAuth(socket))), verifyHostKey: trustTestHosts),
          failsWith(SshFailure.keyUnavailable),
        );
      });
    });
  });

  group('host keys', () {
    test('every hop is checked with its own name, and the jump chain reaches the target', () async {
      final checks = <HostKeyCheck>[];
      final link = await SshLink.open(targetViaBastion(), verifyHostKey: (check) async {
        checks.add(check);
        return trustTestHosts(check);
      });
      addTearDown(link.close);
      expect(checks.map((check) => '${check.host}:${check.port}'), ['localhost:$bastionPort', 'target:22']);
      expect((await run(link, 'hostname')).$1.trim(), 'target');
    });

    test('a changed key is rejected', () async {
      // Same name as the real entry, but another ed25519 key.
      final forged = parseKnownHosts('[localhost]:$targetPort ${generateEd25519Key().publicKey.authorizedKeysLine}');
      final statuses = <KnownHostStatus>[];
      await expectLater(
        SshLink.open(SshTarget(target: targetHop()), verifyHostKey: (check) async {
          final status = checkKnownHost(forged, check);
          statuses.add(status);
          return status == KnownHostStatus.match;
        }),
        failsWith(SshFailure.hostKeyRejected),
      );
      expect(statuses, [KnownHostStatus.mismatch]);
    });
  });

  group('exec', () {
    late SshLink link;

    setUpAll(() async => link = await SshLink.open(SshTarget(target: targetHop()), verifyHostKey: trustTestHosts));
    tearDownAll(() => link.close());

    test('stdin, stdout, stderr and exit code', () async {
      final process = await link.exec('cat; echo oops >&2; exit 3');
      process.write(utf8.encode('hello '));
      process.write(utf8.encode('world'));
      await process.closeStdin();
      final (stdout, stderr) = await (text(process.stdout), text(process.stderr)).wait;
      expect(stdout, 'hello world');
      expect(stderr, 'oops\n');
      expect((await process.exit).code, 3);
    });

    test('PTY sees its size and resizes', () async {
      final process = await link.exec('stty size; read line; stty size', pty: const PtyRequest(columns: 80, rows: 24));
      final output = StringBuffer();
      final done = utf8.decoder.bind(process.stdout).forEach(output.write);
      await eventually(() => output.toString().contains('24 80'));
      process.resize(132, 40);
      process.write(utf8.encode('\r'));
      await eventually(() => output.toString().contains('40 132'));
      await done;
      expect((await process.exit).code, 0);
    });

    test('kill ends the process', () async {
      final process = await link.exec('sleep 30');
      unawaited(process.stdout.drain<void>());
      unawaited(process.stderr.drain<void>());
      await Future<void>.delayed(const Duration(milliseconds: 300));
      process.kill();
      final exit = await process.exit.timeout(const Duration(seconds: 10));
      expect(exit.signal, 'TERM');
    });

    test('12 concurrent channels exceed MaxSessions 10 and spill onto a second connection', () async {
      final results = await Future.wait([for (var i = 0; i < 12; i++) run(link, r'echo $SSH_CONNECTION; sleep 2')]);
      expect(results.map((result) => result.$3.code), everyElement(0));
      // SSH_CONNECTION is "client_ip client_port server_ip server_port": one client port per TCP connection.
      final clientPorts = results.map((result) => result.$1.trim().split(' ')[1]).toSet();
      expect(clientPorts.length, 2);
    });
  });

  group('files', () {
    late SshLink link;
    late HostFiles files;
    late String dir;

    setUpAll(() async {
      link = await SshLink.open(SshTarget(target: targetHop()), verifyHostKey: trustTestHosts);
      files = await link.files();
      dir = '${await files.home()}/files-test-${DateTime.now().microsecondsSinceEpoch}';
      await files.mkdir(dir);
    });

    tearDownAll(() async {
      await run(link, 'rm -rf $dir');
      await files.close();
      await link.close();
    });

    test('home is the login directory', () async {
      expect(await files.home(), '/home/omp');
    });

    test('write, append and ranged reads', () async {
      final path = '$dir/log.jsonl';
      await files.write(path, utf8.encode('one\n'));
      await files.write(path, utf8.encode('two\n'), append: true);
      await files.write(path, utf8.encode('three\n'), append: true);
      expect(utf8.decode(await files.read(path)), 'one\ntwo\nthree\n');
      expect(utf8.decode(await files.read(path, offset: 4)), 'two\nthree\n');
      expect(utf8.decode(await files.read(path, offset: 4, length: 3)), 'two');
      expect((await files.stat(path))!.size, 14);
      await files.write(path, utf8.encode('fresh'));
      expect(utf8.decode(await files.read(path)), 'fresh');
    });

    test('mode applies when the file is created, not when it exists', () async {
      final path = '$dir/secret';
      await files.write(path, utf8.encode('s3cret'), mode: 0x180); // 0600
      expect((await files.stat(path))!.mode! & 0x1ff, 0x180);
      await files.write(path, utf8.encode('again'), mode: 0x1ff);
      expect((await files.stat(path))!.mode! & 0x1ff, 0x180);
      expect(utf8.decode(await files.read(path)), 'again');
    });

    test('mkdir is an exclusive lock', () async {
      final lock = '$dir/in.lock';
      await files.mkdir(lock);
      await expectLater(files.mkdir(lock), throwsA(isA<HostFileExists>()));
      await files.removeDir(lock);
      await files.mkdir(lock);
      await files.removeDir(lock);
    });

    test('stat, list, rename and remove', () async {
      expect(await files.stat('$dir/missing'), isNull);
      await files.write('$dir/a', [1, 2, 3]);
      await files.mkdir('$dir/sub');
      final entries = {for (final entry in await files.list(dir)) entry.name: entry.stat};
      expect(entries['a']!.size, 3);
      expect(entries['a']!.isDirectory, isFalse);
      expect(entries['sub']!.isDirectory, isTrue);
      expect(entries.keys, isNot(contains('.')));
      await files.rename('$dir/a', '$dir/b');
      expect(await files.stat('$dir/a'), isNull);
      expect(await files.read('$dir/b'), [1, 2, 3]);
      await files.remove('$dir/b');
      await files.removeDir('$dir/sub');
      expect(await files.stat('$dir/b'), isNull);
    });

    test('links: stat describes them unless following, list never follows, remove deletes only the link', () async {
      final (_, stderr, exit) = await run(
        link,
        'mkdir $dir/target $dir/tree && touch $dir/target/keep && '
        'ln -s $dir/target $dir/tree/dir-link && ln -s $dir/gone $dir/tree/dangling',
      );
      expect(exit.code, 0, reason: stderr);
      expect((await files.stat('$dir/tree/dir-link'))!.isDirectory, isTrue);
      final own = (await files.stat('$dir/tree/dir-link', followLinks: false))!;
      expect((own.isLink, own.isDirectory), (true, false));
      expect(await files.stat('$dir/tree/dangling'), isNull);
      expect((await files.stat('$dir/tree/dangling', followLinks: false))!.isLink, isTrue);
      final entries = {for (final entry in await files.list('$dir/tree')) entry.name: entry.stat};
      expect((entries['dir-link']!.isLink, entries['dir-link']!.isDirectory), (true, false));
      expect(entries['dangling']!.isLink, isTrue);
      await files.remove('$dir/tree/dir-link');
      await files.remove('$dir/tree/dangling');
      expect(await files.list('$dir/tree'), isEmpty);
      expect(await files.stat('$dir/target/keep'), isNotNull);
    });

    test('errors name the path', () async {
      await expectLater(
        files.read('$dir/missing'),
        throwsA(isA<HostLinkException>().having((error) => error.message, 'message', contains('$dir/missing'))),
      );
    });
  });

  test('connect opens a TCP stream from the target', () async {
    final link = await SshLink.open(targetViaBastion(), verifyHostKey: trustTestHosts);
    addTearDown(link.close);
    final socket = await link.connect('127.0.0.1', 22);
    final banner = await utf8.decoder.bind(socket.input).first;
    expect(banner, startsWith('SSH-2.0-OpenSSH'));
    await socket.close();
  });

  group('link loss', () {
    // A private machine per test, on the test network so it can also serve as a jump host to `target`.
    late String container;
    late int port;

    setUp(() async {
      final authorized = File('$sshTestDir/id_ed25519.pub').readAsStringSync().trim();
      final started = await Process.run('docker', [
        'run', '-d', '--label', 'omp-sshd=1', '--network', 'omp-sshd', '-p', '127.0.0.1::22', //
        '-e', 'AUTHORIZED_KEYS=$authorized', sshdImage,
      ]);
      expect(started.exitCode, 0, reason: '${started.stderr}');
      container = (started.stdout as String).trim();
      final mapped = await Process.run('docker', ['port', container, '22/tcp']);
      port = int.parse((mapped.stdout as String).trim().split('\n').first.split(':').last);
      await eventually(timeout: const Duration(seconds: 30), () => answersSsh(port));
    });

    tearDown(() async {
      await Process.run('docker', ['unpause', container]);
      await Process.run('docker', ['rm', '-f', container]);
    });

    Future<SshLink> open(SshLiveness liveness) => SshLink.open(
          SshTarget(target: SshHop(host: '127.0.0.1', port: port, user: 'omp', auth: testKeyAuth())),
          verifyHostKey: (_) async => true,
          liveness: liveness,
        );

    test('done completes when the machine stops', () async {
      final link = await open(const SshLiveness());
      expect((await run(link, 'id -un')).$1.trim(), 'omp');
      await Process.run('docker', ['stop', '-t', '1', container]);
      await link.done.timeout(const Duration(seconds: 15));
      expect(link.closeReason, isA<HostLinkException>());
      await expectLater(link.exec('true'), throwsA(isA<HostLinkException>()));
    });

    test('done completes when a jump host stops', () async {
      final link = await SshLink.open(
        SshTarget(
          jumps: [SshHop(host: '127.0.0.1', port: port, user: 'omp', auth: testKeyAuth())],
          target: SshHop(host: 'target', user: 'omp', auth: testKeyAuth()),
        ),
        verifyHostKey: (check) async => check.host == '127.0.0.1' || await trustTestHosts(check),
      );
      expect((await run(link, 'hostname')).$1.trim(), 'target');
      await Process.run('docker', ['stop', '-t', '1', container]);
      await link.done.timeout(const Duration(seconds: 15));
      expect(link.closeReason, isA<HostLinkException>());
    });

    test('unanswered keepalives declare a frozen peer dead', () async {
      final link = await open(const SshLiveness(interval: Duration(milliseconds: 500), maxMissed: 3));
      expect((await run(link, 'id -un')).$1.trim(), 'omp');
      final paused = await Process.run('docker', ['pause', container]);
      expect(paused.exitCode, 0, reason: '${paused.stderr}');
      final watch = Stopwatch()..start();
      await link.done.timeout(const Duration(seconds: 15));
      expect(watch.elapsed, lessThan(const Duration(seconds: 5)));
      expect('${link.closeReason}', contains('keepalive'));
    });

    test('probe reports a frozen peer at once', () async {
      final link = await open(const SshLiveness());
      expect(await link.probe(), isTrue);
      await Process.run('docker', ['pause', container]);
      expect(await link.probe(timeout: const Duration(seconds: 1)), isFalse);
      await link.done.timeout(const Duration(seconds: 5));
    });
  });
}
