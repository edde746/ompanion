import { deferred } from "../../deferred";

/** Dart's `Future.ignore()`: the caller does not want [promise]'s result or error, and says so. */
export function ignore(promise: Promise<unknown>): void {
  promise.catch(() => undefined);
}

/** Dart's `Future.delayed`. */
export function delay(ms: number): Promise<void> {
  const done = deferred<void>();
  setTimeout(() => done.resolve(), ms);
  return done.promise;
}

/** Dart's TimeoutException, from [withTimeout]. */
export class TimeoutException extends Error {
  constructor(
    message: string,
    readonly durationMs: number,
  ) {
    super(message);
    this.name = "TimeoutException";
  }
}

/**
 * Dart's `Future.timeout`: settles as [promise] does, or after [ms] with [onTimeout]'s result, or without
 * [onTimeout] rejects with a [TimeoutException]. [promise] keeps running either way.
 */
export function withTimeout<T>(promise: Promise<T>, ms: number, onTimeout?: () => T | Promise<T>): Promise<T> {
  const result = deferred<T>();
  const timer = setTimeout(() => {
    if (!onTimeout) {
      result.reject(new TimeoutException(`no result within ${ms} ms`, ms));
      return;
    }
    Promise.resolve()
      .then(onTimeout)
      .then(result.resolve, (error: unknown) => result.reject(error instanceof Error ? error : new Error(String(error))));
  }, ms);
  promise.then(
    (value) => {
      clearTimeout(timer);
      result.resolve(value);
    },
    (error: unknown) => {
      clearTimeout(timer);
      result.reject(error instanceof Error ? error : new Error(String(error)));
    },
  );
  return result.promise;
}
