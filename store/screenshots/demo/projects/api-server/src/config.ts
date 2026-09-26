export interface Config {
  port: number;
  maxUploadBytes: number;
  storageDir: string;
}

function positiveNumberFromEnv(name: string, fallback: number): number {
  const raw = process.env[name];
  if (raw === undefined || raw === "") return fallback;
  const value = Number(raw);
  if (!Number.isFinite(value) || value <= 0) throw new Error(`${name} must be a positive number, got ${raw}`);
  return value;
}

export const config: Config = {
  port: positiveNumberFromEnv("PORT", 8080),
  maxUploadBytes: positiveNumberFromEnv("UPLOAD_MAX_BYTES", 32 * 1024 * 1024),
  storageDir: process.env.STORAGE_DIR ?? "./data",
};
