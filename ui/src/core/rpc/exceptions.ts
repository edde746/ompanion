// Port of packages/omp_core/lib/src/rpc/exceptions.dart.

/** Everything RpcClient throws. */
export abstract class RpcException extends Error {}

/** omp answered a command with `success: false`. */
export class RpcCommandException extends RpcException {
  constructor(
    readonly command: string,
    message: string,
    /** Machine-readable reason when omp sends one, e.g. `session_busy`, `stale_cursor`, `unknown_since`. */
    readonly code?: string,
  ) {
    super(message);
    this.name = "RpcCommandException";
  }
}

/**
 * The stream from omp broke the protocol: a malformed line after `ready`, an invalid `rpc_chunk` sequence, a response
 * that does not match its request, or a failed negotiation.
 */
export class RpcProtocolException extends RpcException {
  constructor(message: string) {
    super(message);
    this.name = "RpcProtocolException";
  }
}

/** The client stopped before the request got its answer: the channel ended or failed, or the client was closed. */
export class RpcClosedException extends RpcException {
  constructor(message: string, cause?: unknown) {
    super(message, cause === undefined ? undefined : { cause });
    this.name = "RpcClosedException";
  }
}
