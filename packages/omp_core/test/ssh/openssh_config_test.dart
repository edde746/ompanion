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
      // `IdentityAgent none` turns the agent off; unset means SSH_AUTH_SOCK.
      expect(host.identityAgent, 'none');
      expect(parseSshG('user u\nhostname h\nport 22\n').identityAgent, isNull);
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

  group('sshIdentities', () {
    const home = '/home/me';
    SshIdentities resolve(String lines, [Map<String, String> environment = const {}]) => sshIdentities(
      parseSshG('host app\nuser deploy\nhostname app.internal\nport 2200\n$lines'),
      home: home,
      environment: environment,
      localHostname: 'laptop.local',
    );

    test('the agent is SSH_AUTH_SOCK unless IdentityAgent names another, a variable or none', () {
      const env = {'SSH_AUTH_SOCK': '/run/default.sock', 'OP_AGENT': '/run/1password.sock'};
      expect(resolve('', env).agentSocket, '/run/default.sock');
      expect(resolve('identityagent SSH_AUTH_SOCK\n', env).agentSocket, '/run/default.sock');
      expect(resolve(r'identityagent $OP_AGENT' '\n', env).agentSocket, '/run/1password.sock');
      expect(resolve('identityagent ~/My Agent/%r@%h.sock\n', env).agentSocket, '/home/me/My Agent/deploy@app.internal.sock');

      final none = resolve('identityagent none\n', env);
      expect((none.agentSocket, none.agentProblem), (null, 'IdentityAgent is none'));
      final unset = resolve('');
      expect((unset.agentSocket, unset.agentProblem), (null, 'SSH_AUTH_SOCK is not set'));
      // ssh unsets the agent for an IdentityAgent variable that is not set.
      final unsetVariable = resolve(r'identityagent $OP_AGENT' '\n');
      expect((unsetVariable.agentSocket, unsetVariable.agentProblem), (null, 'OP_AGENT is not set'));
    });

    test('identity files keep config order with ~, %-tokens and \${VAR} expanded', () {
      final identities = resolve(
        'identitiesonly yes\n'
        'identityfile ~/keys/app key\n'
        'identityfile %d/.ssh/%r@%n_%p\n'
        r'identityfile ${KEYS}/%u-%L-100%%' '\n',
        {'KEYS': '/vault', 'USER': 'me'},
      );
      expect(identities.files, [
        (configured: '~/keys/app key', path: '/home/me/keys/app key'),
        (configured: '%d/.ssh/%r@%n_%p', path: '/home/me/.ssh/deploy@app_2200'),
        (configured: r'${KEYS}/%u-%L-100%%', path: '/vault/me-laptop-100%'),
      ]);
      expect(identities.identitiesOnly, isTrue);
    });

    test('a token or variable ssh would reject fails', () {
      expect(() => resolve('identityfile ~/%x\n'), throwsFormatException);
      expect(() => resolve(r'identityfile ${NOPE}/key' '\n'), throwsFormatException);
    });
  });

  group('resolveSshAlias with sshIdentities', () {
    late Directory dir;

    setUp(() async => dir = await Directory.systemTemp.createTemp('omp-ssh-ids'));
    tearDown(() => dir.delete(recursive: true));

    Future<SshIdentities> identities(String alias, {String? user}) async => sshIdentities(
      await resolveSshAlias(alias, user: user, configFile: '${dir.path}/config'),
      home: dir.path,
      environment: {'SSH_AUTH_SOCK': '/run/default.sock', 'APP_AGENT': '/run/app.sock'},
    );

    test('Host and Match blocks and Include files apply per host, in config order', () async {
      Directory('${dir.path}/conf.d').createSync();
      File('${dir.path}/conf.d/app.conf').writeAsStringSync('Host app\n  HostName app.internal\n  IdentityAgent \$APP_AGENT\n');
      File('${dir.path}/config').writeAsStringSync('''
Include ${dir.path}/conf.d/*.conf
Host app
  IdentityFile "~/keys/app key"
  IdentitiesOnly yes
Match user deploy
  IdentityFile ~/.ssh/deploy_key
Host *
  IdentityFile ~/.ssh/id_default
''');
      final app = await identities('app', user: 'deploy');
      expect(app.agentSocket, '/run/app.sock');
      expect(app.identitiesOnly, isTrue);
      expect([for (final file in app.files) file.path], [
        '${dir.path}/keys/app key',
        '${dir.path}/.ssh/deploy_key',
        '${dir.path}/.ssh/id_default',
      ]);

      final other = await identities('other', user: 'me');
      expect(other.agentSocket, '/run/default.sock');
      expect(other.identitiesOnly, isFalse);
      expect([for (final file in other.files) file.configured], ['~/.ssh/id_default']);
    });

    test("without an IdentityFile ssh's default keys are tried", () async {
      File('${dir.path}/config').writeAsStringSync('Host app\n  HostName app.internal\n');
      final paths = [for (final file in (await identities('app')).files) file.path];
      expect(paths, containsAll(['${dir.path}/.ssh/id_ed25519', '${dir.path}/.ssh/id_ecdsa', '${dir.path}/.ssh/id_rsa']));
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
