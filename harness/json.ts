/** The one object guard for JSON parsed at the testing tools' boundaries. */
export function isRecord(value: unknown): value is Record<string, unknown> {
	return typeof value === "object" && value !== null && !Array.isArray(value);
}
