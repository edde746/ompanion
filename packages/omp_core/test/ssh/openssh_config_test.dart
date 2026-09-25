import 'dart:io';

import 'package:omp_core/ssh.dart';
import 'package:test/test.dart';

final hasSsh = Process.runSync('which', ['ssh']).exitCode == 0;

void main() {
  group('parseSshG', () {
    // Trimmed `ssh -G` output from OpenSSH 10.3.
    const output = '''
host app
user deploy
hostname app.internal
port 2200
identitiesonly yes
identityfile ~/.ssh/id_app
identityfile /abs/key
userknownhostsfile /home/me/.ssh/known_hosts /home/me/.ssh/known_hosts2
proxyjump ops@bastion:2222,ssh://gw.example.com,[fe80::1]:22,root@2001:db8::7
identityagent /run/agent.sock
''';

    test('reads the effective host, user, port and identity files', () {
      final host = parseSshG(output);
      expect(host.hostname, 'app.internal');
      expect(host.user, 'deploy');
      expect(host.port, 2200);
      expect(host.identityFiles, ['~/.ssh/id_app', '/abs/key']);
      expect(host.identitiesOnly, isTrue);
      expect(host.userKnownHostsFiles, ['/home/me/.ssh/known_hosts', '/home/me/.ssh/known_hosts2']);
      expect(host.identityAgent, '/run/agent.sock');
      expect(host.proxyCommand, isNull);
    });

    test('splits ProxyJump into hops in dial order', () {
      final jumps = parseSshG(output).proxyJump.map((jump) => (jump.user, jump.host, jump.port));
      expect(jumps, [
        ('ops', 'bastion', 2222),
        (null, 'gw.example.com', null),
        (null, 'fe80::1', 22),
        ('root', '2001:db8::7', null),
      ]);
    });

    test('no jump and "none" values', () {
      final host = parseSshG('user u\nhostname h\nport 22\nproxycommand none\nidentityagent none\n');
      expect(host.proxyJump, isEmpty);
      expect(host.proxyCommand, isNull);
      expect(host.identityAgent, isNull);
      expect(host.identitiesOnly, isFalse);
    });

    test('ProxyCommand is reported', () {
      expect(parseSshG('user u\nhostname h\nport 22\nproxycommand nc %h %p\n').proxyCommand, 'nc %h %p');
    });

    test('missing required keys fail', () {
      expect(() => parseSshG('user u\nport 22\n'), throwsFormatException);
      expect(() => parseSshG('user u\nhostname h\nport x\n'), throwsFormatException);
    });
  });

  group('SshJumpSpec.parse', () {
    test('rejects malformed hops', () {
      for (final bad in ['', 'user@', '@host', 'host:0', 'host:99999', 'host:x', '[::1', '[::1]x']) {
        expect(() => SshJumpSpec.parse(bad), throwsFormatException, reason: bad);
      }
    });
  });

  group('resolveSshAlias', () {
    late Directory dir;

    setUp(() async => dir = await Directory.systemTemp.createTemp('omp-ssh-g'));
    tearDown(() => dir.delete(recursive: true));

    test('matches the real ssh -G, with -l and -p overrides for jump hops', () async {
      final config = File('${dir.path}/config')..writeAsStringSync('''
Host app
  HostName app.internal
  User deploy
  Port 2200
  IdentityFile ~/.ssh/id_app
  ProxyJump ops@bastion:2222,gw
Host bastion
  HostName bastion.example.com
  User nobody
''');
      final app = await resolveSshAlias('app', configFile: config.path);
      expect((app.hostname, app.user, app.port), ('app.internal', 'deploy', 2200));
      expect(app.identityFiles, ['~/.ssh/id_app']);
      expect(app.proxyJump.map((jump) => jump.host), ['bastion', 'gw']);
      final jump = app.proxyJump.first;
      final bastion = await resolveSshAlias(jump.host, user: jump.user, port: jump.port, configFile: config.path);
      expect((bastion.hostname, bastion.user, bastion.port), ('bastion.example.com', 'ops', 2222));
    });

    test('refuses an alias that looks like an option', () {
      expect(() => resolveSshAlias('-oProxyCommand=touch /tmp/x'), throwsArgumentError);
    });
  }, skip: hasSsh ? false : 'ssh not installed');

  group('listSshConfigAliases', () {
    late Directory home;

    setUp(() async {
      home = await Directory.systemTemp.createTemp('omp-ssh-home');
      Directory('${home.path}/.ssh/conf.d').createSync(recursive: true);
    });
    tearDown(() => home.delete(recursive: true));

    test('reads Host lines and Include globs, skipping patterns', () async {
      File('${home.path}/.ssh/config').writeAsStringSync('''
# comment
Host alpha beta  # trailing comment
  HostName alpha.example.com
Host *.corp !gamma ? delta
Host=epsilon
Include conf.d/*.conf ~/.ssh/extra
Match host zeta
  User z
host "quoted name"
''');
      File('${home.path}/.ssh/conf.d/b.conf').writeAsStringSync('Host from-b\n');
      File('${home.path}/.ssh/conf.d/a.conf').writeAsStringSync('Host from-a alpha\nInclude ~/.ssh/nested\n');
      File('${home.path}/.ssh/conf.d/c.txt').writeAsStringSync('Host ignored\n');
      File('${home.path}/.ssh/conf.d/.hidden.conf').writeAsStringSync('Host hidden\n');
      File('${home.path}/.ssh/nested').writeAsStringSync('Host nested\n');
      File('${home.path}/.ssh/extra').writeAsStringSync('Host extra\n');
      expect(
        await listSshConfigAliases(home: home.path),
        ['alpha', 'beta', 'delta', 'epsilon', 'from-a', 'nested', 'from-b', 'extra', 'quoted name'],
      );
    });

    test('an Include cycle stops at OpenSSH depth limit', () async {
      File('${home.path}/.ssh/config').writeAsStringSync('Host one\nInclude config\n');
      expect(await listSshConfigAliases(home: home.path), ['one']);
    });

    test('a missing config lists nothing', () async {
      expect(await listSshConfigAliases(home: home.path), isEmpty);
    });
  });
}
