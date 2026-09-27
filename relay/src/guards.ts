/** A parsed JSON object. The relay's JSON comes from the network or a file; each field is checked where used. */
export function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}
