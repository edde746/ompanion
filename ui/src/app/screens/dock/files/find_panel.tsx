// The file editor's find and replace bar (lib/screens/dock/files/file_editor_view.dart, _FindPanel) as CodeMirror's
// search panel: it sits above the text and takes its own rows, so the text under it stays reachable.
import {
  closeSearchPanel,
  findNext,
  findPrevious,
  getSearchQuery,
  replaceAll,
  replaceNext,
  SearchQuery,
  setSearchQuery,
} from "@codemirror/search";
import { EditorSelection } from "@codemirror/state";
import { EditorView, type Panel, type ViewUpdate } from "@codemirror/view";
import { render } from "@solidjs/web";
import { createMemo, createSignal, onSettled, Show } from "solid-js";
import { t } from "../../../i18n/i18n";
import { IconButton, TonalButton } from "../../../widgets/button";
import * as Symbols from "../../../widgets/symbols";
import { TextField } from "../../../widgets/text_field";
import "./find_panel.css";

/** Counting stops here, so a common word in a large file costs one bounded scan per keystroke. */
const maxCounted = 10_000;

/** The search panel of an editor whose text is read-only while `readOnly` holds: no replace row then. */
export function findPanel(readOnly: () => boolean): (view: EditorView) => Panel {
  return (view) => {
    const dom = document.createElement("div");
    const [version, setVersion] = createSignal(0, { ownedWrite: true });
    let dispose: (() => void) | undefined;
    return {
      dom,
      top: true,
      mount: () => {
        dispose = render(() => <FindBar view={view} version={version()} readOnly={readOnly()} />, dom);
      },
      update: (update: ViewUpdate) => {
        if (update.docChanged || update.selectionSet || getSearchQuery(update.state) !== getSearchQuery(update.startState)) {
          setVersion((count) => count + 1);
        }
      },
      destroy: () => dispose?.(),
    };
  };
}

function FindBar(props: { readonly view: EditorView; readonly version: number; readonly readOnly: boolean }) {
  const strings = () => t.dock.fileBrowser;
  const [replacing, setReplacing] = createSignal(false);
  let field!: HTMLInputElement;
  // CodeMirror focuses the `main-field` when it opens the panel, which may come before this bar has rendered.
  onSettled(() => {
    field.focus();
    field.select();
  });
  const query = createMemo(() => {
    void props.version;
    return getSearchQuery(props.view.state);
  });
  const count = createMemo(() => {
    void props.version;
    return countMatches(props.view, query());
  });
  const set = (change: { search?: string; replace?: string; caseSensitive?: boolean }) => {
    const current = getSearchQuery(props.view.state);
    const next = new SearchQuery({
      search: change.search ?? current.search,
      replace: change.replace ?? current.replace,
      caseSensitive: change.caseSensitive ?? current.caseSensitive,
      literal: true,
    });
    props.view.dispatch({ effects: setSearchQuery.of(next) });
    if (change.search !== undefined || change.caseSensitive !== undefined) selectNearest(props.view, next);
  };
  const close = () => {
    closeSearchPanel(props.view);
    props.view.focus();
  };
  const onKeyDown = (event: KeyboardEvent) => {
    if (event.key !== "Escape") return;
    event.preventDefault();
    close();
  };
  const label = () => {
    const { index, total, capped } = count();
    if (total === 0) return strings().noMatches;
    return `${index === undefined ? "?" : index + 1}/${total}${capped ? "+" : ""}`;
  };
  return (
    <div class="find-panel">
      <div class="find-panel-row">
        <Show when={!props.readOnly} fallback={<span class="find-panel-lead" />}>
          <IconButton
            icon={replacing() ? Symbols.expand_more : Symbols.chevron_right}
            tooltip={strings().replace}
            iconSize={18}
            onClick={() => setReplacing((open) => !open)}
          />
        </Show>
        <TextField
          class="find-panel-field"
          value={query().search}
          hint={strings().find}
          onInput={(search) => set({ search })}
          onSubmit={() => findNext(props.view)}
          onKeyDown={onKeyDown}
          ref={(input) => {
            field = input;
            input.setAttribute("main-field", "true");
          }}
        />
        <span class="find-panel-count">{label()}</span>
        <IconButton
          icon={Symbols.format_size}
          tooltip={strings().caseSensitive}
          iconSize={18}
          class={query().caseSensitive ? "find-panel-on" : undefined}
          onClick={() => set({ caseSensitive: !query().caseSensitive })}
        />
        <IconButton
          icon={Symbols.expand_less}
          tooltip={strings().previousMatch}
          iconSize={18}
          onClick={() => findPrevious(props.view)}
        />
        <IconButton
          icon={Symbols.expand_more}
          tooltip={strings().nextMatch}
          iconSize={18}
          onClick={() => findNext(props.view)}
        />
        <IconButton icon={Symbols.close} tooltip={t.common.close} iconSize={18} onClick={close} />
      </div>
      <Show when={replacing() && !props.readOnly}>
        <div class="find-panel-row find-panel-replace">
          <TextField
            class="find-panel-field"
            value={query().replace}
            hint={strings().replace}
            onInput={(replace) => set({ replace })}
            onSubmit={() => replaceNext(props.view)}
            onKeyDown={onKeyDown}
          />
          <TonalButton onClick={() => replaceNext(props.view)}>{strings().replace}</TonalButton>
          <TonalButton onClick={() => replaceAll(props.view)}>{strings().replaceAll}</TonalButton>
        </div>
      </Show>
    </div>
  );
}

/** How many matches `query` has, and which of them the main selection is (undefined when it is none). */
function countMatches(view: EditorView, query: SearchQuery): { index?: number; total: number; capped: boolean } {
  if (!query.valid) return { total: 0, capped: false };
  const selection = view.state.selection.main;
  const cursor = query.getCursor(view.state);
  let index: number | undefined;
  let total = 0;
  for (let match = cursor.next(); !match.done; match = cursor.next()) {
    if (match.value.from === selection.from && match.value.to === selection.to) index = total;
    if (++total >= maxCounted) return { index, total, capped: true };
  }
  return { index, total, capped: false };
}

/** Selects the first match from the selection on, wrapping to the top, as the query is typed. */
function selectNearest(view: EditorView, query: SearchQuery): void {
  if (!query.valid) return;
  let match = query.getCursor(view.state, view.state.selection.main.from).next();
  if (match.done) match = query.getCursor(view.state).next();
  if (match.done) return;
  view.dispatch({
    selection: EditorSelection.single(match.value.from, match.value.to),
    effects: EditorView.scrollIntoView(match.value.from, { y: "center" }),
    userEvent: "select.search",
  });
}
