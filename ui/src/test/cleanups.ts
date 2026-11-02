/**
 * Cleanup steps registered as a test makes what they undo, run newest first by [run]. Every step runs even when an
 * earlier one throws, so a failed test or setup cannot leave a run, a server or a directory behind.
 */
export class Cleanups {
  private readonly steps: Array<() => unknown> = [];

  add(step: () => unknown): void {
    this.steps.push(step);
  }

  async run(): Promise<void> {
    const errors: unknown[] = [];
    for (const step of this.steps.splice(0).reverse()) {
      try {
        await step();
      } catch (error) {
        errors.push(error);
      }
    }
    if (errors.length === 1) throw errors[0];
    if (errors.length > 1) throw new AggregateError(errors, `${errors.length} cleanup steps failed`);
  }
}
