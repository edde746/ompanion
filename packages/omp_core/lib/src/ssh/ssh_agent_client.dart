import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';

import 'keys.dart';
import 'wire.dart';

// draft-miller-ssh-agent message numbers.
const _failure = 5;
const _requestIdentities = 11;
const _identitiesAnswer = 12;
const _signRequest = 13;
const _signResponse = 14;
const _rsaSha256 = 2;

final class SshAgentException implements Exception {
  const SshAgentException(this.message, {this.cause});

  final String message;
  final Object? cause;

  @override
  String toString() => cause == null ? 'SshAgentException($message)' : 'SshAgentException($message: $cause)';
}

/// A connection to a running ssh-agent over its unix socket (POSIX desktops).
///
/// Windows' OpenSSH agent listens on a named pipe, which dart:io cannot open for reading and writing.
final class SshAgentClient {
  SshAgentClient._(this._socket) {
    _subscription = _socket.listen(
      _onData,
      onError: (Object error) => _fail(SshAgentException('ssh-agent connection failed', cause: error)),
      onDone: () => _fail(const SshAgentException('ssh-agent closed the connection')),
    );
  }

  /// Connects to [socketPath], or to `$SSH_AUTH_SOCK` when null.
  static Future<SshAgentClient> connect([String? socketPath]) async {
    final path = socketPath ?? Platform.environment['SSH_AUTH_SOCK'];
    if (path == null || path.isEmpty) throw const SshAgentException('SSH_AUTH_SOCK is not set');
    if (Platform.isWindows) throw const SshAgentException('the Windows OpenSSH agent pipe is not supported');
    try {
      return SshAgentClient._(await Socket.connect(InternetAddress(path, type: InternetAddressType.unix), 0));
    } on SocketException catch (error) {
      throw SshAgentException('cannot reach ssh-agent at $path', cause: error);
    }
  }

  final Socket _socket;
  late final StreamSubscription<Uint8List> _subscription;
  final _replies = Queue<Completer<Uint8List>>();
  var _buffer = Uint8List(0);
  SshAgentException? _error;

  Future<List<SshPublicKey>> identities() async {
    final reader = WireReader(await _request(WireWriter()..writeUint8(_requestIdentities)));
    final type = reader.readUint8();
    if (type != _identitiesAnswer) throw SshAgentException('ssh-agent refused to list keys (reply $type)');
    final count = reader.readUint32();
    final keys = <SshPublicKey>[];
    for (var i = 0; i < count; i++) {
      final blob = Uint8List.fromList(reader.readString());
      keys.add(SshPublicKey(blob, comment: reader.readUtf8()));
    }
    return keys;
  }

  /// Signs [data] with the agent's key [keyBlob]. [flags] 2 and 4 select rsa-sha2-256 and -512.
  Future<Uint8List> sign(Uint8List keyBlob, Uint8List data, {int flags = 0}) async {
    final reader = WireReader(await _request(WireWriter()
      ..writeUint8(_signRequest)
      ..writeString(keyBlob)
      ..writeString(data)
      ..writeUint32(flags)));
    final type = reader.readUint8();
    if (type == _failure) throw const SshAgentException('ssh-agent refused to sign');
    if (type != _signResponse) throw SshAgentException('unexpected ssh-agent reply $type');
    return Uint8List.fromList(reader.readString());
  }

  Future<void> close() async {
    _fail(const SshAgentException('ssh-agent connection closed'));
    await _subscription.cancel();
    _socket.destroy();
  }

  Future<Uint8List> _request(WireWriter message) {
    final error = _error;
    if (error != null) return Future.error(error);
    final reply = Completer<Uint8List>();
    _replies.add(reply);
    _socket.add((WireWriter()..writeString(message.takeBytes())).takeBytes());
    return reply.future;
  }

  void _onData(Uint8List chunk) {
    _buffer = _buffer.isEmpty ? chunk : (BytesBuilder(copy: false)..add(_buffer)..add(chunk)).takeBytes();
    while (_buffer.length >= 4) {
      final length = ByteData.sublistView(_buffer, 0, 4).getUint32(0);
      if (_buffer.length < 4 + length) return;
      final message = Uint8List.fromList(Uint8List.sublistView(_buffer, 4, 4 + length));
      _buffer = Uint8List.sublistView(_buffer, 4 + length);
      if (_replies.isEmpty) return _fail(const SshAgentException('ssh-agent sent an unrequested message'));
      _replies.removeFirst().complete(message);
    }
  }

  void _fail(SshAgentException error) {
    _error ??= error;
    while (_replies.isNotEmpty) {
      _replies.removeFirst().completeError(error);
    }
  }
}

/// Lists the keys a running agent holds.
Future<List<SshPublicKey>> listAgentKeys([String? socketPath]) async {
  final agent = await SshAgentClient.connect(socketPath);
  try {
    return await agent.identities();
  } finally {
    await agent.close();
  }
}

/// dartssh2 identities that sign through [agent]. The server is probed before each signature, so an
/// agent that confirms every use (1Password, Secretive) only prompts for a key the server accepts.
List<SSHIdentity> agentIdentities(SshAgentClient agent, List<SshPublicKey> keys) => [
      for (final key in keys)
        SSHIdentity.custom(
          // RFC 8332: RSA keys sign with SHA-256; OpenSSH 8.8+ refuses SHA-1 `ssh-rsa` signatures.
          type: key.type == 'ssh-rsa' ? 'rsa-sha2-256' : key.type,
          publicKey: SSHRawHostKey(key.blob),
          signer: (data) async =>
              SSHRawSignature(await agent.sign(key.blob, data, flags: key.type == 'ssh-rsa' ? _rsaSha256 : 0)),
          comment: key.comment,
          shouldProbe: true,
        ),
    ];
