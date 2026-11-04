// Port of lib/screens/dock/files/file_editor_view.dart on CodeMirror 6. files_tab.tsx loads this module with import()
// when a document opens, so CodeMirror never loads with the browser, the dock or the app.
import { defaultKeymap, history, historyKeymap, indentWithTab } from "@codemirror/commands";
import { openSearchPanel, search, searchKeymap } from "@codemirror/search";
import { Compartment, EditorSelection, EditorState, type Extension, StateEffect } from "@codemirror/state";
import {
  drawSelection,
  EditorView,
  highlightActiveLine,
  highlightActiveLineGutter,
  keymap,
  lineNumbers,
} from "@codemirror/view";
import { createEffect, createMemo, createSignal, flush, Match, onSettled, Show, Switch, untrack } from "solid-js";
import { call } from "../../../../bridge";
import { hostPath } from "../../../../core/host/scripts";
import { useSettings } from "../../../app_state";
import { FileChangedOnDisk, type FileDocument, maxEditableBytes } from "../../../files/file_document";
import { languageFor } from "../../../files/file_language";
import { baseName } from "../../../files/file_paths";
import type { FileWorkspace } from "../../../files/file_workspace";
import { gitStatusChangeOf } from "../../../files/git_status";
import { t } from "../../../i18n/i18n";
import { Prefs } from "../../../providers/settings_provider";
import { ActivityMark } from "../../../widgets/activity_mark";
import { FilledButton, IconButton, TextButton } from "../../../widgets/button";
import { Dialog, showDialog } from "../../../widgets/dialog";
import { showMenu } from "../../../widgets/popup_menu";
import { showSnackBar } from "../../../widgets/snackbar";
import * as Symbols from "../../../widgets/symbols";
import { PillTabs } from "../../../widgets/tabs";
import { tooltip } from "../../../widgets/tooltip";
import { type DiffLine, parseUnifiedDiff } from "../../chat/transcript/diff";
import { DiffView } from "../../chat/transcript/diff_view";
import { syntaxHighlighting } from "./editor_syntax";
import "./file_editor_view.css";
import { findPanel } from "./find_panel";

/** Caps the rows a diff builds; DiffView lays out every row. */
const maxDiffLines = 4000;

type GitDiffState =
  | { readonly kind: "loading" }
  | { readonly kind: "loaded"; readonly lines: readonly DiffLine[] }
  | { readonly kind: "failed"; readonly error: unknown };

type EditorAction = "find" | "wrap" | "reload" | "copyPath" | "close";

/**
 * One open document: the editor (read-only for large, binary or non-UTF-8 files), save with a conflict check, and the
 * file's `git diff` against HEAD.
 */
export function FileEditorView(props: { readonly workspace: FileWorkspace; readonly document: FileDocument }) {
  const strings = () => t.dock.fileBrowser;
  const settings = useSettings();
  const [showDiff, setShowDiff] = createSignal(false);
  const [diff, setDiff] = createSignal<GitDiffState>({ kind: "loading" });
  const [editor, setEditor] = createSignal<EditorView>();
  let diffRequest = 0;
  let moreButton!: HTMLButtonElement;

  const canDiff = createMemo(() => {
    const git = props.workspace.git();
    const change = git === undefined ? undefined : gitStatusChangeOf(git, props.document.path());
    return change !== undefined && change !== "untracked" && change !== "ignored";
  });
  const diffShown = () => showDiff() && canDiff();

  const loadDiff = () => {
    const request = ++diffRequest;
    setDiff({ kind: "loading" });
    props.workspace.diff(props.document.path()).then(
      (text) => {
        if (request === diffRequest) setDiff({ kind: "loaded", lines: parseUnifiedDiff(text) });
      },
      (error: unknown) => {
        if (request === diffRequest) setDiff({ kind: "failed", error });
      },
    );
  };

  const toggleDiff = () => {
    const shown = !showDiff();
    setShowDiff(shown);
    if (shown) loadDiff();
  };

  const reload = async () => {
    try {
      await props.workspace.reload(props.document);
    } catch (error) {
      showSnackBar(strings().openFailed({ error: String(error) }));
      return;
    }
    // The text came from disk again, so a diff on screen is stale.
    if (showDiff()) loadDiff();
  };

  const save = async (force = false): Promise<void> => {
    const document = props.document;
    if (document.readOnly() || document.saving()) return;
    try {
      await props.workspace.save(document, { force });
      showSnackBar(strings().saved({ name: baseName(document.path()) }));
    } catch (error) {
      if (!(error instanceof FileChangedOnDisk)) {
        showSnackBar(strings().saveFailed({ error: String(error) }));
        return;
      }
      const choice = await showDialog<"overwrite" | "reload">((close) => (
        <Dialog
          title={strings().conflictTitle({ name: baseName(document.path()) })}
          actions={
            <>
              <TextButton onClick={() => close()}>{t.common.cancel}</TextButton>
              <Show when={!error.deleted}>
                <TextButton onClick={() => close("reload")}>{strings().discardAndReload}</TextButton>
              </Show>
              <FilledButton onClick={() => close("overwrite")}>{strings().overwrite}</FilledButton>
            </>
          }
        >
          {error.deleted ? strings().conflictDeleted : strings().conflictChanged}
        </Dialog>
      ));
      if (choice === "overwrite") await save(true);
      else if (choice === "reload") await reload();
    }
  };

  const close = async () => {
    const document = props.document;
    if (document.dirty()) {
      const discard = await showDialog<boolean>((close) => (
        <Dialog
          title={strings().discardTitle({ name: baseName(document.path()) })}
          actions={
            <>
              <TextButton onClick={() => close(false)}>{t.common.cancel}</TextButton>
              <FilledButton onClick={() => close(true)}>{strings().discard}</FilledButton>
            </>
          }
        >
          {strings().discardBody}
        </Dialog>
      ));
      if (discard !== true) return;
    }
    props.workspace.closeDocument(document);
  };

  const menu = async () => {
    const action = await showMenu<EditorAction>({
      anchor: moreButton,
      items: [
        { value: "find", label: strings().find },
        { value: "wrap", label: strings().wrapLines, checked: settings.get(Prefs.editorWrapLines) },
        { value: "reload", label: strings().reload },
        { value: "copyPath", label: strings().copyPath },
        { value: "close", label: t.common.close },
      ],
    });
    switch (action) {
      case "find": {
        setShowDiff(false);
        // The editor must be on screen for the find field to take the focus.
        flush();
        const view = editor();
        if (view !== undefined) openSearchPanel(view);
        break;
      }
      case "wrap":
        void settings.set(Prefs.editorWrapLines, !settings.get(Prefs.editorWrapLines));
        break;
      case "reload":
        await reload();
        break;
      case "copyPath":
        await call("shell.clipboardWrite", { text: hostPath(props.document.path()) });
        showSnackBar(t.common.copied);
        break;
      case "close":
        await close();
        break;
      case undefined:
        break;
    }
  };

  const readOnlyNotice = () => {
    switch (props.document.readOnlyReason()) {
      case "tooLarge":
        return strings().tooLarge({ mb: maxEditableBytes / (1024 * 1024) });
      case "binary":
        return strings().binary;
      case "notUtf8":
        return strings().notUtf8;
      case undefined:
        return undefined;
    }
  };

  return (
    <div
      class="file-editor"
      onKeyDown={(event) => {
        if (event.key.toLowerCase() !== "s" || !(event.metaKey || event.ctrlKey) || event.shiftKey || event.altKey) return;
        event.preventDefault();
        void save();
      }}
    >
      <div class="file-editor-header">
        <IconButton icon={Symbols.arrow_back} tooltip={strings().backToFiles} onClick={() => props.workspace.showBrowser()} />
        <span class="file-editor-title" ref={tooltip(() => hostPath(props.document.path()))}>
          {baseName(props.document.path())}
          <Show when={props.document.dirty()}>
            <span class="file-editor-dirty"> ●</span>
          </Show>
        </span>
        <Show when={canDiff()}>
          <IconButton
            icon={showDiff() ? Symbols.difference_fill : Symbols.difference}
            tooltip={showDiff() ? strings().showFile : strings().showDiff}
            onClick={toggleDiff}
          />
        </Show>
        <Show when={!props.document.readOnly()}>
          <Show
            when={!props.document.saving()}
            fallback={
              <span class="file-editor-busy">
                <ActivityMark size={18} />
              </span>
            }
          >
            <IconButton
              icon={Symbols.save}
              tooltip={strings().save}
              disabled={!props.document.dirty()}
              onClick={() => void save()}
            />
          </Show>
        </Show>
        <IconButton
          icon={Symbols.more_vert}
          tooltip={strings().more}
          ref={(button) => (moreButton = button)}
          onClick={() => void menu()}
        />
      </div>
      <Show when={props.workspace.documents().length > 1}>
        <div class="file-editor-documents">
          <PillTabs
            value={props.document}
            tabs={props.workspace.documents().map((document) => ({
              value: document,
              label: document.dirty() ? `${baseName(document.path())} ●` : baseName(document.path()),
            }))}
            onChanged={(document) => props.workspace.show(document)}
          />
        </div>
      </Show>
      <Show when={readOnlyNotice()}>{(notice) => <p class="file-editor-notice">{notice()}</p>}</Show>
      <div class="file-editor-body">
        <Show when={diffShown()}>
          <GitDiff state={diff()} onRetry={loadDiff} />
        </Show>
        <Show when={props.document.readOnlyReason() !== "binary"}>
          <Editor workspace={props.workspace} document={props.document} hidden={diffShown()} onView={setEditor} />
        </Show>
      </div>
    </div>
  );
}

const editorTheme = EditorView.theme({
  "&": { height: "100%", backgroundColor: "var(--surface-container-lowest)", color: "var(--on-surface)" },
  "&.cm-focused": { outline: "none" },
  ".cm-scroller": {
    fontFamily: "var(--font-mono)",
    fontSize: "12px",
    lineHeight: "1.35",
    fontVariantLigatures: "none",
    fontFeatureSettings: '"calt" 0, "liga" 0',
  },
  ".cm-content": { caretColor: "var(--on-surface)" },
  ".cm-cursor, .cm-dropCursor": { borderLeftColor: "var(--on-surface)" },
  // The current find match is the selection, every match also has a faint tone: a strong selection under a faint
  // match tone sets the current match apart from the others.
  "&.cm-focused > .cm-scroller > .cm-selectionLayer .cm-selectionBackground, .cm-selectionBackground": {
    background: "rgb(var(--on-surface-rgb) / 0.32)",
  },
  ".cm-content ::selection": { backgroundColor: "rgb(var(--on-surface-rgb) / 0.32)" },
  ".cm-searchMatch": { backgroundColor: "rgb(var(--on-surface-rgb) / 0.16)", outline: "none" },
  ".cm-searchMatch.cm-searchMatch-selected": { backgroundColor: "rgb(var(--on-surface-rgb) / 0.16)" },
  ".cm-activeLine": { backgroundColor: "var(--surface-container)" },
  ".cm-gutters": { backgroundColor: "var(--surface-container-lowest)", color: "var(--on-surface-variant)", border: "none" },
  ".cm-lineNumbers .cm-gutterElement": { fontSize: "11px", padding: "0 6px 0 8px" },
  ".cm-activeLineGutter": { backgroundColor: "transparent", color: "var(--on-surface)" },
  ".cm-panels": { backgroundColor: "var(--surface-container)", color: "var(--on-surface)" },
  ".cm-panels.cm-panels-top": { borderBottom: "none" },
});

/** Selects line `line` (1-based) and centres it unless it is on screen already. */
function reveal(view: EditorView, line: number): void {
  const doc = view.state.doc;
  const target = doc.line(Math.min(Math.max(line, 1), doc.lines));
  const box = view.scrollDOM.getBoundingClientRect();
  const at = view.coordsAtPos(target.from);
  const visible = at !== null && at.top >= box.top && at.bottom <= box.bottom;
  view.dispatch({
    selection: EditorSelection.range(target.from, target.to),
    effects: visible ? [] : EditorView.scrollIntoView(target.from, { y: "center" }),
  });
}

/**
 * The text in CodeMirror. Its state goes back to the document after every transaction, so text, selection and undo
 * history outlive the view: switching documents or closing the dock keeps them.
 */
function Editor(props: {
  readonly workspace: FileWorkspace;
  readonly document: FileDocument;
  readonly hidden: boolean;
  readonly onView: (view: EditorView | undefined) => void;
}) {
  let host!: HTMLDivElement;
  const [view, setView] = createSignal<EditorView>();
  const readOnly = new Compartment();
  const wrap = new Compartment();
  const settings = useSettings();
  const wrapping = (on: boolean): Extension => (on ? EditorView.lineWrapping : []);
  const document = untrack(() => props.document);
  const language = languageFor(baseName(untrack(() => document.path())));
  const extensions = (): Extension[] => [
    lineNumbers(),
    highlightActiveLineGutter(),
    highlightActiveLine(),
    drawSelection(),
    history(),
    search({ top: true, createPanel: findPanel(() => document.readOnly()) }),
    keymap.of([...searchKeymap, ...historyKeymap, ...defaultKeymap, indentWithTab]),
    readOnly.of(EditorState.readOnly.of(untrack(() => document.readOnly()))),
    wrap.of(wrapping(untrack(() => settings.get(Prefs.editorWrapLines)))),
    editorTheme,
    EditorView.updateListener.of((update) => document.edited(update.state)),
    language === undefined ? [] : syntaxHighlighting(language),
  ];
  let revision = untrack(() => document.revision());

  onSettled(() => {
    const kept = document.editorState();
    const editor = new EditorView({
      parent: host,
      state:
        kept === undefined
          ? EditorState.create({ doc: document.text(), extensions: extensions() })
          : kept.update({ effects: StateEffect.reconfigure.of(extensions()) }).state,
    });
    document.edited(editor.state);
    setView(editor);
    props.onView(editor);
    return () => {
      props.onView(undefined);
      editor.destroy();
    };
  });

  // A reload replaced the text: start over from it, with a fresh undo history.
  createEffect(
    () => [view(), document.revision()] as const,
    ([editor, current]) => {
      if (editor === undefined || current === revision) return;
      revision = current;
      editor.setState(EditorState.create({ doc: document.text(), extensions: extensions() }));
      document.edited(editor.state);
    },
  );

  createEffect(
    () => [view(), document.readOnly()] as const,
    ([editor, readOnlyNow]) => editor?.dispatch({ effects: readOnly.reconfigure(EditorState.readOnly.of(readOnlyNow)) }),
  );

  createEffect(
    () => [view(), settings.get(Prefs.editorWrapLines)] as const,
    ([editor, on]) => editor?.dispatch({ effects: wrap.reconfigure(wrapping(on)) }),
  );

  // A line asked for with the file, now or when the open document is opened again.
  createEffect(
    () => {
      props.workspace.current();
      return view();
    },
    (editor) => {
      const line = document.pendingLine;
      if (editor === undefined || line === undefined) return;
      document.pendingLine = undefined;
      reveal(editor, line);
    },
  );

  return <div class={["file-editor-code", { "file-editor-hidden": props.hidden }]} ref={host} />;
}

function GitDiff(props: { readonly state: GitDiffState; readonly onRetry: () => void }) {
  const strings = () => t.dock.fileBrowser;
  return (
    <Switch>
      <Match when={props.state.kind === "failed" && props.state}>
        {(failed) => (
          <div class="file-editor-center">
            <p>{strings().diffFailed({ error: String(failed().error) })}</p>
            <TextButton onClick={props.onRetry}>{t.common.retry}</TextButton>
          </div>
        )}
      </Match>
      <Match when={props.state.kind === "loaded" && props.state}>
        {(loaded) => (
          <Show
            when={loaded().lines.length > 0}
            fallback={
              <div class="file-editor-center">
                <p>{strings().noChanges}</p>
              </div>
            }
          >
            <div class="file-editor-diff">
              <DiffView lines={loaded().lines.slice(0, maxDiffLines)} />
              <Show when={loaded().lines.length > maxDiffLines}>
                <p class="file-editor-truncated">
                  {strings().diffTruncated({ shown: maxDiffLines, total: loaded().lines.length })}
                </p>
              </Show>
            </div>
          </Show>
        )}
      </Match>
      <Match when={props.state.kind === "loading"}>
        <div class="file-editor-center">
          <ActivityMark size={20} />
        </div>
      </Match>
    </Switch>
  );
}
