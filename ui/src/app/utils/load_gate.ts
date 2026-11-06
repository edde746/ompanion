import { deferred } from "../../deferred";

/** A document's one load that later calls wait for: {@link ready} resolves once it loaded, rejects once it failed. */
export class LoadGate {
  private readonly settled = deferred<Error | undefined>();

  /** The first of {@link loaded} and {@link failed} counts. */
  loaded(): void {
    this.settled.resolve(undefined);
  }

  failed(error: unknown): void {
    this.settled.resolve(error instanceof Error ? error : new Error(String(error)));
  }

  /** A promise per call, so a failure nothing waits for is not an unhandled rejection. */
  get ready(): Promise<void> {
    return this.settled.promise.then((error) => {
      if (error !== undefined) throw error;
    });
  }
}
