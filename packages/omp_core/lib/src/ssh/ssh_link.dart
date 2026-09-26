import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';

import '../transport/host_link.dart';
import 'host_key_tap.dart';
import 'keys.dart';
import 'openssh_config.dart';
import 'ssh_agent_client.dart';
import 'ssh_config.dart';

/// Dead-peer detection. dartssh2's own keepalive ignores missing replies, so the link sends a
/// keepalive every [interval] and declares the peer dead after [maxMissed] unanswered in a row.
final class SshLiveness {
  const SshLiveness({this.interval = const Duration(seconds: 15), this.maxMissed = 3});

  final Duration interval;
  final int maxMissed;
}

enum SshFailure {
  /// TCP connect failed, or a jump host could not open a channel to the next hop.
  unreachable,

  /// No answer within the connect timeout. Only network and protocol waits count: time the user spends on host-key,
  /// password, keyboard-interactive and passphrase prompts or confirming an agent signature is excluded.
  timeout,

  /// The verifier refused the host key, or the key changed during the connection.
  hostKeyRejected,

  /// The server refused every credential offered; [SshConnectException.offer] lists the keys.
  authFailed,

  /// The configured private key or ssh-agent could not be used on this device, or there was no key to offer.
  keyUnavailable,

  /// The SSH handshake failed for another reason.
  protocol,
}

final class SshConnectException extends HostLinkException {
  SshConnectException(this.hop, this.failure, String message, {this.offer, super.cause})
    : super('${hop.label}: $message');

  final SshHop hop;
  final SshFailure failure;

  /// The keys the hop refused ([SshFailure.authFailed]), or where keys were looked for when there were none.
  final SshKeyOffer? offer;
}

/// A machine reached over SSH, directly or through a chain of jump hosts.
///
/// Session channels (exec, SFTP) are spread over extra connections to the target when sshd's
/// `MaxSessions` (default 10) refuses one; extra connections close after 30 idle seconds.
final class SshLink implements HostLink {
  SshLink._(this.target, this._dialer, this._liveness, this._jumps, this._primary) {
    _connections.add(_primary);
    for (final (index, jump) in _jumps.indexed) {
      _watch(jump.client, target.jumps[index]);
    }
    _watch(_primary.client, target.target);
    _keepalive = Timer.periodic(_liveness.interval, (_) => _sendKeepalive());
  }

  /// Connects hop by hop: each jump opens a `direct-tcpip` channel to the next hop, which gets its
  /// own host-key check and authentication. Throws [SshConnectException].
  static Future<SshLink> open(
    SshTarget target, {
    required HostKeyVerifier verifyHostKey,
    SshLiveness liveness = const SshLiveness(),
    Duration connectTimeout = const Duration(seconds: 15),
    void Function(SshHop hop, String banner)? onBanner,
  }) async {
    final dialer = _Dialer(verifyHostKey, connectTimeout, onBanner);
    final hops = target.hops;
    final connections = <_Connection>[];
    try {
      for (var index = 0; index < hops.length; index++) {
        connections.add(await dialer.dial(hops, index, via: connections.lastOrNull?.client));
      }
    } on Object {
      for (final connection in connections.reversed) {
        unawaited(connection.close());
      }
      rethrow;
    }
    return SshLink._(target, dialer, liveness, connections.sublist(0, hops.length - 1), connections.last);
  }

  final SshTarget target;
  final _Dialer _dialer;
  final SshLiveness _liveness;
  final List<_Connection> _jumps;
  final _Connection _primary;
  final _connections = <_Connection>[];
  final _done = Completer<void>();
  late final Timer _keepalive;
  Future<_Connection>? _adding;
  Object? _closeReason;
  var _closing = false;
  var _unanswered = 0;

  static const _idleClose = Duration(seconds: 30);

  @override
  String get label => target.label;

  /// Completes (never with an error) once the link is gone: closed locally, closed by any hop, or dead.
  @override
  Future<void> get done => _done.future;

  /// Why the link went down; null after [close].
  Object? get closeReason => _closeReason;

  /// Sends one keepalive and waits up to [timeout] for the reply, e.g. when the app resumes or the
  /// network changes. On silence the link closes as dead and this returns false.
  Future<bool> probe({Duration timeout = const Duration(seconds: 5)}) async {
    if (_closing) return false;
    try {
      await _primary.client.ping().timeout(timeout);
      _unanswered = 0;
      return true;
    } on TimeoutException catch (error) {
      await _shutDown(HostLinkException('$label did not answer a keepalive within $timeout', cause: error));
      return false;
    } on SSHError catch (error) {
      await _shutDown(HostLinkException('$label: connection lost', cause: error));
      return false;
    }
  }

  @override
  Future<HostProcess> exec(String command, {PtyRequest? pty}) async {
    final (session, connection) = await _session('exec', (client) {
      final config = pty == null ? null : SSHPtyConfig(type: pty.term, width: pty.columns, height: pty.rows);
      return client.execute(command, pty: config);
    });
    unawaited(session.done.then((_) => _release(connection)));
    return _SshProcess(session);
  }

  @override
  Future<HostFiles> files() async {
    final (sftp, connection) = await _session('sftp', (client) async {
      final sftp = await client.sftp();
      try {
        await sftp.handshake.timeout(_dialer.timeout);
      } on Object {
        unawaited(sftp.close());
        rethrow;
      }
      return sftp;
    });
    return _SftpFiles(sftp, label, () => _release(connection));
  }

  @override
  Future<HostSocket> connect(String host, int port) async {
    _checkOpen();
    try {
      return _SshSocket(await _primary.client.forwardLocal(host, port));
    } on SSHChannelOpenError catch (error) {
      throw HostLinkException('$label cannot reach $host:$port: ${error.description}', cause: error);
    } on SSHError catch (error) {
      throw HostLinkException('$label: connect to $host:$port failed', cause: error);
    }
  }

  @override
  Future<void> close() => _shutDown(null);

  /// Opens a session channel, on another connection to the target when this one is full.
  Future<(T, _Connection)> _session<T>(String what, Future<T> Function(SSHClient client) open) async {
    while (true) {
      _checkOpen();
      final connection = _connections.where((c) => c.hasRoom).firstOrNull ?? await _addConnection();
      connection.idle?.cancel();
      final setup = Completer<void>();
      connection.setups.add(setup.future);
      final SSHChannelOpenError refusal;
      try {
        final value = await open(connection.client);
        connection.open++;
        return (value, connection);
      } on SSHChannelOpenError catch (error) {
        refusal = error;
      } on Object catch (error) {
        if (error is HostLinkException) rethrow;
        throw HostLinkException('$label: $what failed', cause: error);
      } finally {
        connection.setups.remove(setup.future);
        setup.complete();
        _retireWhenIdle(connection);
      }
      // sshd refuses session channels past MaxSessions (default 10). The server answers channel opens
      // in order, so once the setups racing this one settle, an established channel here means that.
      await Future.wait(List.of(connection.setups));
      if (connection.open == 0) {
        throw HostLinkException('$label refused a session channel for $what: ${refusal.description}', cause: refusal);
      }
      connection.full = true;
    }
  }

  Future<_Connection> _addConnection() => _adding ??= () async {
    try {
      final hops = target.hops;
      final connection = await _dialer.dial(hops, hops.length - 1, via: _jumps.lastOrNull?.client);
      if (_closing) {
        unawaited(connection.close());
        throw HostLinkException('$label: link is closed', cause: _closeReason);
      }
      _connections.add(connection);
      _watch(connection.client, target.target, connection);
      return connection;
    } finally {
      _adding = null;
    }
  }();

  void _release(_Connection connection) {
    connection.open--;
    connection.full = false;
    _retireWhenIdle(connection);
  }

  void _retireWhenIdle(_Connection connection) {
    if (connection == _primary || connection.open > 0 || connection.setups.isNotEmpty || _closing) return;
    connection.idle?.cancel();
    connection.idle = Timer(_idleClose, () {
      connection.retired = true;
      _connections.remove(connection);
      unawaited(connection.close());
    });
  }

  void _watch(SSHClient client, SshHop hop, [_Connection? connection]) {
    void lost(Object? error) {
      if (_closing || (connection?.retired ?? false)) return;
      unawaited(_shutDown(HostLinkException('${hop.label}: connection closed', cause: error)));
    }

    unawaited(client.done.then((_) => lost(null), onError: lost));
  }

  void _sendKeepalive() {
    if (_unanswered >= _liveness.maxMissed) {
      unawaited(_shutDown(HostLinkException('$label did not answer $_unanswered keepalives')));
      return;
    }
    _unanswered++;
    unawaited(
      _primary.client.ping().then(
        (_) => _unanswered = 0,
        onError: (Object error) => _shutDown(HostLinkException('$label: connection lost', cause: error)),
      ),
    );
  }

  void _checkOpen() {
    if (_closing) throw HostLinkException('$label: link is closed', cause: _closeReason);
  }

  Future<void> _shutDown(Object? reason) async {
    if (_closing) return _done.future;
    _closing = true;
    _closeReason = reason;
    _keepalive.cancel();
    final targets = List.of(_connections);
    for (final connection in targets) {
      connection.idle?.cancel();
    }
    await Future.wait([for (final connection in targets) connection.close()]);
    for (final jump in _jumps.reversed) {
      await jump.close();
    }
    _done.complete();
  }
}

/// One SSH connection to one hop, with its session-channel accounting.
final class _Connection {
  _Connection(this.client, this.socket);

  final SSHClient client;
  final SSHSocket socket;

  /// Session channels in use.
  var open = 0;

  /// Session channel setups in flight; each future completes (never with an error) when its setup ends.
  final setups = <Future<void>>{};
  Timer? idle;
  var retired = false;

  /// The server refused a session channel while others were open (MaxSessions); cleared when one closes.
  var full = false;

  bool get hasRoom => !retired && !full;

  /// Closes the SSH connection, then drops the socket in case a dead peer never acknowledges.
  /// Never fails: closing a broken socket reports the break again, and the link already recorded it.
  Future<void> close() async {
    await client
        .close()
        .timeout(const Duration(seconds: 2), onTimeout: () {})
        .then<void>((_) {}, onError: (Object _) {});
    socket.destroy();
  }
}

/// Dials one hop at a time, keeping decoded keys, accepted host keys and the working credential
/// for extra connections.
final class _Dialer {
  _Dialer(this._verify, this.timeout, this._onBanner);

  final HostKeyVerifier _verify;
  final Duration timeout;
  final void Function(SshHop hop, String banner)? _onBanner;
  final _keys = <int, List<SSHKeyPair>>{};

  /// Identity files unlocked for this link, by path, so extra connections do not ask for passphrases again.
  final _unlocked = <String, SSHKeyPair>{};
  final _acceptedHostKeys = <int, String>{};
  final _workingAuth = <int, SshAuth>{};

  Future<_Connection> dial(List<SshHop> hops, int index, {SSHClient? via}) async {
    final hop = hops[index];
    final auth = _workingAuth[index] ?? hop.auth;
    try {
      return await _dialWith(hops, index, auth, via);
    } on SshConnectException catch (error) {
      // dartssh2 queues `none` after the configured method but drops it once the server answers
      // with a failure. OpenSSH tries `none` first, and Tailscale SSH admits clients that way.
      if (error.failure != SshFailure.authFailed || auth is SshNoneAuth) rethrow;
      try {
        final connection = await _dialWith(hops, index, const SshNoneAuth(), via);
        _workingAuth[index] = const SshNoneAuth();
        return connection;
      } on SshConnectException {
        throw error;
      }
    }
  }

  Future<_Connection> _dialWith(List<SshHop> hops, int index, SshAuth auth, SSHClient? via) async {
    final hop = hops[index];
    final prepared = await _prepareAuth(hop, index, auth);
    try {
      final socket = via == null ? await _connectTcp(hop) : await _forward(via, hops[index - 1], hop);
      return _Connection(await _handshake(hop, index, socket, prepared), socket);
    } finally {
      await prepared.agent?.close();
    }
  }

  Future<_Auth> _prepareAuth(SshHop hop, int index, SshAuth auth) async {
    final waits = _UserWaits();
    switch (auth) {
      case SshKeyAuth(:final privateKeyPem, :final passphrase, :final name, :final fallback):
        final List<SSHKeyPair> keys;
        try {
          keys = _keys[index] ??= decodeKeyPairs(privateKeyPem, passphrase);
        } on SshKeyException catch (error) {
          throw SshConnectException(hop, SshFailure.keyUnavailable, error.message, cause: error);
        }
        final offer = SshKeyOffer(
          keys: [
            for (final key in keys)
              SshOfferedKey(SshPublicKey(key.toPublicKey().encode(), comment: key.comment ?? ''), name: name),
          ],
        );
        return _Auth.offering(hop, waits, offer, fallback, identities: keys);
      case SshPasswordAuth(:final password):
        var typed = false;
        return _Auth(
          waits,
          onPassword: () async => password,
          // Servers with PasswordAuthentication off often take the password through a PAM
          // keyboard-interactive prompt instead. dartssh2 tries the password method first whether or not
          // the server offers it, so its failure does not prove the password wrong: type it into one
          // password prompt, once. Anything else (one-time codes) gives up.
          respond: (request) async {
            final prompts = request.prompts;
            if (prompts.isEmpty) return const [];
            if (typed || prompts.length != 1 || prompts.single.echo) return null;
            if (!prompts.single.text.toLowerCase().contains('password')) return null;
            typed = true;
            return [password];
          },
        );
      case SshConfigAuth():
        return _prepareConfig(hop, auth, waits);
      case SshNoneAuth():
        return _Auth(waits);
      case SshKeyboardInteractiveAuth(:final respond):
        return _Auth(waits, respond: respond);
    }
  }

  /// Offers keys like `ssh`'s `pubkey_prepare`: agent keys in agent order (one that is also an identity file counts as
  /// that file; others only without `IdentitiesOnly`), then the remaining identity files.
  Future<_Auth> _prepareConfig(SshHop hop, SshConfigAuth auth, _UserWaits waits) async {
    final environment = auth.config.environment ?? Platform.environment;
    final home = auth.config.home ?? environment[Platform.isWindows ? 'USERPROFILE' : 'HOME'] ?? '';
    final SshIdentities plan;
    try {
      final resolved = await resolveSshAlias(
        auth.alias ?? hop.host,
        user: hop.user,
        port: hop.port,
        configFile: auth.config.configFile,
      );
      plan = sshIdentities(resolved, home: home, environment: environment);
    } on ProcessException catch (error) {
      final message = 'ssh -G cannot read the OpenSSH config: ${error.message}';
      throw SshConnectException(hop, SshFailure.keyUnavailable, message, cause: error);
    } on FormatException catch (error) {
      throw SshConnectException(hop, SshFailure.keyUnavailable, 'OpenSSH config: ${error.message}', cause: error);
    }

    SshAgentClient? agent;
    var agentKeys = const <SshPublicKey>[];
    var agentProblem = plan.agentProblem;
    if (plan.agentSocket case final socket?) {
      try {
        agent = await SshAgentClient.connect(socket);
        agentKeys = await agent.identities().timeout(timeout);
        if (agentKeys.isEmpty) agentProblem = 'ssh-agent at $socket holds no keys';
      } on SshAgentException catch (error) {
        agentProblem = error.message;
      } on TimeoutException {
        agentProblem = 'ssh-agent at $socket did not answer';
      }
      if (agentKeys.isEmpty) {
        await agent?.close();
        agent = null;
      }
    }

    final missing = <String>[];
    final unusable = <({String path, String reason})>[];
    final files = <_IdentityFile>[];
    for (final (:configured, :path) in plan.files) {
      try {
        final identity = await _readIdentityFile(configured, path);
        if (identity == null) {
          missing.add(configured);
        } else if (identity.publicKey case final key? when !_signable.contains(key.type)) {
          unusable.add((path: configured, reason: '${keyTypeLabel(key.type)} keys are not supported'));
        } else {
          files.add(identity);
        }
      } on SshKeyException catch (error) {
        // ssh reports an unreadable identity file and goes on with the next.
        unusable.add((path: configured, reason: error.message));
      } on FormatException catch (error) {
        unusable.add((path: configured, reason: error.message));
      } on FileSystemException catch (error) {
        unusable.add((path: configured, reason: error.osError?.message ?? error.message));
      }
    }

    final identities = <SSHIdentity>[];
    final offered = <SshOfferedKey>[];
    final agentSigned = agent == null ? const <SSHIdentity>[] : agentIdentities(agent, agentKeys, wait: waits.run);
    final remaining = List.of(files);
    for (final (index, key) in agentKeys.indexed) {
      final file = remaining.where((file) => _sameKey(file.publicKey, key)).firstOrNull;
      if (file == null && plan.identitiesOnly) continue;
      remaining.remove(file);
      identities.add(agentSigned[index]);
      offered.add(SshOfferedKey(key, path: file?.configured, agent: true));
    }
    for (final file in remaining) {
      if (file.pem == null) {
        const reason = 'only the public key is there, and the ssh-agent does not hold it';
        unusable.add((path: file.configured, reason: reason));
        continue;
      }
      final SshPublicKey publicKey;
      if (file.publicKey case final known?) {
        publicKey = known;
      } else {
        // Nothing tells which key an encrypted PEM file holds, so ssh unlocks it before offering it.
        final pair = await _unlock(hop, file, auth.passphrase);
        publicKey = SshPublicKey(pair.toPublicKey().encode());
      }
      identities.add(
        SSHIdentity.custom(
          type: signatureType(publicKey.type),
          publicKey: SSHRawHostKey(publicKey.blob),
          signer: (data) async => (await waits.run(() => _unlock(hop, file, auth.passphrase))).sign(data),
          comment: file.configured,
          // The passphrase is asked only for a key the server accepts.
          shouldProbe: true,
        ),
      );
      offered.add(SshOfferedKey(publicKey, path: file.configured));
    }

    final offer = SshKeyOffer(
      keys: offered,
      agentProblem: agentProblem,
      missingFiles: missing,
      unusableFiles: unusable,
    );
    if (identities.isEmpty && auth.fallback == null) {
      throw SshConnectException(hop, SshFailure.keyUnavailable, offer.describe(), offer: offer);
    }
    return _Auth.offering(hop, waits, offer, auth.fallback, identities: identities, agent: agent);
  }

  /// dartssh2 signs with these; others (`-sk` security keys) cannot be used from an identity file.
  static const _signable = {
    'ssh-ed25519',
    'ssh-rsa',
    'ecdsa-sha2-nistp256',
    'ecdsa-sha2-nistp384',
    'ecdsa-sha2-nistp521',
  };

  static bool _sameKey(SshPublicKey? a, SshPublicKey b) => a != null && a.fingerprint == b.fingerprint;

  /// Reads an identity file like `ssh` loads one: the private key with its public half (from the `.pub` next to it
  /// when there is one), or only a public key (`IdentityFile` naming a `.pub`, or a `.pub` without its private key)
  /// for a key the agent holds. Null when neither exists.
  static Future<_IdentityFile?> _readIdentityFile(String configured, String path) async {
    final file = File(path);
    final pub = File('$path.pub');
    final publicText = await pub.exists() ? await pub.readAsString() : null;
    if (!await file.exists()) {
      return publicText == null ? null : _IdentityFile(configured, path, null, SshPublicKey.parse(publicText));
    }
    final text = await file.readAsString();
    if (!text.contains('PRIVATE KEY-----')) {
      try {
        return _IdentityFile(configured, path, null, SshPublicKey.parse(text));
      } on FormatException {
        throw const SshKeyException(SshKeyProblem.malformed, 'neither a private nor a public key');
      }
    }
    return _IdentityFile(configured, path, text, identityPublicKey(text, publicText: publicText));
  }

  /// The private key of [file], asking [ask] for its passphrase until it decrypts. Decryption (bcrypt) runs off this
  /// isolate.
  Future<SSHKeyPair> _unlock(SshHop hop, _IdentityFile file, KeyPassphraseHandler? ask) async {
    if (_unlocked[file.path] case final pair?) return pair;
    final pem = file.pem!;
    try {
      if (!privateKeyIsEncrypted(pem)) return _unlocked[file.path] = decodeKeyPairs(pem, null).first;
      if (ask == null) throw SshConnectException(hop, SshFailure.keyUnavailable, '${file.configured} is encrypted');
      var wrong = false;
      while (true) {
        final request = KeyPassphraseRequest(
          hop: hop.label,
          path: file.configured,
          publicKey: file.publicKey,
          wrong: wrong,
        );
        final passphrase = await ask(request);
        if (passphrase == null) {
          throw SshConnectException(hop, SshFailure.keyUnavailable, 'no passphrase for ${file.configured}');
        }
        try {
          return _unlocked[file.path] = await Isolate.run(() => decodeKeyPairs(pem, passphrase).first);
        } on SshKeyException catch (error) {
          if (error.problem != SshKeyProblem.wrongPassphrase) rethrow;
          wrong = true;
        }
      }
    } on SshKeyException catch (error) {
      throw SshConnectException(hop, SshFailure.keyUnavailable, '${file.configured}: ${error.message}', cause: error);
    }
  }

  Future<SSHSocket> _connectTcp(SshHop hop) async {
    try {
      return await SSHSocket.connect(hop.host, hop.port, timeout: timeout);
    } on SocketException catch (error) {
      throw SshConnectException(hop, SshFailure.unreachable, 'cannot connect to ${hop.host}:${hop.port}', cause: error);
    }
  }

  Future<SSHSocket> _forward(SSHClient via, SshHop viaHop, SshHop hop) async {
    try {
      return await via.forwardLocal(hop.host, hop.port).timeout(timeout);
    } on TimeoutException catch (error) {
      throw SshConnectException(
        hop,
        SshFailure.timeout,
        '${viaHop.label} did not reach ${hop.host}:${hop.port}',
        cause: error,
      );
    } on SSHChannelOpenError catch (error) {
      throw SshConnectException(
        hop,
        SshFailure.unreachable,
        '${viaHop.label} cannot reach ${hop.host}:${hop.port}: ${error.description}',
        cause: error,
      );
    } on SSHError catch (error) {
      throw SshConnectException(hop, SshFailure.unreachable, 'connection to ${viaHop.label} lost', cause: error);
    }
  }

  Future<SSHClient> _handshake(SshHop hop, int index, SSHSocket socket, _Auth auth) async {
    final tap = HostKeyTap(socket);
    late final _Deadline deadline;
    SshConnectException? verdict;
    // Tells a hung key exchange from a server that stops answering once asked to authenticate.
    var phase = 'key exchange';
    Future<bool> verifyHostKey(String type, Uint8List fingerprintBytes) async {
      final fingerprint = utf8.decode(fingerprintBytes);
      final blob = tap.hostKey(fingerprint);
      if (blob == null) {
        verdict = SshConnectException(hop, SshFailure.protocol, 'host key $fingerprint missing from the key exchange');
        return false;
      }
      // Extra connections to a hop must present the key accepted for the first one.
      final accepted = _acceptedHostKeys[index];
      if (accepted != null) {
        if (accepted == fingerprint) return true;
        verdict = SshConnectException(
          hop,
          SshFailure.hostKeyRejected,
          'host key changed from $accepted to $fingerprint',
        );
        return false;
      }
      final check = HostKeyCheck(
        host: hop.host,
        port: hop.port,
        keyType: keyBlobType(blob),
        keyBlob: blob,
        sha256Fingerprint: fingerprint,
      );
      final bool trusted;
      try {
        trusted = await deadline.pausedWhile(() => _verify(check));
      } on Object catch (error) {
        verdict = SshConnectException(hop, SshFailure.hostKeyRejected, 'host key check failed', cause: error);
        return false;
      }
      if (!trusted) {
        verdict = SshConnectException(hop, SshFailure.hostKeyRejected, 'host key $fingerprint is not trusted');
        return false;
      }
      _acceptedHostKeys[index] = fingerprint;
      phase = 'authentication';
      return true;
    }

    final respond = auth.respond;
    final onPassword = auth.onPassword;
    final client = SSHClient(
      tap,
      username: hop.user,
      onVerifyHostKey: verifyHostKey,
      identities: auth.identities,
      onPasswordRequest: onPassword == null ? null : () => auth.waits.run(onPassword),
      onUserInfoRequest: respond == null
          ? null
          : (request) async {
              // OpenSSH ends a PAM conversation with an empty round; only one with text reaches the user.
              if (request.prompts.isEmpty && request.name.isEmpty && request.instruction.isEmpty) return const [];
              return auth.waits.run(
                () => respond(
                  KeyboardInteractiveRequest(
                    hop: hop.label,
                    name: request.name,
                    instruction: request.instruction,
                    prompts: [
                      for (final prompt in request.prompts)
                        KeyboardInteractivePrompt(prompt.promptText, echo: prompt.echo),
                    ],
                    refused: auth.offer,
                  ),
                ),
              );
            },
      onUserauthBanner: _onBanner == null ? null : (banner) => _onBanner(hop, banner),
      keepAliveInterval: null,
      algorithms: _algorithms,
    );
    deadline = _Deadline(timeout, () => unawaited(client.close()));
    auth.waits.deadline = deadline;
    try {
      await client.authenticated;
      return client;
    } on Object catch (error) {
      unawaited(client.close());
      socket.destroy();
      throw switch (auth.waits.abort) {
        SshAgentException(:final message) && final abort => SshConnectException(
          hop,
          SshFailure.keyUnavailable,
          message,
          cause: abort,
        ),
        final abort? => abort,
        null => verdict ?? _classify(hop, error, auth.offer, timedOut: deadline.expired, phase: phase),
      };
    } finally {
      deadline.cancel();
    }
  }

  SshConnectException _classify(
    SshHop hop,
    Object error,
    SshKeyOffer? offer, {
    required bool timedOut,
    required String phase,
  }) {
    if (timedOut) {
      final message = 'no answer during $phase within ${_seconds(timeout)}';
      return SshConnectException(hop, SshFailure.timeout, message, cause: error);
    }
    final reason = error is SSHAuthAbortError ? error.reason : error;
    return switch (reason) {
      // SSH_DISCONNECT_NO_MORE_AUTH_METHODS_AVAILABLE, e.g. "Too many authentication failures".
      SSHAuthFailError() || SSHDisconnectError(reasonCode: 14) => SshConnectException(
        hop,
        SshFailure.authFailed,
        offer?.describe() ?? (reason is SSHDisconnectError ? reason.message : 'authentication failed'),
        offer: offer,
        cause: error,
      ),
      SSHHostkeyError(:final message) => SshConnectException(hop, SshFailure.hostKeyRejected, message, cause: error),
      SSHSocketError() => SshConnectException(
        hop,
        SshFailure.unreachable,
        'connection lost during handshake',
        cause: error,
      ),
      _ => SshConnectException(hop, SshFailure.protocol, 'SSH handshake failed', cause: error),
    };
  }

  static String _seconds(Duration duration) =>
      duration.inMilliseconds % 1000 == 0 ? '${duration.inSeconds} s' : '${duration.inMilliseconds} ms';
}

/// An identity file `ssh -G` named for a hop, read before dialing.
final class _IdentityFile {
  const _IdentityFile(this.configured, this.path, this.pem, this.publicKey);

  final String configured;
  final String path;

  /// Null when only the public key is there, for a key the agent holds.
  final String? pem;

  /// Null for an encrypted PEM key without a `.pub`.
  final SshPublicKey? publicKey;
}

/// Where auth callbacks wait for the user (prompts, passphrases, agent confirmations): the handshake's deadline stops
/// meanwhile, and an error a callback throws ends the attempt with that error.
final class _UserWaits {
  _Deadline? deadline;
  Object? abort;

  Future<T> run<T>(Future<T> Function() action) async {
    try {
      final deadline = this.deadline;
      return await (deadline == null ? action() : deadline.pausedWhile(action));
    } on Object catch (error) {
      abort ??= error;
      rethrow;
    }
  }
}

final class _Auth {
  _Auth(this.waits, {this.identities, this.onPassword, this.respond, this.agent, this.offer});

  /// [identities] first; once the server refused them (or there were none), its password and keyboard-interactive
  /// prompts go to [fallback], like `ssh` asks, until the user gives up on one.
  factory _Auth.offering(
    SshHop hop,
    _UserWaits waits,
    SshKeyOffer offer,
    KeyboardInteractiveHandler? fallback, {
    required List<SSHIdentity> identities,
    SshAgentClient? agent,
  }) {
    if (fallback == null) return _Auth(waits, identities: identities, agent: agent, offer: offer);
    var gaveUp = false;
    Future<List<String>?> ask(KeyboardInteractiveRequest request) async {
      if (gaveUp) return null;
      final answers = await fallback(request);
      gaveUp = answers == null;
      return answers;
    }

    return _Auth(
      waits,
      identities: identities,
      agent: agent,
      offer: offer,
      onPassword: () async {
        final answers = await ask(
          KeyboardInteractiveRequest(
            hop: hop.label,
            name: '',
            instruction: '',
            prompts: const [KeyboardInteractivePrompt('Password:', echo: false)],
            password: true,
            refused: offer,
          ),
        );
        return answers?.firstOrNull;
      },
      respond: ask,
    );
  }

  final _UserWaits waits;
  final List<SSHIdentity>? identities;
  final Future<String?> Function()? onPassword;
  final KeyboardInteractiveHandler? respond;
  final SshAgentClient? agent;

  /// The keys offered, for the error when the hop refuses them and for the prompts that follow.
  final SshKeyOffer? offer;
}

/// A timeout that stops while the user answers a prompt and restarts in full afterwards.
final class _Deadline {
  _Deadline(this._duration, this._onExpired) {
    _arm();
  }

  final Duration _duration;
  final void Function() _onExpired;
  Timer? _timer;
  var _paused = 0;
  var _cancelled = false;
  var expired = false;

  Future<T> pausedWhile<T>(Future<T> Function() action) async {
    _timer?.cancel();
    _paused++;
    try {
      return await action();
    } finally {
      _paused--;
      if (_paused == 0 && !_cancelled && !expired) _arm();
    }
  }

  void cancel() {
    _cancelled = true;
    _timer?.cancel();
  }

  void _arm() {
    _timer = Timer(_duration, () {
      expired = true;
      _onExpired();
    });
  }
}

final class _SshProcess implements HostProcess {
  _SshProcess(this._session) {
    unawaited(_session.done.then((_) => _closed = true));
  }

  final SSHSession _session;
  var _closed = false;

  @override
  Stream<Uint8List> get stdout => _session.stdout;

  @override
  Stream<Uint8List> get stderr => _session.stderr;

  @override
  void write(List<int> bytes) => _session.stdin.add(bytes is Uint8List ? bytes : Uint8List.fromList(bytes));

  @override
  Future<void> closeStdin() async => _session.stdin.close();

  @override
  Future<HostExit> get exit =>
      _session.done.then((_) => HostExit(code: _session.exitCode, signal: _session.exitSignal?.signalName));

  @override
  void resize(int columns, int rows) {
    if (!_closed) _session.resizeTerminal(columns, rows);
  }

  @override
  void kill() {
    if (!_closed) _session.kill(SSHSignal.TERM);
  }

  @override
  Future<void> close() async {
    if (!_closed) _session.close();
    await _session.done;
  }
}

final class _SftpFiles implements HostFiles {
  _SftpFiles(this._sftp, this._label, this._onClose);

  final SftpClient _sftp;
  final String _label;
  final void Function() _onClose;
  var _closed = false;

  @override
  Future<HostFileStat?> stat(String path, {bool followLinks = true}) async {
    try {
      return _toStat(await _sftp.stat(path, followLink: followLinks));
    } on SftpStatusError catch (error) {
      if (error.code == SftpStatusCode.noSuchFile) return null;
      throw _error('stat', path, error);
    } on Object catch (error) {
      throw _error('stat', path, error);
    }
  }

  /// OpenSSH's sftp-server describes READDIR entries with lstat, so links arrive as links.
  @override
  Future<List<HostDirEntry>> list(String path) => _run('list', path, () async {
    return [
      for (final name in await _sftp.listdir(path))
        if (name.filename != '.' && name.filename != '..') HostDirEntry(name.filename, _toStat(name.attr)),
    ];
  });

  @override
  Future<Uint8List> read(String path, {int offset = 0, int? length}) => _run('read', path, () async {
    final file = await _sftp.open(path);
    try {
      return await file.readBytes(offset: offset, length: length);
    } finally {
      await file.close();
    }
  });

  @override
  Future<void> write(String path, List<int> bytes, {bool append = false, int? mode}) => _run('write', path, () async {
    final data = bytes is Uint8List ? bytes : Uint8List.fromList(bytes);
    final created = mode == null ? null : await _createExclusive(path);
    final file =
        created ??
        await _sftp.open(
          path,
          mode:
              SftpFileOpenMode.write |
              SftpFileOpenMode.create |
              (append ? SftpFileOpenMode.append : SftpFileOpenMode.truncate),
        );
    try {
      // Permissions go on before any byte is written, so a secret is never readable by others.
      if (created != null) await file.setStat(SftpFileAttrs(mode: SftpFileMode.value(mode!)));
      // OpenSSH's sftp-server appends regardless of offset; other servers honour the offset.
      final offset = append && created == null ? (await file.stat()).size ?? 0 : 0;
      await file.writeBytes(data, offset: offset);
    } finally {
      await file.close();
    }
  });

  /// Null when [path] already exists.
  Future<SftpFile?> _createExclusive(String path) async {
    try {
      return await _sftp.open(
        path,
        mode: SftpFileOpenMode.write | SftpFileOpenMode.create | SftpFileOpenMode.exclusive,
      );
    } on SftpStatusError catch (error) {
      // SFTPv3 has no "already exists" status: OpenSSH reports EEXIST as a generic failure.
      if (error.code == SftpStatusCode.failure && await stat(path) != null) return null;
      rethrow;
    }
  }

  @override
  Future<void> mkdir(String path, {int? mode}) async {
    final attrs = mode == null ? null : SftpFileAttrs(mode: SftpFileMode.value(mode));
    // A lock holder may remove the directory between our failed mkdir and the stat: try once more.
    for (var attempt = 1; ; attempt++) {
      try {
        await _sftp.mkdir(path, attrs);
        return;
      } on SftpStatusError catch (error) {
        // SFTPv3 has no "already exists" status: OpenSSH reports EEXIST as a generic failure.
        if (await stat(path) != null) throw HostFileExists(path);
        if (attempt == 2) throw _error('mkdir', path, error);
      } on Object catch (error) {
        throw _error('mkdir', path, error);
      }
    }
  }

  @override
  Future<void> remove(String path) => _run('remove', path, () => _sftp.remove(path));

  @override
  Future<void> removeDir(String path) => _run('rmdir', path, () => _sftp.rmdir(path));

  @override
  Future<void> rename(String from, String to) => _run('rename', '$from -> $to', () => _sftp.rename(from, to));

  @override
  Future<String> home() => _run('realpath', '.', () => _sftp.absolute('.'));

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _sftp.close();
    _onClose();
  }

  Future<T> _run<T>(String action, String path, Future<T> Function() body) async {
    try {
      return await body();
    } on HostLinkException {
      rethrow;
    } on Object catch (error) {
      throw _error(action, path, error);
    }
  }

  HostLinkException _error(String action, String path, Object error) {
    final detail = error is SftpError ? ': ${error.message}' : '';
    return HostLinkException('$_label: $action $path$detail', cause: error);
  }

  static HostFileStat _toStat(SftpFileAttrs attrs) => HostFileStat(
    size: attrs.size ?? 0,
    isDirectory: attrs.isDirectory,
    isLink: attrs.isSymbolicLink,
    modified: attrs.modifyTime == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(attrs.modifyTime! * 1000, isUtc: true),
    mode: attrs.mode?.value,
  );
}

final class _SshSocket implements HostSocket {
  _SshSocket(this._channel);

  final SSHForwardChannel _channel;

  @override
  late final Stream<Uint8List> input = _channel.stream;

  @override
  void add(List<int> bytes) => _channel.sink.add(bytes);

  @override
  Future<void> get done => _channel.done;

  /// Sends EOF after the bytes already added; [done] completes when the far end closes too.
  @override
  Future<void> close() async => _channel.sink.close();
}

/// dartssh2's defaults with chacha20-poly1305 first, as OpenSSH orders it. dartssh2's ciphers are pure Dart: its
/// AES-GCM moves 0.8 MB/s, chacha20-poly1305 13.8 MB/s (a 4 MB `exec` to the SSH test machine on an M-series Mac), so
/// a 7.6 MB session history took 16 s to open with GCM first.
const _algorithms = SSHAlgorithms(
  cipher: [
    SSHCipherType.chacha20poly1305,
    SSHCipherType.aes256gcm,
    SSHCipherType.aes128gcm,
    SSHCipherType.aes256ctr,
    SSHCipherType.aes128ctr,
  ],
);
