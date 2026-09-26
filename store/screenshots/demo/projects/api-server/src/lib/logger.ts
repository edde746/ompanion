type Level = "debug" | "info" | "warn" | "error";

function write(level: Level, message: string, fields: Record<string, unknown>): void {
  process.stdout.write(`${JSON.stringify({ level, message, time: new Date().toISOString(), ...fields })}\n`);
}

/** One JSON object per line, so the log collector needs no parser. */
export const logger = {
  debug: (message: string, fields: Record<string, unknown> = {}) => write("debug", message, fields),
  info: (message: string, fields: Record<string, unknown> = {}) => write("info", message, fields),
  warn: (message: string, fields: Record<string, unknown> = {}) => write("warn", message, fields),
  error: (message: string, fields: Record<string, unknown> = {}) => write("error", message, fields),
};
