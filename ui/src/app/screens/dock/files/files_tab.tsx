// Port of lib/screens/dock/files/files_tab.dart.
import { createEffect, createMemo, createSignal, For, lazy, Loading, onSettled, Show } from "solid-js";
import { call } from "../../../../bridge";
import { hostPath } from "../../../../core/host/scripts";
import type { LiveSession } from "../../../../core/session/live_session";
import { HostFileExists } from "../../../../core/transport/host_link";
import { useDock, useSessions } from "../../../app_state";
import { baseName, breadcrumbs, checkName, extensionOf, isRootPath, type NameProblem, parentPath } from "../../../files/file_paths";
import type { BrowserRow, EntryRow, FileWorkspace } from "../../../files/file_workspace";
import { type GitChange, gitStatusChangeOf } from "../../../files/git_status";
import { t } from "../../../i18n/i18n";
import type { Machine } from "../../../models/machine";
import { isTouch } from "../../../platform";
import { formatBytes } from "../../../utils/byte_size";
import { ActivityMark } from "../../../widgets/activity_mark";
import { FilledButton, IconButton, TextButton } from "../../../widgets/button";
import { Dialog, showDialog } from "../../../widgets/dialog";
import { Icon } from "../../../widgets/icon";
import { LabeledField } from "../../../widgets/labeled_field";
import { ListRow } from "../../../widgets/list_row";
import { showMenu } from "../../../widgets/popup_menu";
import { showSnackBar } from "../../../widgets/snackbar";
import * as Symbols from "../../../widgets/symbols";
import { TextField } from "../../../widgets/text_field";
import { tooltip } from "../../../widgets/tooltip";
import { machineAccess } from "../machine_access";
import "./files_tab.css";

// CodeMirror comes with the editor, when a document opens.
const FileEditorView = lazy(() => import("./file_editor_view"), { export: "FileEditorView" });

/**
 * Files of the machine, rooted at the session's directory: a lazy tree with breadcrumbs, and an editor for the files
 * opened from it or from the transcript.
 */
export function FilesTab(props: { readonly machine: Machine; readonly session: LiveSession | undefined }) {
  const dock = useDock();
  const sessions = useSessions();
  const workspace = createMemo(() => dock.files(props.machine.id));

  const open = async (path: string, line?: number) => {
    try {
      await workspace().open(path, { line });
    } catch (error) {
      showSnackBar(t.dock.fileBrowser.openFailed({ error: String(error) }));
    }
  };

  createEffect(
    () => [workspace(), props.machine, props.session?.cwd] as const,
    ([files, machine, cwd]) => {
      files.connect = () => machineAccess(sessions.runtimeFor(machine));
      void files.follow(cwd);
    },
  );

  createEffect(
    () => [dock.requests(), workspace(), props.session?.cwd] as const,
    ([, files, cwd]) => {
      const request = dock.takeFileRequest();
      if (request === undefined) return;
      files.resolve(request.path, { cwd }).then(
        (path) => open(path, request.line),
        (error: unknown) => showSnackBar(t.dock.fileBrowser.openFailed({ error: String(error) })),
      );
    },
  );

  return (
    <Show
      when={workspace().current()}
      keyed
      fallback={<Browser workspace={workspace()} onOpen={(path) => void open(path)} />}
    >
      {(document) => (
        <Loading
          fallback={
            <div class="files-tab-center">
              <ActivityMark size={20} />
            </div>
          }
        >
          <FileEditorView workspace={workspace()} document={document} />
        </Loading>
      )}
    </Show>
  );
}

type EntryAction = "open" | "newFile" | "newFolder" | "rename" | "copyPath" | "delete";

/** Rows drawn beyond the visible ones on each side, so a fast scroll does not show empty space. */
const overscanRows = 10;

function Browser(props: { readonly workspace: FileWorkspace; readonly onOpen: (path: string) => void }) {
  const strings = () => t.dock.fileBrowser;
  const failed = (error: unknown) => showSnackBar(strings().failed({ error: String(error) }));

  const create = async (dir: string, folder: boolean) => {
    const name = await askName({ title: folder ? strings().newFolder : strings().newFile, action: strings().create });
    if (name === undefined) return;
    try {
      if (folder) await props.workspace.createFolder(dir, name);
      else await props.workspace.createFile(dir, name);
    } catch (error) {
      if (error instanceof HostFileExists) showSnackBar(strings().exists({ name }));
      else failed(error);
    }
  };

  const rename = async (path: string) => {
    const name = await askName({ title: strings().rename, action: strings().rename, initial: baseName(path) });
    if (name === undefined || name === baseName(path)) return;
    try {
      await props.workspace.rename(path, name);
    } catch (error) {
      if (error instanceof HostFileExists) showSnackBar(strings().exists({ name }));
      else failed(error);
    }
  };

  const remove = async (row: EntryRow) => {
    const stat = row.entry.stat;
    const confirmed = await showDialog<boolean>((close) => (
      <Dialog
        title={strings().deleteTitle({ name: row.entry.name })}
        actions={
          <>
            <TextButton onClick={() => close(false)}>{t.common.cancel}</TextButton>
            <FilledButton onClick={() => close(true)}>{t.common.delete}</FilledButton>
          </>
        }
      >
        {stat.isLink ? strings().deleteLinkBody : stat.isDirectory ? strings().deleteFolderBody : strings().deleteFileBody}
      </Dialog>
    ));
    if (confirmed !== true) return;
    try {
      await props.workspace.delete(row.path);
    } catch (error) {
      failed(error);
    }
  };

  const menu = async (row: EntryRow, point: { x: number; y: number }) => {
    const isDirectory = row.entry.stat.isDirectory;
    const dir = isDirectory ? row.path : parentPath(row.path);
    const action = await showMenu<EntryAction>({
      anchor: point,
      items: [
        { value: "open", label: isDirectory ? strings().browseHere : strings().open },
        { value: "newFile", label: strings().newFile },
        { value: "newFolder", label: strings().newFolder },
        { value: "rename", label: strings().rename },
        { value: "copyPath", label: strings().copyPath },
        { value: "delete", label: t.common.delete },
      ],
    });
    switch (action) {
      case "open":
        if (isDirectory) await props.workspace.openDir(row.path);
        else props.onOpen(row.path);
        break;
      case "newFile":
        await create(dir, false);
        break;
      case "newFolder":
        await create(dir, true);
        break;
      case "rename":
        await rename(row.path);
        break;
      case "copyPath":
        await call("shell.clipboardWrite", { text: hostPath(row.path) });
        showSnackBar(t.common.copied);
        break;
      case "delete":
        await remove(row);
        break;
      case undefined:
        break;
    }
  };

  return (
    <Show
      when={props.workspace.root()}
      fallback={
        <div class="files-tab-center">
          <ActivityMark size={20} />
        </div>
      }
    >
      {(root) => (
        <div class="files-tab">
          <Breadcrumbs path={root()} onOpen={(dir) => void props.workspace.openDir(dir)} />
          <div class="files-tab-toolbar">
            <IconButton
              icon={Symbols.arrow_upward}
              tooltip={strings().up}
              iconSize={20}
              disabled={isRootPath(root())}
              onClick={() => void props.workspace.openDir(parentPath(root()))}
            />
            <IconButton
              icon={Symbols.refresh}
              tooltip={strings().refresh}
              iconSize={20}
              onClick={() => void props.workspace.refresh()}
            />
            <IconButton
              icon={Symbols.note_add}
              tooltip={strings().newFile}
              iconSize={20}
              onClick={() => void create(root(), false)}
            />
            <IconButton
              icon={Symbols.create_new_folder}
              tooltip={strings().newFolder}
              iconSize={20}
              onClick={() => void create(root(), true)}
            />
            <span class="files-tab-spacer" />
            <Show when={props.workspace.documents().length > 0}>
              <TextButton
                icon={Symbols.description}
                onClick={() => {
                  const documents = props.workspace.documents();
                  const last = documents[documents.length - 1];
                  if (last !== undefined) props.workspace.show(last);
                }}
              >
                {strings().openDocuments({ n: props.workspace.documents().length })}
              </TextButton>
            </Show>
          </div>
          <BrowserList
            workspace={props.workspace}
            onOpen={props.onOpen}
            onMenu={(entry, point) => void menu(entry, point)}
          />
        </div>
      )}
    </Show>
  );
}

/** The rows in view and no more: every row is one height, as ListView's itemExtent. */
function BrowserList(props: {
  readonly workspace: FileWorkspace;
  readonly onOpen: (path: string) => void;
  readonly onMenu: (row: EntryRow, point: { x: number; y: number }) => void;
}) {
  const [scrollTop, setScrollTop] = createSignal(0);
  const [viewHeight, setViewHeight] = createSignal(0);
  const rowHeight = () => (isTouch() ? 44 : 32);
  const rows = createMemo(() => props.workspace.rows());
  const visible = createMemo(() => {
    const height = rowHeight();
    const first = Math.max(0, Math.floor(scrollTop() / height) - overscanRows);
    const last = Math.min(rows().length, Math.ceil((scrollTop() + viewHeight()) / height) + overscanRows);
    return { first, rows: rows().slice(first, last) };
  });
  let list!: HTMLDivElement;
  onSettled(() => {
    const observer = new ResizeObserver(() => setViewHeight(list.clientHeight));
    observer.observe(list);
    return () => observer.disconnect();
  });
  return (
    <div class="files-tab-list" ref={list} onScroll={(event) => setScrollTop(event.currentTarget.scrollTop)}>
      <div class="files-tab-extent" style={{ height: `${rows().length * rowHeight()}px` }}>
        <div class="files-tab-window" style={{ transform: `translateY(${visible().first * rowHeight()}px)` }}>
          <For each={visible().rows} keyed={rowKey}>
            {(row) => <BrowserLine row={row()} workspace={props.workspace} onOpen={props.onOpen} onMenu={props.onMenu} />}
          </For>
        </div>
      </div>
    </div>
  );
}

function rowKey(row: BrowserRow): string {
  switch (row.kind) {
    case "EntryRow":
      return row.path;
    case "FailedRow":
      return `failed:${row.dir}`;
    case "LoadingRow":
    case "EmptyRow":
      return `${row.kind}:${row.depth}`;
  }
}

function BrowserLine(props: {
  readonly row: BrowserRow;
  readonly workspace: FileWorkspace;
  readonly onOpen: (path: string) => void;
  readonly onMenu: (row: EntryRow, point: { x: number; y: number }) => void;
}) {
  const strings = () => t.dock.fileBrowser;
  // The status rows start where the entries' icons do.
  const statusIndent = () => `${34 + props.row.depth * 16}px`;
  return (
    <>
      <Show when={props.row.kind === "EntryRow" && props.row} keyed>
        {(row) => <EntryLine row={row} workspace={props.workspace} onOpen={props.onOpen} onMenu={props.onMenu} />}
      </Show>
      <Show when={props.row.kind === "LoadingRow"}>
        <div class="files-tab-status" style={{ "padding-left": statusIndent() }}>
          <ActivityMark />
        </div>
      </Show>
      <Show when={props.row.kind === "EmptyRow"}>
        <div class="files-tab-status files-tab-muted" style={{ "padding-left": statusIndent() }}>
          {strings().emptyFolder}
        </div>
      </Show>
      <Show when={props.row.kind === "FailedRow" && props.row} keyed>
        {(row) => (
          <div class="files-tab-status" style={{ "padding-left": statusIndent() }}>
            <span class="files-tab-failed" ref={tooltip(() => String(row.error))}>
              {strings().listFailed({ error: String(row.error) })}
            </span>
            <TextButton onClick={() => void props.workspace.reloadDir(row.dir)}>{t.common.retry}</TextButton>
          </div>
        )}
      </Show>
    </>
  );
}

function EntryLine(props: {
  readonly row: EntryRow;
  readonly workspace: FileWorkspace;
  readonly onOpen: (path: string) => void;
  readonly onMenu: (row: EntryRow, point: { x: number; y: number }) => void;
}) {
  const stat = () => props.row.entry.stat;
  const change = () => {
    const git = props.workspace.git();
    return git === undefined ? undefined : gitStatusChangeOf(git, props.row.path);
  };
  const dirty = () => stat().isDirectory && (props.workspace.git()?.dirty.has(props.row.path) ?? false);
  const tone = () => {
    const current = change();
    return current === undefined ? undefined : `files-tab-change-${changeTone[current]}`;
  };
  const icon = () => {
    if (stat().isDirectory) return props.row.expanded ? Symbols.folder_open : Symbols.folder;
    return fileIcon(props.row.entry.name);
  };
  return (
    <ListRow
      class="files-tab-entry"
      indent={8 + props.row.depth * 16}
      onClick={() => {
        if (stat().isDirectory) void props.workspace.toggle(props.row.path);
        else props.onOpen(props.row.path);
      }}
      onMenu={(point) => props.onMenu(props.row, point)}
    >
      <div
        class="files-tab-entry-content"
        onDblClick={() => {
          if (stat().isDirectory) void props.workspace.openDir(props.row.path);
        }}
      >
        <span class="files-tab-chevron">
          <Show when={stat().isDirectory}>
            <Icon icon={props.row.expanded ? Symbols.expand_more : Symbols.chevron_right} size={18} />
          </Show>
        </span>
        <Show
          when={stat().isLink}
          fallback={<Icon icon={icon()} size={16} class="files-tab-icon" />}
        >
          <span class="files-tab-icon" ref={tooltip(() => t.dock.fileBrowser.link)}>
            <Icon icon={Symbols.link} size={16} />
          </span>
        </Show>
        <span
          class={[
            "files-tab-name",
            { "files-tab-muted": change() === undefined && props.row.entry.name.startsWith(".") },
            tone(),
          ]}
        >
          {props.row.entry.name}
        </span>
        <Show when={change()} keyed>
          {(current) => (
            <span
              class={["files-tab-badge", tone()]}
              ref={tooltip(() => t.dock.fileBrowser.git[current])}
            >
              {changeBadge[current]}
            </span>
          )}
        </Show>
        <Show when={change() === undefined && dirty()}>
          <Icon icon={Symbols.circle_fill} size={6} class="files-tab-dirty" />
        </Show>
        <Show when={change() === undefined && !dirty() && !stat().isDirectory && !stat().isLink}>
          <span class="files-tab-size">{formatBytes(stat().size)}</span>
        </Show>
      </div>
    </ListRow>
  );
}

const changeBadge: Record<GitChange, string> = {
  modified: "M",
  added: "A",
  deleted: "D",
  renamed: "R",
  copied: "C",
  typeChanged: "T",
  untracked: "U",
  ignored: "I",
  conflicted: "!",
};

/** The `AppColors` content colour of each change. */
const changeTone: Record<GitChange, "warning" | "success" | "error" | "muted"> = {
  modified: "warning",
  added: "success",
  deleted: "error",
  renamed: "success",
  copied: "success",
  typeChanged: "warning",
  untracked: "success",
  ignored: "muted",
  conflicted: "error",
};

function fileIcon(name: string): string {
  switch (extensionOf(name)) {
    case "md":
    case "txt":
    case "rst":
      return Symbols.article;
    case "png":
    case "jpg":
    case "jpeg":
    case "gif":
    case "webp":
    case "svg":
    case "ico":
      return Symbols.image;
    case "json":
    case "yaml":
    case "yml":
    case "toml":
    case "ini":
    case "lock":
      return Symbols.data_object;
    case "zip":
    case "gz":
    case "tar":
    case "tgz":
    case "xz":
    case "7z":
      return Symbols.archive;
    default:
      return Symbols.draft;
  }
}

/** The directories from `/` down to `path`, the deepest one in view at the end. */
function Breadcrumbs(props: { readonly path: string; readonly onOpen: (dir: string) => void }) {
  let strip!: HTMLDivElement;
  const crumbs = createMemo(() => breadcrumbs(props.path));
  createEffect(crumbs, () => {
    strip.scrollLeft = strip.scrollWidth;
  });
  return (
    <div class="files-tab-crumbs" ref={strip}>
      <For each={crumbs()}>
        {(crumb, index) => (
          <>
            <Show when={index() > 0}>
              <Icon icon={Symbols.chevron_right} size={16} class="files-tab-crumb-separator" />
            </Show>
            <Show
              when={index() < crumbs().length - 1}
              fallback={<span class="files-tab-crumb files-tab-crumb-last">{crumb.label}</span>}
            >
              <button type="button" data-ripple class="files-tab-crumb" onClick={() => props.onOpen(crumb.path)}>
                {crumb.label}
              </button>
            </Show>
          </>
        )}
      </For>
    </div>
  );
}

/** Asks for a new name; undefined when cancelled. With `initial`, its stem is selected, as file managers do. */
function askName(options: { readonly title: string; readonly action: string; readonly initial?: string }) {
  return showDialog<string>((close) => <NameDialog {...options} onDone={close} />);
}

function NameDialog(props: {
  readonly title: string;
  readonly action: string;
  readonly initial?: string;
  readonly onDone: (name?: string) => void;
}) {
  const strings = () => t.dock.fileBrowser;
  const [name, setName] = createSignal(props.initial ?? "");
  const [problem, setProblem] = createSignal<NameProblem>();
  let input!: HTMLInputElement;
  let selected = false;
  const submit = () => {
    const trimmed = name().trim();
    const found = checkName(trimmed);
    if (found !== undefined) {
      setProblem(found);
      return;
    }
    props.onDone(trimmed);
  };
  const error = () => {
    switch (problem()) {
      case "empty":
        return t.common.required;
      case "reserved":
        return strings().nameReserved;
      case "separator":
        return strings().nameSeparator;
      case undefined:
        return undefined;
    }
  };
  return (
    <Dialog
      title={props.title}
      class="files-tab-name-dialog"
      actions={
        <>
          <TextButton onClick={() => props.onDone()}>{t.common.cancel}</TextButton>
          <FilledButton onClick={submit}>{props.action}</FilledButton>
        </>
      }
    >
      <LabeledField label={strings().name} error={error()}>
        <TextField
          value={name()}
          onInput={setName}
          onSubmit={submit}
          autofocus
          ref={(element) => (input = element)}
          onFocus={() => {
            const initial = props.initial;
            if (selected || initial === undefined) return;
            selected = true;
            // Select the stem, so typing replaces the name and keeps the extension.
            const dot = initial.lastIndexOf(".");
            input.setSelectionRange(0, dot > 0 ? dot : initial.length);
          }}
        />
      </LabeledField>
    </Dialog>
  );
}
