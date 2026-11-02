import { t } from "../i18n/i18n";

/**
 * `durationMs` as omp's TUI writes a loop's time left (`formatLoopLimit`, `status-line/segments.ts`): `1h30m`, `4m30s`,
 * `45s` (German `1 h 30 min`), in whole seconds rounded up.
 */
export function compactDuration(durationMs: number): string {
  const total = Math.max(0, Math.ceil(durationMs / 1000));
  const hours = Math.floor(total / 3600);
  const minutes = Math.floor((total % 3600) / 60);
  const seconds = total % 60;
  const units = t.units;
  const pair = (big: string, small: number, smallUnit: (args: { value: number }) => string) =>
    small > 0 ? units.pair({ big, small: smallUnit({ value: small }) }) : big;
  if (hours > 0) return pair(units.hours({ value: hours }), minutes, units.minutes);
  if (minutes > 0) return pair(units.minutes({ value: minutes }), seconds, units.seconds);
  return units.seconds({ value: seconds });
}
