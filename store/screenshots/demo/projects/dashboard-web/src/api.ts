export interface UploadResult {
  key: string;
  bytes: number;
}

/** Sends one file and returns the key the server stored it under. */
export async function upload(file: File): Promise<UploadResult> {
  const response = await fetch("/upload", { method: "POST", body: file });
  if (response.status === 429) {
    const retryAfter = Number(response.headers.get("retry-after") ?? "1");
    throw new RetryLater(retryAfter * 1000);
  }
  if (!response.ok) throw new Error(`upload failed: ${response.status}`);
  return (await response.json()) as UploadResult;
}

export class RetryLater extends Error {
  constructor(readonly delayMs: number) {
    super(`retry in ${delayMs} ms`);
  }
}
