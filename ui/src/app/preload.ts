// Code the first frame leaves out (lazy screens and dialogs) loads once the app has booted, so its first use does not
// wait for it (docs/research/web-ui/startup.md). Modules register their loaders when they evaluate; main.tsx starts
// them.
const waiting: (() => Promise<unknown>)[] = [];
let started = false;

/** Loads each of `loads` once the app has booted, or now when it has. */
export function preloadAfterBoot(...loads: (() => Promise<unknown>)[]): void {
  if (started) for (const load of loads) run(load);
  else waiting.push(...loads);
}

/** Starts the registered loads, one task each, after the app's boot. */
export function startPreloads(): void {
  started = true;
  for (const load of waiting.splice(0)) run(load);
}

// A load that fails is tried again, and reported, where the code is used.
function run(load: () => Promise<unknown>): void {
  setTimeout(() => void load().catch(() => undefined));
}
