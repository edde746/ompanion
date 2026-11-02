import { decimalSeparator } from "./number_format";

/**
 * `tokens` for people: `950`, `1.2K`, `128K`, `1M`, `1.5M`, `17.4B` (German `1,2K`); one decimal unless the value is
 * whole in its unit.
 */
export function formatTokens(tokens: number): string {
  if (tokens < 1000) return `${tokens}`;
  // Rounded to tenths of the unit first, so 999,960 reads `1M` rather than `1000K`.
  const tenthsOfK = Math.round(tokens / 100);
  const tenthsOfM = Math.round(tokens / 100000);
  const [tenths, unit] =
    tenthsOfK < 10000
      ? [tenthsOfK, "K"]
      : tenthsOfM < 10000
        ? [tenthsOfM, "M"]
        : [Math.round(tokens / 100000000), "B"];
  const whole = Math.floor(tenths / 10);
  const decimal = tenths % 10;
  return decimal === 0 ? `${whole}${unit}` : `${whole}${decimalSeparator()}${decimal}${unit}`;
}
