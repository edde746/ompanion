/// Everything [RpcClient] throws.
sealed class RpcException implements Exception {
  String get message;
}

/// omp answered a command with `success: false`.
final class RpcCommandException implements RpcException {
  RpcCommandException(this.command, this.message, this.code);

  final String command;
  @override
  final String message;

  /// Machine-readable reason when omp sends one, e.g. `session_busy`, `stale_cursor`, `unknown_since`.
  final String? code;

  @override
  String toString() => 'RpcCommandException($command${code == null ? '' : ', $code'}): $message';
}

/// The stream from omp broke the protocol: a malformed line after `ready`, an invalid `rpc_chunk`
/// sequence, a response that does not match its request, or a failed negotiation.
final class RpcProtocolException implements RpcException {
  RpcProtocolException(this.message);

  @override
  final String message;

  @override
  String toString() => 'RpcProtocolException: $message';
}

/// The client stopped before the request got its answer: the channel ended or failed, or the
/// client was closed.
final class RpcClosedException implements RpcException {
  RpcClosedException(this.message, {this.cause});

  @override
  final String message;
  final Object? cause;

  @override
  String toString() => 'RpcClosedException: $message${cause == null ? '' : ' ($cause)'}';
}
