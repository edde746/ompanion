// The decisions of lib/screens/chat/request_panel.dart, apart from its markup in request_panel.tsx: a request's title,
// what the user entered into it, which open request the panel shows, what an approval shows, and the composer's part.
import type { LiveSession } from "../../../core/session/live_session";
import {
  type ApprovalRequest,
  type SessionView,
  sessionViewToolResults,
  type UiRequest,
} from "../../../core/store/session_view";
import { t } from "../../i18n/i18n";
import type { AskDraft } from "./ask";
import type { FieldDraft } from "./html_form";

/** A one-line title for `request`. */
export function requestTitle(request: UiRequest): string {
  switch (request.kind) {
    case "ApprovalRequest":
      return t.requests.approvalTitle({ tool: request.toolName });
    case "SelectRequest":
    case "ConfirmRequest":
    case "InputRequest":
    case "EditorRequest":
      return request.title;
    case "EditorTextRequest":
      return t.requests.editorText;
    case "OpenUrlRequest":
      return t.requests.openUrlTitle;
    case "CompanionRequest":
      return request.method === "ask" || request.method === "form" ? t.ask.title : request.method;
  }
}

/** What the user entered into one request so far. RequestPanel keeps it while another request is shown. */
export interface RequestDraft {
  /** The input's or the editor's text. */
  text: string;
  /** The `ask` form's answers, one per question; filled when the form first shows. */
  ask: readonly AskDraft[];
  /** The `form` request's answers, one per field; filled when the form first shows. */
  form: readonly FieldDraft[];
}

export function requestDraft(request: UiRequest): RequestDraft {
  return { text: request.kind === "EditorRequest" ? (request.prefill ?? "") : "", ask: [], form: [] };
}

/** The requests the panel lists and the one it shows. */
export interface ShownRequests {
  /** Every open request but `set_editor_text`, which fills the composer instead. */
  readonly requests: readonly UiRequest[];
  /** The shown request; when it settles, the one that takes its place is shown. */
  readonly id: string | undefined;
  readonly index: number;
}

export const noShownRequests: ShownRequests = { requests: [], id: undefined, index: 0 };

/** The panel after the open requests became `requests`: the shown one stays shown while it is open. */
export function followRequests(previous: ShownRequests, requests: readonly UiRequest[]): ShownRequests {
  const shown = requests.filter((request) => request.kind !== "EditorTextRequest");
  const index = shown.findIndex((request) => request.id === previous.id);
  if (index >= 0) return { requests: shown, id: previous.id, index };
  const clamped = Math.min(previous.index, shown.length - 1);
  const next = shown[clamped];
  return next === undefined ? { requests: shown, id: undefined, index: 0 } : { requests: shown, id: next.id, index: clamped };
}

/** Shows the request at `index` of the list. */
export function showRequest(shown: ShownRequests, index: number): ShownRequests {
  return { ...shown, id: shown.requests[index]?.id, index };
}

/** What the panel uses of SessionsProvider. */
export interface RequestPanelSessions {
  setDraft(session: LiveSession, text: string): void;
  draftOf(session: LiveSession): { requestFocus(): void };
}

/**
 * The composer's part in a change of `session`'s open requests to `requests`: `set_editor_text` fills it and leaves the
 * view, and once no request is left (`hadRequests` and now none) it takes the focus back, as the TUI returns to its
 * editor.
 */
export function updateComposer(
  session: LiveSession,
  sessions: RequestPanelSessions,
  requests: readonly UiRequest[],
  hadRequests: boolean,
): void {
  for (const request of requests) {
    if (request.kind !== "EditorTextRequest") continue;
    sessions.setDraft(session, request.text);
    session.dismissRequest(request.id);
  }
  if (hadRequests && requests.every((request) => request.kind === "EditorTextRequest")) {
    sessions.draftOf(session).requestFocus();
  }
}

/**
 * Every label omp offers but `Deny` approves: `Approve`, `Approve Once`, `Approve <tool> for this session`, and since
 * 18.12.3 the grants (`Approve File`, `Always Approve Directory: <dir>`, …).
 */
export function isApproveOption(option: string): boolean {
  const label = option.toLowerCase();
  return label.startsWith("approve") || label.startsWith("always approve") || label === "allow";
}

/** What an approval shows of the call it gates. */
export interface ApprovalShown {
  /** The call's harness intent, the heading. */
  readonly intent?: string;
  /** The call's command, else its arguments as indented JSON. */
  readonly call?: string;
  /** omp's detail lines that do not repeat an argument. */
  readonly details: readonly string[];
}

export function approvalShown(request: ApprovalRequest, view: SessionView): ApprovalShown {
  const call = request.toolCallId === undefined ? undefined : sessionViewToolResults(view).get(request.toolCallId);
  const args = call?.args;
  const map = isMap(args) ? args : undefined;
  const command = typeof map?.command === "string" ? map.command : undefined;
  // `i` is the intent every built-in tool takes; it shows as the heading instead.
  const shownArgs = map === undefined ? args : Object.fromEntries(Object.entries(map).filter(([key]) => key !== "i"));
  // omp's detail lines repeat the arguments ("Command: ls -la"); the block above shows those already.
  const argValues = new Set(
    Object.values(map ?? {}).flatMap((value) => (typeof value === "string" ? [value.trim()] : [])),
  );
  return {
    intent: call?.intent,
    call: command ?? (shownArgs === undefined ? undefined : JSON.stringify(shownArgs, null, 2)),
    details: request.details.filter((line) => line.trim().length > 0 && !repeatsArgument(line, argValues)),
  };
}

function isMap(value: unknown): value is { readonly [key: string]: unknown } {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

/** True when `line` is `Label: value` (or just `value`) for one of the call's string arguments. */
function repeatsArgument(line: string, values: ReadonlySet<string>): boolean {
  const trimmed = line.trim();
  if (values.has(trimmed)) return true;
  const colon = trimmed.indexOf(": ");
  return colon > 0 && values.has(trimmed.substring(colon + 2).trim());
}
