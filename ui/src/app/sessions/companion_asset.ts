// lib/sessions/companion_asset.dart: the companion extension the app uploads to every machine (docs/PLAN.md §6). A
// build artifact: `scripts/build_companion.sh` builds `companion/` into `ui/companion/ompx.js`, which the page
// bundles as a chunk of its own, loaded on the first upload rather than with the page.

/** The bundle is empty in this build. */
export class CompanionMissing extends Error {
  constructor() {
    super("This build has no companion (ui/companion/ompx.js). Run scripts/build_companion.sh, then rebuild the app.");
    this.name = "CompanionMissing";
  }
}

/**
 * The bundled companion for a machine running omp `ompVersion`. One build serves every supported omp release (18.3.1
 * onward); the companion feature-checks what it uses. Throws {@link CompanionMissing}, which the machine runtime
 * reports as its status.
 */
export async function bundledCompanion(_ompVersion: string): Promise<Uint8Array> {
  const { default: text } = await import("../../../companion/ompx.js?raw");
  if (text.length === 0) throw new CompanionMissing();
  return new TextEncoder().encode(text);
}
