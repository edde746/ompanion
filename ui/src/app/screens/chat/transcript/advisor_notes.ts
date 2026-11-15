import { isJsonObject } from "../../../../core/rpc/json_fields";

/** omp's advisor-note severities, weakest first. */
export const advisorSeverities = ["nit", "concern", "blocker"] as const;

export type AdvisorSeverity = (typeof advisorSeverities)[number];

/** One note from `details.notes` or a parsed `<advisory>` block. */
export interface AdvisorNote {
  readonly note: string;
  readonly severity?: AdvisorSeverity;
  readonly advisor?: string;
  readonly turnsAgo?: number;
}

function isAdvisorSeverity(value: unknown): value is AdvisorSeverity {
  return value === "nit" || value === "concern" || value === "blocker";
}

function unescapeXml(text: string): string {
  return text
    .replace(/&lt;/g, "<")
    .replace(/&gt;/g, ">")
    .replace(/&quot;/g, '"')
    .replace(/&apos;/g, "'")
    .replace(/&amp;/g, "&");
}

function attr(attrs: string, name: string): string | undefined {
  const match = new RegExp(`(?:^|\\s)${name}="([^"]*)"`, "i").exec(attrs);
  if (match === null) return undefined;
  return unescapeXml(match[1] ?? "");
}

function turnsAgoOf(value: string | undefined): number | undefined {
  if (value === undefined || value === "") return undefined;
  const parsed = Number(value);
  return Number.isFinite(parsed) ? parsed : undefined;
}

function noteOf(fields: {
  note: string;
  advisor?: string;
  severity?: AdvisorSeverity;
  turnsAgo?: number;
}): AdvisorNote {
  return {
    note: fields.note,
    ...(fields.advisor !== undefined && fields.advisor.length > 0 ? { advisor: fields.advisor } : {}),
    ...(fields.severity !== undefined ? { severity: fields.severity } : {}),
    ...(fields.turnsAgo !== undefined ? { turnsAgo: fields.turnsAgo } : {}),
  };
}

/** Notes from an `advisor` custom message's `details.notes`. */
export function advisorNotesFromDetails(details: unknown): AdvisorNote[] {
  if (!isJsonObject(details) || !Array.isArray(details.notes)) return [];
  const notes: AdvisorNote[] = [];
  for (const item of details.notes) {
    if (!isJsonObject(item) || typeof item.note !== "string") continue;
    const turnsAgo = typeof item.turnsAgo === "number" && Number.isFinite(item.turnsAgo) ? item.turnsAgo : undefined;
    notes.push(
      noteOf({
        note: item.note,
        advisor: typeof item.advisor === "string" ? item.advisor : undefined,
        severity: isAdvisorSeverity(item.severity) ? item.severity : undefined,
        turnsAgo,
      }),
    );
  }
  return notes;
}

/** The advisor's notes and their tags (`advisorTreeDisplay`, which shows `advisor (<tags>): <notes>`). */
export function advisorTreeNotes(details: unknown): { tags: string; notes: string } {
  const parsed = advisorNotesFromDetails(details);
  const notes: string[] = [];
  const advisors: string[] = [];
  const severities: string[] = [];
  for (const note of parsed) {
    notes.push(note.note);
    const name = note.advisor;
    if (name !== undefined && name.length > 0 && name !== "default" && !advisors.includes(name)) {
      advisors.push(name);
    }
    const severity = note.severity;
    if (severity !== undefined && !severities.includes(severity)) {
      severities.push(severity);
    }
  }
  return { tags: [...advisors, ...severities].join(", "), notes: notes.join(" ") };
}

/** Notes from omp's model-facing `<advisory>` XML, used when `details.notes` is missing. */
export function advisorNotesFromContent(content: string): AdvisorNote[] {
  const notes: AdvisorNote[] = [];
  for (const match of content.matchAll(/<advisory\b([^>]*)>([\s\S]*?)<\/advisory>/gi)) {
    const body = unescapeXml((match[2] ?? "").trim());
    if (body.length === 0) continue;
    const attrs = match[1] ?? "";
    const severity = attr(attrs, "severity");
    notes.push(
      noteOf({
        note: body,
        advisor: attr(attrs, "advisor"),
        severity: isAdvisorSeverity(severity) ? severity : undefined,
        turnsAgo: turnsAgoOf(attr(attrs, "turns_ago") ?? attr(attrs, "turnsAgo")),
      }),
    );
  }
  return notes;
}

/** Last-resort body when content is not a complete `<advisory>` batch: tags stripped, entities unescaped. */
export function stripAdvisoryMarkup(content: string): string {
  return unescapeXml(content.replace(/<\/?advisory\b[^>]*>/gi, "")).trim();
}

/**
 * Notes to show for an advisor custom message: `details.notes` when that field is present, otherwise
 * `<advisory>` blocks from `content`, otherwise the content with those tags stripped.
 */
export function resolveAdvisorNotes(details: unknown, content: string): AdvisorNote[] {
  if (isJsonObject(details) && Array.isArray(details.notes)) return advisorNotesFromDetails(details);
  const fromXml = advisorNotesFromContent(content);
  if (fromXml.length > 0) return fromXml;
  const stripped = stripAdvisoryMarkup(content);
  return stripped.length > 0 ? [noteOf({ note: stripped })] : [];
}
