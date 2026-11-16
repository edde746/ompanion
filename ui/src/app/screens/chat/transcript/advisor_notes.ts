import { isJsonObject } from "../../../../core/rpc/json_fields";

/** omp's advisor-note severities, weakest first. A missing severity is a plain `note`. */
export type AdvisorSeverity = "note" | "nit" | "concern" | "blocker";

/** One note from an `advisor` custom message's `details.notes`. */
export interface AdvisorNote {
  readonly note: string;
  readonly severity?: AdvisorSeverity;
  readonly advisor?: string;
  readonly turnsAgo?: number;
}

function isAdvisorSeverity(value: unknown): value is AdvisorSeverity {
  return value === "note" || value === "nit" || value === "concern" || value === "blocker";
}

/** Notes from an `advisor` custom message's `details.notes`. */
export function advisorNotesFromDetails(details: unknown): AdvisorNote[] {
  if (!isJsonObject(details) || !Array.isArray(details.notes)) return [];
  const notes: AdvisorNote[] = [];
  for (const item of details.notes) {
    if (!isJsonObject(item) || typeof item.note !== "string") continue;
    const advisor = typeof item.advisor === "string" && item.advisor.length > 0 ? item.advisor : undefined;
    const severity = isAdvisorSeverity(item.severity) ? item.severity : undefined;
    const turnsAgo = typeof item.turnsAgo === "number" && Number.isFinite(item.turnsAgo) ? item.turnsAgo : undefined;
    notes.push({
      note: item.note,
      ...(advisor !== undefined ? { advisor } : {}),
      ...(severity !== undefined ? { severity } : {}),
      ...(turnsAgo !== undefined ? { turnsAgo } : {}),
    });
  }
  return notes;
}
