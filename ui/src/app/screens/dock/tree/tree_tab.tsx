// Port of lib/screens/dock/tree/tree_tab.dart; its state is tree_tab_state.ts, its rows session_tree_view.tsx.
import { createSignal, For, Match, onSettled, Show, Switch, untrack } from "solid-js";
import { call } from "../../../../bridge";
import type { LiveSession } from "../../../../core/session/live_session";
import { t } from "../../../i18n/i18n";
import { useSessions } from "../../../app_state";
import { isTouch } from "../../../platform";
import { ActivityMark } from "../../../widgets/activity_mark";
import { AppSearchField } from "../../../widgets/app_search_field";
import { FilledButton, IconButton, TextButton, TonalButton } from "../../../widgets/button";
import { Dialog, showDialog } from "../../../widgets/dialog";
import { LabeledField } from "../../../widgets/labeled_field";
import { showMenu } from "../../../widgets/popup_menu";
import { showSnackBar } from "../../../widgets/snackbar";
import * as Symbols from "../../../widgets/symbols";
import { TextField } from "../../../widgets/text_field";
import { DockEmptyState } from "../dock_empty_state";
import { type TreeEntry, type TreeFilter, treeFilters, type TreeRow } from "./session_tree";
import { SessionTreeRow, treeRowText } from "./session_tree_view";
import { canRunTreeAction, type TreeAction, TreeTabState } from "./tree_tab_state";
import "./tree_tab.css";

/**
 * AppSizes.rowHeight, rowHeightTouch on touch screens (`--list-row-height`): every row of the tree is this tall, so the
 * list renders only the rows in view.
 */
const rowHeight = () => (isTouch() ? 44 : 32);
/** Rows rendered beyond each edge of the view, so a fast scroll does not show blank rows. */
const overscan = 10;

function actionLabel(action: TreeAction): string {
  const strings = t.dock.sessionTree;
  switch (action) {
    case "navigate":
      return strings.navigate;
    case "summarize":
      return strings.navigateWithSummary;
    case "label":
      return strings.label;
    case "branch":
      return strings.branch;
    case "copy":
      return strings.copyText;
  }
}

/**
 * The session tree (`/tree`): every branch of the conversation, the current leaf highlighted. Navigate the leaf
 * (optionally summarizing the abandoned branch), label entries, or branch a user message into a new session.
 */
export function TreeTab(props: { readonly session: LiveSession }) {
  // The tab is keyed by its session (DockTabBody), so the session never changes under one state.
  const state = new TreeTabState(untrack(() => props.session), useSessions(), {
    snack: (message) => showSnackBar(message),
    askSummary: () => showDialog<string>((close) => <SummaryDialog close={close} />),
    askLabel: (initial) =>
      showDialog<{ readonly value: string | undefined }>((close) => <LabelDialog initial={initial} close={close} />),
    copy: (text) => call("shell.clipboardWrite", { text }).then(() => undefined),
  });
  onSettled(() => () => state.dispose());
  const enabled = (action: TreeAction) =>
    canRunTreeAction(action, { busy: state.busy(), companion: props.session.companionHello !== undefined });

  async function rowMenu(row: TreeRow, point: { x: number; y: number }) {
    state.select(row.entry.id);
    const action = await showMenu<TreeAction>({
      anchor: point,
      items: state
        .actionsFor(row.entry)
        .map((action) => ({ value: action, label: actionLabel(action), disabled: !enabled(action) })),
    });
    if (action !== undefined) await state.run(action, row.entry);
  }

  async function filterMenu(anchor: HTMLElement) {
    const strings = t.dock.sessionTree;
    const labels: Readonly<Record<TreeFilter, string>> = {
      standard: strings.filterStandard,
      noTools: strings.filterNoTools,
      userOnly: strings.filterUserOnly,
      labeledOnly: strings.filterLabeled,
      all: strings.filterAll,
    };
    const filter = await showMenu<TreeFilter>({
      anchor,
      items: treeFilters.map((filter) => ({ value: filter, label: labels[filter], checked: filter === state.filter() })),
    });
    if (filter !== undefined) state.setFilter(filter);
  }

  return (
    <div class="tree-tab">
      <div class="tree-tab-header">
        <AppSearchField class="tree-tab-search" hint={t.dock.sessionTree.search} onChanged={(query) => state.setQuery(query)} />
        <IconButton
          icon={Symbols.filter_list}
          tooltip={t.dock.sessionTree.filter}
          class={state.filter() === "standard" ? undefined : "tree-tab-filter-on"}
          onClick={(event) => void filterMenu(event.currentTarget as HTMLElement)}
        />
        <Show
          when={!state.loading()}
          fallback={
            <span class="tree-tab-loading" role="status" aria-label={t.dock.sessionTree.refresh}>
              <ActivityMark size={16} />
            </span>
          }
        >
          <IconButton icon={Symbols.refresh} tooltip={t.dock.sessionTree.refresh} onClick={() => void state.reload()} />
        </Show>
      </div>
      <Show when={props.session.companionHello === undefined}>
        <p class="tree-tab-notice">{t.dock.sessionTree.noCompanion}</p>
      </Show>
      <Show when={state.summarizing()}>
        <div class="tree-tab-banner">
          <ActivityMark size={20} />
          <span class="tree-tab-banner-text">{t.dock.sessionTree.summarizing}</span>
          <TextButton onClick={() => void state.abortSummary()}>{t.dock.sessionTree.abort}</TextButton>
        </div>
      </Show>
      <div class="tree-tab-body">
        <Switch>
          <Match when={state.tree() === undefined && state.error()}>
            {(error) => (
              <DockEmptyState
                icon={Symbols.error}
                message={t.dock.sessionTree.loadFailed({ error: error() })}
                action={<TextButton onClick={() => void state.reload()}>{t.common.retry}</TextButton>}
              />
            )}
          </Match>
          <Match when={state.tree() === undefined}>
            <div class="tree-tab-centered">
              <ActivityMark size={20} />
            </div>
          </Match>
          {/* Nothing to list without a search or a filter of the user's: the standard filter hides the bookkeeping a
              session starts with, so a new one has entries but no rows. */}
          <Match
            when={
              state.tree()?.entries.length === 0 ||
              (state.rows().length === 0 && state.query().trim() === "" && state.filter() === "standard")
            }
          >
            <DockEmptyState icon={Symbols.account_tree} message={t.dock.sessionTree.empty} />
          </Match>
          <Match when={state.rows().length === 0}>
            <DockEmptyState icon={Symbols.filter_list_off} message={t.dock.sessionTree.noMatches} />
          </Match>
          <Match when={true}>
            <TreeRows
              rows={state.rows()}
              selectedId={state.selectedId()}
              onTap={(id) => state.tap(id)}
              onToggle={(id) => state.toggle(id)}
              onMenu={(row, point) => void rowMenu(row, point)}
            />
          </Match>
        </Switch>
      </div>
      <Show when={state.selected()}>
        {(entry) => (
          <SelectionBar
            entry={entry()}
            actions={state.actionsFor(entry())}
            enabled={enabled}
            onAction={(action) => void state.run(action, entry())}
          />
        )}
      </Show>
    </div>
  );
}

/** The rows in view of a scrolling list of fixed-height rows. */
function TreeRows(props: {
  readonly rows: readonly TreeRow[];
  readonly selectedId: string | undefined;
  readonly onTap: (id: string) => void;
  readonly onToggle: (id: string) => void;
  readonly onMenu: (row: TreeRow, point: { x: number; y: number }) => void;
}) {
  const [scrollTop, setScrollTop] = createSignal(0);
  const [height, setHeight] = createSignal(0);
  let list!: HTMLDivElement;
  onSettled(() => {
    // The list opens on the current position, as omp's `/tree` selector does: in a long session it is far down, and
    // the list starts where the session does. Once, at the first height: the tab may mount hidden.
    let revealed = false;
    const observer = new ResizeObserver(() => {
      setHeight(list.clientHeight);
      if (revealed || list.clientHeight === 0) return;
      revealed = true;
      const leaf = props.rows.findIndex((row) => row.isLeaf);
      if (leaf < 0) return;
      list.scrollTop = Math.max(0, (leaf + 1) * rowHeight() - list.clientHeight / 2);
      setScrollTop(list.scrollTop);
    });
    observer.observe(list);
    return () => observer.disconnect();
  });
  const first = () => Math.max(0, Math.floor(scrollTop() / rowHeight()) - overscan);
  const shown = () =>
    props.rows.slice(
      first(),
      Math.min(props.rows.length, Math.ceil((scrollTop() + height()) / rowHeight()) + overscan),
    );
  return (
    <div class="tree-tab-list" ref={list} onScroll={(event) => setScrollTop(event.currentTarget.scrollTop)}>
      <div class="tree-tab-list-extent" style={{ height: `${props.rows.length * rowHeight()}px` }}>
        <div class="tree-tab-list-window" style={{ transform: `translateY(${first() * rowHeight()}px)` }}>
          <For each={shown()} keyed={(row) => row.entry.id}>
            {(row) => (
              <SessionTreeRow
                row={row()}
                selected={row().entry.id === props.selectedId}
                onClick={() => props.onTap(row().entry.id)}
                onToggle={row().branchHead ? () => props.onToggle(row().entry.id) : undefined}
                onMenu={(point) => props.onMenu(row(), point)}
              />
            )}
          </For>
        </div>
      </div>
    </div>
  );
}

function SelectionBar(props: {
  readonly entry: TreeEntry;
  readonly actions: readonly TreeAction[];
  readonly enabled: (action: TreeAction) => boolean;
  readonly onAction: (action: TreeAction) => void;
}) {
  return (
    <div class="tree-tab-selection">
      <p class="tree-tab-selection-text">{treeRowText(props.entry)}</p>
      <div class="tree-tab-selection-actions">
        <For each={props.actions.filter((action) => action !== "copy")}>
          {(action) => (
            <TonalButton disabled={!props.enabled(action)} onClick={() => props.onAction(action)}>
              {actionLabel(action)}
            </TonalButton>
          )}
        </For>
      </div>
    </div>
  );
}

function SummaryDialog(props: { readonly close: (instructions?: string) => void }) {
  const [instructions, setInstructions] = createSignal("");
  const strings = t.dock.sessionTree;
  return (
    <Dialog
      title={strings.summaryTitle}
      class="tree-tab-dialog"
      actions={
        <>
          <TextButton onClick={() => props.close()}>{t.common.cancel}</TextButton>
          <FilledButton onClick={() => props.close(instructions())}>{strings.summarize}</FilledButton>
        </>
      }
    >
      <p>{strings.summaryBody}</p>
      <LabeledField label={strings.summaryInstructions}>
        <textarea
          class="tree-tab-instructions"
          rows={2}
          autofocus
          value={instructions()}
          onInput={(event) => setInstructions(event.currentTarget.value)}
        />
      </LabeledField>
    </Dialog>
  );
}

function LabelDialog(props: {
  readonly initial: string | undefined;
  readonly close: (label?: { readonly value: string | undefined }) => void;
}) {
  const [label, setLabel] = createSignal(props.initial ?? "");
  const strings = t.dock.sessionTree;
  const submit = () => {
    const value = label().trim();
    props.close({ value: value.length === 0 ? undefined : value });
  };
  return (
    <Dialog
      title={strings.labelTitle}
      class="tree-tab-label-dialog"
      actions={
        <>
          <Show when={props.initial !== undefined}>
            <TextButton onClick={() => props.close({ value: undefined })}>{strings.clearLabel}</TextButton>
          </Show>
          <TextButton onClick={() => props.close()}>{t.common.cancel}</TextButton>
          <FilledButton onClick={submit}>{t.common.save}</FilledButton>
        </>
      }
    >
      <LabeledField label={strings.labelField}>
        <TextField value={label()} onInput={setLabel} onSubmit={submit} autofocus />
      </LabeledField>
    </Dialog>
  );
}
