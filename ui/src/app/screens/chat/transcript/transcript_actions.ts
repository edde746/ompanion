// Port of lib/screens/chat/transcript/transcript_actions.dart.
import { type Accessor, createContext, createSignal, useContext } from "solid-js";
import type { SessionImages } from "../../../sessions/machine_images";
import type { TreeEntryKind } from "../../dock/tree/session_tree";

/**
 * What the transcript asks of the screen that shows it. Undefined callbacks hide their affordance (a subagent's
 * transcript cannot be branched, a fully seeded one has nothing earlier to load).
 */
export interface TranscriptActions {
  /** Branch the session from the user message with this session entry id. */
  readonly onBranchFrom?: (entryId: string) => void;

  /**
   * Move the session's leaf to the entry with this id (`/tree` in place, companion `tree.navigate`): a user message
   * goes back into the composer, anything else becomes the leaf. `kind` says which the entry is.
   */
  readonly onResetTo?: (entryId: string, kind: TreeEntryKind) => void;

  /** Whether omp will navigate now; a turn that runs makes it refuse. Rows read it in JSX, so they follow it. */
  readonly canReset: boolean;

  /** Put `text` on the clipboard (and confirm it). */
  readonly onCopy: (text: string) => void;

  /** Show a file of the session's machine, optionally at a 1-based `line`. */
  readonly onOpenFile: (path: string, options?: { line?: number }) => void;

  /** Show a task subagent by its id. */
  readonly onOpenSubagent: (id: string) => void;

  /** Load the page of history before the oldest row; resolves when the view holds it. */
  readonly onLoadEarlier?: () => Promise<void>;

  /**
   * Image files of the session's machine that the transcript names by path; undefined where there is no machine to
   * load them from, and such images show their path.
   */
  readonly images?: SessionImages;
}

/**
 * Hands the transcript's actions down to the rows (`TranscriptScope.of`). Rows call the accessor when the user acts;
 * reading `canReset` in JSX follows a run that starts or ends while the row stays (`TranscriptScope.canResetOf`).
 */
export const TranscriptScope = createContext<Accessor<TranscriptActions>>();

/**
 * The transcript's PageStorage: state a row keeps while it leaves the DOM. Rows are windowed, so a row that scrolls
 * far out of view is disposed and built again when it comes back.
 */
export const TranscriptStorage = createContext<Map<string, unknown>>();

/**
 * A signal that starts at the value stored under `id` in the transcript's storage (else `initial`) and stores every
 * write. Call it in a component body.
 */
export function useStoredState<T>(id: string, initial: T): [Accessor<T>, (value: T) => void] {
  const storage = useContext(TranscriptStorage);
  // Boxed: a stored value that is a function would read as a signal's compute function.
  const [state, setState] = createSignal({ value: storage.has(id) ? (storage.get(id) as T) : initial });
  return [
    () => state().value,
    (value: T) => {
      storage.set(id, value);
      setState({ value });
    },
  ];
}
