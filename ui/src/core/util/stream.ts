import { deferred } from "../../deferred";

// Dart's Stream and StreamController, as far as the ported core uses them. An EventStream is a recipe: each listen
// subscribes anew through the function it was built with. An Emitter is the controller: `buffered` behaves like a
// single-subscription controller (events wait for the first listener), else like a broadcast one (events without a
// listener are dropped).

export interface Subscription {
  cancel(): void;
}

export interface Sink<T> {
  data(value: T): void;
  error(error: Error): void;
  done(): void;
}

export interface ListenOptions {
  error?(error: Error): void;
  done?(): void;
  /** As Dart's: the first error ends the subscription (`done` is not called). */
  cancelOnError?: boolean;
}

function toError(error: unknown): Error {
  return error instanceof Error ? error : new Error(String(error));
}

export class EventStream<T> {
  /** [subscribe] starts delivering to the sink and returns the function that stops it. */
  constructor(private readonly subscribe: (sink: Sink<T>) => () => void) {}

  /** An error without an error handler is rethrown asynchronously, as Dart reports an unhandled stream error. */
  listen(data: (value: T) => void, options: ListenOptions = {}): Subscription {
    let open = true;
    let stop: (() => void) | undefined;
    const sink: Sink<T> = {
      data: (value) => {
        if (open) data(value);
      },
      error: (error) => {
        if (!open) return;
        if (options.cancelOnError) {
          open = false;
          stop?.();
        }
        if (options.error) options.error(error);
        else queueMicrotask(() => {
          throw error;
        });
      },
      done: () => {
        if (!open) return;
        open = false;
        stop?.();
        options.done?.();
      },
    };
    stop = this.subscribe(sink);
    if (!open) stop();
    return {
      cancel: () => {
        if (!open) return;
        open = false;
        stop?.();
      },
    };
  }

  map<U>(transform: (value: T) => U): EventStream<U> {
    return new EventStream<U>((sink) => {
      const subscription = this.listen(
        (value) => {
          let mapped: U;
          try {
            mapped = transform(value);
          } catch (error) {
            sink.error(toError(error));
            return;
          }
          sink.data(mapped);
        },
        { error: sink.error, done: sink.done },
      );
      return () => subscription.cancel();
    });
  }

  where(test: (value: T) => boolean): EventStream<T> {
    return new EventStream<T>((sink) => {
      const subscription = this.listen((value) => test(value) && sink.data(value), { error: sink.error, done: sink.done });
      return () => subscription.cancel();
    });
  }

  /** The first event; rejects with the first error, or when the stream ends empty. */
  first(): Promise<T> {
    const result = deferred<T>();
    let settled = false;
    // A buffered stream delivers during listen, before `subscription` is assigned.
    let subscription: Subscription | undefined;
    subscription = this.listen(
      (value) => {
        if (settled) return;
        settled = true;
        subscription?.cancel();
        result.resolve(value);
      },
      {
        cancelOnError: true,
        error: result.reject,
        done: () => result.reject(new Error("stream ended without an event")),
      },
    );
    if (settled) subscription.cancel();
    return result.promise;
  }

  /** Every event until the stream ends; rejects with the first error. */
  toArray(): Promise<T[]> {
    const values: T[] = [];
    const result = deferred<T[]>();
    this.listen((value) => values.push(value), {
      cancelOnError: true,
      error: result.reject,
      done: () => result.resolve(values),
    });
    return result.promise;
  }

  /** `for await` over the events: an error ends the loop by throwing; breaking out cancels the subscription. */
  [Symbol.asyncIterator](): AsyncIterator<T> {
    const queue: T[] = [];
    let failure: Error | undefined;
    let ended = false;
    let wake: (() => void) | undefined;
    const notify = () => {
      wake?.();
      wake = undefined;
    };
    const subscription = this.listen(
      (value) => {
        queue.push(value);
        notify();
      },
      {
        cancelOnError: true,
        error: (error) => {
          failure = error;
          notify();
        },
        done: () => {
          ended = true;
          notify();
        },
      },
    );
    return {
      next: async (): Promise<IteratorResult<T>> => {
        for (;;) {
          if (queue.length > 0) return { value: queue.shift() as T, done: false };
          if (failure) throw failure;
          if (ended) return { value: undefined, done: true };
          const woken = deferred<void>();
          wake = () => woken.resolve();
          await woken.promise;
        }
      },
      return: async (): Promise<IteratorResult<T>> => {
        subscription.cancel();
        ended = true;
        return { value: undefined, done: true };
      },
    };
  }

  static empty<T>(): EventStream<T> {
    return new EventStream<T>((sink) => {
      sink.done();
      return () => {};
    });
  }

  static fromPromise<T>(promise: Promise<T>): EventStream<T> {
    return new EventStream<T>((sink) => {
      promise.then(
        (value) => {
          sink.data(value);
          sink.done();
        },
        (error) => sink.error(toError(error)),
      );
      return () => {};
    });
  }
}

type Event<T> = { kind: "data"; value: T } | { kind: "error"; error: Error } | { kind: "done" };

export class Emitter<T> {
  private readonly sinks = new Set<Sink<T>>();
  private pending: Event<T>[] | undefined;
  private isClosed = false;

  /** With [buffered], events wait for the first listener, and only one listener may subscribe. */
  constructor(options: { buffered?: boolean } = {}) {
    if (options.buffered) this.pending = [];
    const buffered = options.buffered ?? false;
    let subscribed = false;
    this.stream = new EventStream<T>((sink) => {
      if (buffered) {
        if (subscribed) throw new Error("Emitter: a buffered stream has a single listener");
        subscribed = true;
      }
      this.sinks.add(sink);
      const queued = this.pending ?? [];
      this.pending = undefined;
      for (const event of queued) this.deliver(sink, event);
      if (this.isClosed && queued.every((event) => event.kind !== "done")) sink.done();
      return () => this.sinks.delete(sink);
    });
  }

  readonly stream: EventStream<T>;

  get closed(): boolean {
    return this.isClosed;
  }

  get hasListener(): boolean {
    return this.sinks.size > 0;
  }

  add(value: T): void {
    this.emit({ kind: "data", value });
  }

  addError(error: unknown): void {
    this.emit({ kind: "error", error: toError(error) });
  }

  close(): void {
    if (this.isClosed) return;
    this.emit({ kind: "done" });
    this.isClosed = true;
  }

  private emit(event: Event<T>) {
    if (this.isClosed) throw new Error("Emitter: add after close");
    if (this.pending) {
      this.pending.push(event);
      return;
    }
    for (const sink of [...this.sinks]) this.deliver(sink, event);
    if (event.kind === "done") this.sinks.clear();
  }

  private deliver(sink: Sink<T>, event: Event<T>) {
    if (event.kind === "data") sink.data(event.value);
    else if (event.kind === "error") sink.error(event.error);
    else sink.done();
  }
}
