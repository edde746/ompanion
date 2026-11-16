import { isJsonObject } from "../../../../core/rpc/json_fields";

/** How strongly omp's advisor weighs a note (its `advise` tool); a note without one is a plain note. */
export type AdvisorSeverity = "nit" | "concern" | "blocker";

/** One entry of an `advisor` custom message's `details.notes`, as omp's advisor card shows it. */
export interface AdvisorNote {
  readonly note: string;
  readonly severity?: AdvisorSeverity;
  /** The advisor's name; absent for omp's `default` advisor, which the card does not name. */
  readonly advisor?: string;
  /** Turns between the turn the note is about and its delivery (`T-<n>`). */
  readonly turnsAgo?: number;
}

/** The notes of an `advisor` custom message; entries without a `note` string are skipped. */
export function decodeAdvisorNotes(details: unknown): AdvisorNote[] {
  if (!isJsonObject(details) || !Array.isArray(details.notes)) return [];
  const notes: AdvisorNote[] = [];
  for (const item of details.notes) {
    if (!isJsonObject(item) || typeof item.note !== "string") continue;
    const { severity, advisor, turnsAgo } = item;
    notes.push({
      note: item.note,
      ...(severity === "nit" || severity === "concern" || severity === "blocker" ? { severity } : {}),
      ...(typeof advisor === "string" && advisor !== "" && advisor !== "default" ? { advisor } : {}),
      ...(typeof turnsAgo === "number" && Number.isInteger(turnsAgo) && turnsAgo > 0 ? { turnsAgo } : {}),
    });
  }
  return notes;
}
