// The state of lib/screens/dock/tree/tree_tab.dart (_TreeTabState): the tree loaded over RPC, kept fresh while the
// session changes, and the actions on its entries. tree_tab.tsx shows it.
import { type Accessor, createMemo, createSignal } from "solid-js";
import { CompanionException } from "../../../../core/companion/companion_client";
import { RpcException } from "../../../../core/rpc/exceptions";
import { asJsonObject } from "../../../../core/rpc/json_fields";
import { type RpcTree, rpcTreeFromJson } from "../../../../core/rpc/results";
import type { LiveSession } from "../../../../core/session/live_session";
import type { SessionView } from "../../../../core/store/session_view";
import type { Subscription } from "../../../../core/util/stream";
import { t } from "../../../i18n/i18n";
import { offersVerb } from "../../chat/mode_verbs";
import { navigateTree, type TreeNavigationSessions } from "./navigate_tree";
import {
  type SessionTree,
  sessionTreeDecode,
  sessionTreeRows,
  type TreeEntry,
  type TreeFilter,
  type TreeRow,
} from "./session_tree";

export type TreeAction = "navigate" | "summarize" | "label" | "branch" | "copy";

/** The actions an entry offers, in menu order. */
export function treeActionsFor(entry: TreeEntry, leafId: string | undefined): TreeAction[] {
  const actions: TreeAction[] = [];
  if (entry.id !== leafId) actions.push("navigate", "summarize");
  actions.push("label");
  if (entry.kind === "user") actions.push("branch");
  if (entry.text.length > 0) actions.push("copy");
  return actions;
}

/**
 * Navigate (with or without summary) and labels are companion verbs: without the companion an `/ompx` call would reach
 * the model as a prompt. Only one tree operation runs at a time.
 */
export function canRunTreeAction(action: TreeAction, state: { busy: boolean; companion: boolean }): boolean {
  switch (action) {
    case "copy":
      return true;
    case "branch":
      return !state.busy;
    default:
      return !state.busy && state.companion;
  }
}

/** What the tab asks of the screen: dialogs, snack bars and the clipboard. */
export interface TreeTabUi {
  snack(message: string): void;
  /** The summary dialog: the custom instructions, or undefined when cancelled. */
  askSummary(): Promise<string | undefined>;
  /** The label dialog: the label to set (`value` undefined clears it), or undefined when cancelled. */
  askLabel(initial: string | undefined): Promise<{ readonly value: string | undefined } | undefined>;
  copy(text: string): Promise<void>;
}

/** Waits this long after the transcript settles before reloading the tree. */
const reloadDelayMs = 300;

/**
 * The session and the last entry the transcript names: a new entry (also the ids a settled run's rows get) or a moved
 * leaf changes it, a rebuilt transcript of the same branch does not.
 */
function treeKey(view: SessionView): string {
  let entryId: string | undefined;
  for (let i = view.transcript.length - 1; i >= 0 && entryId === undefined; i--) entryId = view.transcript[i]!.entryId;
  return `${view.config.sessionId ?? ""}\n${entryId ?? ""}`;
}

export class TreeTabState {
  readonly tree: Accessor<SessionTree | undefined>;
  /** Why the last load failed, while there is no tree to show. */
  readonly error: Accessor<string | undefined>;
  readonly loading: Accessor<boolean>;
  /** A tree operation runs. */
  readonly busy: Accessor<boolean>;
  /** A navigation with summary runs; `tree.abort` stops it. */
  readonly summarizing: Accessor<boolean>;
  readonly filter: Accessor<TreeFilter>;
  readonly query: Accessor<string>;
  readonly selectedId: Accessor<string | undefined>;
  readonly rows: Accessor<TreeRow[]>;
  readonly selected: Accessor<TreeEntry | undefined>;

  private readonly setTree: (tree: SessionTree) => void;
  private readonly setError: (error: string | undefined) => void;
  private readonly setLoading: (loading: boolean) => void;
  private readonly setBusy: (busy: boolean) => void;
  private readonly setSummarizing: (summarizing: boolean) => void;
  private readonly setFilterValue: (filter: TreeFilter) => void;
  private readonly setQueryValue: (query: string) => void;
  private readonly setSelected: (id: string | undefined) => void;
  private readonly setToggled: (toggled: ReadonlySet<string>) => void;
  private toggledIds: ReadonlySet<string> = new Set();

  // Signals show their writes only after the next flush; these guard against a second start within one.
  private loadRunning = false;
  private reloadAgain = false;
  /** A reload came while the link was down or the tab hidden; the link coming back or the tab showing runs it. */
  private reloadMissed = false;
  /** The dock shows this tab: a mounted tab stays when another one shows. */
  private shown = true;
  private operationRunning = false;
  private disposed = false;

  private readonly subscriptions: Subscription[];
  private seenTree: string;
  /** A resync (another session, a label, a navigation on any device) began since the last reload was scheduled. */
  private resyncSeen = false;
  private debounce: ReturnType<typeof setTimeout> | undefined;

  constructor(
    private readonly session: LiveSession,
    private readonly sessions: TreeNavigationSessions,
    private readonly ui: TreeTabUi,
  ) {
    const [tree, setTree] = createSignal<SessionTree>();
    const [error, setError] = createSignal<string>();
    const [loading, setLoading] = createSignal(false);
    const [busy, setBusy] = createSignal(false);
    const [summarizing, setSummarizing] = createSignal(false);
    const [filter, setFilter] = createSignal<TreeFilter>("standard");
    const [query, setQuery] = createSignal("");
    const [selectedId, setSelected] = createSignal<string>();
    const [toggled, setToggled] = createSignal<ReadonlySet<string>>(this.toggledIds);
    this.tree = tree;
    this.error = error;
    this.loading = loading;
    this.busy = busy;
    this.summarizing = summarizing;
    this.filter = filter;
    this.query = query;
    this.selectedId = selectedId;
    this.setTree = setTree;
    this.setError = setError;
    this.setLoading = setLoading;
    this.setBusy = setBusy;
    this.setSummarizing = setSummarizing;
    this.setFilterValue = setFilter;
    this.setQueryValue = setQuery;
    this.setSelected = setSelected;
    this.setToggled = setToggled;
    this.rows = createMemo(() => {
      const current = tree();
      return current === undefined ? [] : sessionTreeRows(current, { filter: filter(), query: query(), toggled: toggled() });
    });
    this.selected = createMemo(() => {
      const id = selectedId();
      return id === undefined ? undefined : tree()?.entries.find((entry) => entry.id === id);
    });

    this.seenTree = treeKey(session.view);
    this.subscriptions = [
      session.views.listen((view) => {
        // The tree changes when entries are appended, the leaf moves, a label changes or the session is replaced. A
        // reattach rebuilds the transcript without any of that; reloading then read a large session's tree again,
        // which rotated the run's log into another reattach. While a run streams, the transcript changes per token;
        // reload once it settles.
        if (view.resyncReason !== undefined) this.resyncSeen = true;
        if (view.run.running || view.resyncReason !== undefined) return;
        const key = treeKey(view);
        if (key === this.seenTree && !this.resyncSeen) return;
        this.seenTree = key;
        this.resyncSeen = false;
        clearTimeout(this.debounce);
        this.debounce = setTimeout(() => void this.reload(), reloadDelayMs);
      }),
      session.linkStates.listen((state) => {
        if (state.kind !== "LinkLive") return;
        if (this.reloadMissed || this.tree() === undefined || this.error() !== undefined) void this.reload();
      }),
    ];
    queueMicrotask(() => void this.reload());
  }

  /** Whether the dock shows the tab: a hidden one leaves the tree, a whole read per change, until it shows again. */
  setShown(shown: boolean): void {
    if (shown === this.shown) return;
    this.shown = shown;
    if (shown && (this.reloadMissed || this.tree() === undefined || this.error() !== undefined)) void this.reload();
  }

  dispose(): void {
    this.disposed = true;
    clearTimeout(this.debounce);
    for (const subscription of this.subscriptions) subscription.cancel();
  }

  /** Whether the session runs the companion, which every tree operation but branching and copying needs. */
  get companion(): boolean {
    return this.session.companionHello !== undefined;
  }

  actionsFor(entry: TreeEntry): TreeAction[] {
    return treeActionsFor(entry, this.tree()?.leafId);
  }

  async reload(): Promise<void> {
    // Called again after awaited companion calls, which can outlive the tab.
    if (this.disposed) return;
    if (this.loadRunning) {
      this.reloadAgain = true;
      return;
    }
    if (!this.shown || this.session.linkState.kind !== "LinkLive") {
      this.reloadMissed = true;
      return;
    }
    this.reloadMissed = false;
    this.loadRunning = true;
    this.setLoading(true);
    try {
      const result = await this.fetchTree();
      if (this.disposed) return;
      this.setTree(sessionTreeDecode(result.tree, result.leafId));
      this.setError(undefined);
    } catch (error) {
      if (!this.disposed) this.setError(String(error));
    } finally {
      this.loadRunning = false;
      if (!this.disposed) this.setLoading(false);
      if (this.reloadAgain) {
        this.reloadAgain = false;
        void this.reload();
      }
    }
  }

  /** `get_tree` holds every tool output and image of the session; the companion's `tree.get` only what rows show. */
  private async fetchTree(): Promise<RpcTree> {
    if (!offersVerb(this.session, "tree.get")) return this.session.rpc.getTree();
    return rpcTreeFromJson(asJsonObject(await this.session.companion.call("tree.get"), "tree.get"));
  }

  setFilter(filter: TreeFilter): void {
    this.setFilterValue(filter);
  }

  setQuery(query: string): void {
    this.setQueryValue(query);
  }

  toggle(id: string): void {
    const next = new Set(this.toggledIds);
    if (!next.delete(id)) next.add(id);
    this.toggledIds = next;
    this.setToggled(next);
  }

  /** Selects the entry, or clears the selection when it is the selected one. */
  tap(id: string): void {
    this.setSelected(id === this.selectedId() ? undefined : id);
  }

  select(id: string): void {
    this.setSelected(id);
  }

  /** Every action starts here, whichever button or menu offered it. */
  async run(action: TreeAction, entry: TreeEntry): Promise<void> {
    if (!canRunTreeAction(action, { busy: this.operationRunning, companion: this.companion })) return;
    switch (action) {
      case "navigate":
        return this.navigate(entry, false);
      case "summarize": {
        const instructions = await this.ui.askSummary();
        if (instructions === undefined || this.disposed) return;
        return this.navigate(entry, true, instructions);
      }
      case "label":
        return this.label(entry);
      case "branch":
        return this.branch(entry);
      case "copy":
        await this.ui.copy(entry.text);
        if (!this.disposed) this.ui.snack(t.common.copied);
    }
  }

  async abortSummary(): Promise<void> {
    try {
      await this.session.companion.call("tree.abort");
    } catch (error) {
      if (!(error instanceof CompanionException)) throw error;
      if (!this.disposed) this.ui.snack(t.dock.sessionTree.failed({ error: error.message }));
    }
  }

  private async navigate(entry: TreeEntry, summarize: boolean, instructions?: string): Promise<void> {
    const strings = t.dock.sessionTree;
    this.startOperation(summarize);
    try {
      const outcome = await navigateTree(this.session, this.sessions, {
        entryId: entry.id,
        kind: entry.kind,
        summarize,
        instructions,
      });
      if (outcome !== "moved") {
        if (!this.disposed) this.ui.snack(outcome === "aborted" ? strings.summaryAborted : strings.navigationCancelled);
        return;
      }
      await this.reload();
    } catch (error) {
      this.report(error);
    } finally {
      this.endOperation();
    }
  }

  private async label(entry: TreeEntry): Promise<void> {
    const label = await this.ui.askLabel(entry.label);
    if (label === undefined || this.disposed) return;
    try {
      // The verb requires the key, and null clears the label; an undefined value would drop the key from the JSON.
      await this.session.companion.call("tree.label", { entryId: entry.id, label: label.value ?? null });
      await this.reload();
    } catch (error) {
      if (!(error instanceof CompanionException)) throw error;
      if (!this.disposed) this.ui.snack(t.dock.sessionTree.failed({ error: error.message }));
    }
  }

  private async branch(entry: TreeEntry): Promise<void> {
    const strings = t.dock.sessionTree;
    this.startOperation(false);
    try {
      const result = await this.session.rpc.branch(entry.id);
      if (result.cancelled) {
        if (!this.disposed) this.ui.snack(strings.branchCancelled);
        return;
      }
      this.sessions.setDraft(this.session, result.text, { attachments: [] });
      if (!this.disposed) this.ui.snack(strings.branched);
    } catch (error) {
      if (!(error instanceof RpcException)) throw error;
      if (!this.disposed) this.ui.snack(strings.failed({ error: String(error) }));
    } finally {
      this.endOperation();
    }
  }

  private startOperation(summarize: boolean): void {
    this.operationRunning = true;
    this.setBusy(true);
    this.setSummarizing(summarize);
  }

  private endOperation(): void {
    this.operationRunning = false;
    if (this.disposed) return;
    this.setBusy(false);
    this.setSummarizing(false);
  }

  private report(error: unknown): void {
    const strings = t.dock.sessionTree;
    if (error instanceof CompanionException) {
      if (!this.disposed) this.ui.snack(strings.failed({ error: error.message }));
    } else if (error instanceof RpcException) {
      if (!this.disposed) this.ui.snack(strings.failed({ error: String(error) }));
    } else {
      throw error;
    }
  }
}
