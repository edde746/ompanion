// lib/screens/sessions/new_session_dialog.dart.
import { createMemo, createSignal, For, onSettled, Show, untrack } from "solid-js";
import { type HostProbe, hostProbeScratchDirs } from "../../../core/host/probe";
import { hostPath } from "../../../core/host/scripts";
import type { RpcModel } from "../../../core/rpc/results";
import type { HostLink } from "../../../core/transport/host_link";
import { useSessions, useShell } from "../../app_state";
import { t } from "../../i18n/i18n";
import type { Machine } from "../../models/machine";
import { openAndShow } from "../../sessions/show_session";
import { ActivityMark } from "../../widgets/activity_mark";
import { AppSegmented } from "../../widgets/app_segmented";
import { FilledButton, IconButton, TextButton, TonalButton } from "../../widgets/button";
import { Dialog, showDialog } from "../../widgets/dialog";
import { Icon } from "../../widgets/icon";
import { LabeledField } from "../../widgets/labeled_field";
import { ListRow } from "../../widgets/list_row";
import * as Symbols from "../../widgets/symbols";
import { TextField } from "../../widgets/text_field";
import { tooltip } from "../../widgets/tooltip";
import { pickModel } from "../config/model_picker";
import { describeConnectError } from "../machines/connect_dialogs";
import { shortPath } from "../shell/sidebar_tree";
import {
  DirectoryBrowser,
  expandHome,
  modelName,
  parentDirectory,
  recentProjects,
  sessionDirectory,
} from "./new_session";
import "./new_session_dialog.css";

/**
 * Asks where on `machine` a new session works (no project folder, a recent project directory, a typed path, or a
 * folder picked on the machine) and an optional model, opens the session there and shows it. It starts on no folder
 * unless `noFolder` is false: omp then works in its temporary directory, as when it starts in the home directory.
 */
export function showNewSessionDialog(machine: Machine, options: { noFolder?: boolean } = {}): Promise<void> {
  const [creating, setCreating] = createSignal(false);
  // Escape, the scrim and back wait like Cancel while the session starts: omp creates it either way, and the dialog
  // hands it to the shell.
  return showDialog<void>(
    (close) => (
      <NewSessionDialog
        machine={machine}
        noFolder={options.noFolder ?? true}
        creating={creating()}
        setCreating={setCreating}
        close={close}
      />
    ),
    { dismissible: () => !creating() },
  ).then(() => undefined);
}

/** The chosen model: `selector` (`provider/id[:thinking]`) is what omp gets, `name` is what the field shows. */
interface ChosenModel {
  readonly selector: string;
  readonly name: string;
}

function NewSessionDialog(props: {
  readonly machine: Machine;
  readonly noFolder: boolean;
  readonly creating: boolean;
  readonly setCreating: (creating: boolean) => void;
  readonly close: () => void;
}) {
  const sessions = useSessions();
  const shell = useShell();
  /** The session works in omp's temporary directory (`hostProbeScratchDirs`) instead of a project folder. */
  const [noFolder, setNoFolder] = createSignal(untrack(() => props.noFolder));
  const [cwd, setCwdText] = createSignal("");
  /** Undefined leaves omp on its configured default. */
  const [model, setModel] = createSignal<ChosenModel>();
  const [probe, setProbe] = createSignal<HostProbe>();
  const [connecting, setConnecting] = createSignal(true);
  const [loadingModels, setLoadingModels] = createSignal(false);
  const [error, setError] = createSignal<string>();
  let open = true;
  let cwdInput: HTMLInputElement | undefined;
  let startButton: HTMLButtonElement | undefined;
  const runtime = () => sessions.runtimeFor(props.machine);

  const ready = () => !connecting() && probe() !== undefined && !props.creating;
  const recent = createMemo(() => {
    const current = probe();
    // A session in omp's temporary directory has no project to come back to.
    return recentProjects(
      sessions.listingOf(props.machine).sessions,
      current === undefined ? [] : hostProbeScratchDirs(current),
    );
  });
  const typed = () => expandHome(cwd().trim(), probe()?.home);

  /** Moves the focus to where Enter starts the session: the directory field, or Start when no folder is typed. */
  const focusEnter = () =>
    requestAnimationFrame(() => {
      if (open) (noFolder() ? startButton : cwdInput)?.focus();
    });

  /** Puts `path` in the directory field with the caret at its end, ready to type a subdirectory. */
  const setCwd = (path: string) => {
    setCwdText(path);
    requestAnimationFrame(() => {
      cwdInput?.focus();
      cwdInput?.setSelectionRange(path.length, path.length);
    });
  };

  const connect = async () => {
    const current = runtime();
    try {
      const status = current.status;
      const probed =
        status.kind === "MachineOnline"
          ? status.probe
          : // omp may have been installed by hand since the probe.
            status.kind === "MachineNeedsOmp"
            ? await current.reprobe()
            : await current.connectAndProbe();
      setProbe(probed);
      setConnecting(false);
      const after = current.status;
      if (after.kind === "MachineNeedsOmp") setError(t.sessions.needsOmp({ reason: after.reason }));
      // Start was disabled until now, so it could not take the focus when the dialog opened.
      if (noFolder()) focusEnter();
    } catch (failure) {
      setConnecting(false);
      setError(describeConnectError(failure));
    }
  };

  const create = async () => {
    const current = probe();
    if (current === undefined) return;
    const folderless = noFolder();
    const path = typed();
    if (!folderless && path === "") {
      setError(t.sessions.directoryRequired);
      return;
    }
    props.setCreating(true);
    setError(undefined);
    try {
      const where = await sessionDirectory(runtime().link, {
        probe: current,
        noFolder: folderless,
        typed: path,
        machine: props.machine.name,
      });
      if ("error" in where) {
        props.setCreating(false);
        setError(where.error);
        return;
      }
      const selector = model()?.selector;
      await openAndShow(sessions, shell, () =>
        sessions.open(props.machine, { kind: "NewSession", cwd: where.cwd, model: selector }),
      );
      props.close();
    } catch (failure) {
      props.setCreating(false);
      setError(describeConnectError(failure));
    }
  };

  /**
   * Opens the machine's model picker. The machine's control process may have to start first; a failure leaves the
   * form usable and Start on omp's default model.
   */
  const chooseModel = async () => {
    setLoadingModels(true);
    setError(undefined);
    let models: RpcModel[];
    try {
      const control = await sessions.control(props.machine);
      models = await sessions.models(props.machine, control.rpc);
    } catch (failure) {
      setLoadingModels(false);
      setError(t.chat.modelsFailed({ error: describeConnectError(failure) }));
      return;
    }
    setLoadingModels(false);
    // Start was pressed while the list loaded: the session opens on omp's default, and a picker now would sit over
    // the dialog when the session closes it.
    if (!open || props.creating) return;
    const selector = await pickModel({ models, title: t.sessions.modelPick, current: model()?.selector });
    if (!open || selector === undefined) return;
    setModel({ selector, name: modelName(models, selector) });
  };

  const browse = async () => {
    const start = typed();
    const picked = await showDialog<string>((close) => (
      <DirectoryPicker link={() => runtime().link} start={start === "" ? undefined : start} close={close} />
    ));
    if (picked !== undefined) setCwd(picked);
  };

  onSettled(() => {
    void connect();
    return () => {
      open = false;
    };
  });

  const modelField = () => (
    <TonalButton
      class="new-session-model-field"
      disabled={!ready() || loadingModels()}
      onClick={() => void chooseModel()}
    >
      <span class="new-session-model-label">{model()?.name ?? t.sessions.modelDefault}</span>
      <Show when={loadingModels()} fallback={<Icon icon={Symbols.expand_more} size={18} />}>
        <ActivityMark />
      </Show>
    </TonalButton>
  );

  return (
    <Dialog
      class="new-session-dialog"
      title={t.sessions.newSessionOn({ machine: props.machine.name })}
      actions={
        <>
          <TextButton disabled={props.creating} onClick={() => props.close()}>
            {t.common.cancel}
          </TextButton>
          <FilledButton
            disabled={!ready()}
            onClick={() => void create()}
            ref={(element) => {
              startButton = element;
            }}
          >
            <Show when={props.creating} fallback={t.sessions.create}>
              <ActivityMark size={16} />
            </Show>
          </FilledButton>
        </>
      }
    >
      <Show when={connecting()}>
        <span class="new-session-connecting" ref={tooltip(() => t.sessions.connecting)}>
          <ActivityMark />
        </span>
      </Show>
      <div class="new-session-form">
        <div class="new-session-mode">
          <AppSegmented<boolean>
            value={noFolder()}
            segments={[
              { value: false, label: t.sessions.folder, icon: Symbols.folder },
              { value: true, label: t.sessions.noFolder, icon: Symbols.folder_off },
            ]}
            onChanged={(value) => {
              setNoFolder(value);
              focusEnter();
            }}
          />
        </div>
        <Show
          when={!noFolder()}
          fallback={<p class="new-session-hint">{t.sessions.noFolderHint}</p>}
        >
          <LabeledField label={t.sessions.directory}>
            <TextField
              value={cwd()}
              onInput={setCwdText}
              onSubmit={() => {
                if (ready()) void create();
              }}
              hint={t.sessions.directoryHint}
              autofocus
              ref={(element) => {
                cwdInput = element;
              }}
              suffix={
                <IconButton
                  icon={Symbols.folder_open}
                  tooltip={t.sessions.browse}
                  size={32}
                  iconSize={20}
                  disabled={probe() === undefined}
                  onClick={() => void browse()}
                />
              }
            />
          </LabeledField>
          <Show when={recent().length > 0}>
            <LabeledField label={t.sessions.recentDirectories}>
              <div class="new-session-recent">
                <For each={recent()}>
                  {(path) => (
                    <RecentProject
                      path={path}
                      home={probe()?.home}
                      selected={path === typed()}
                      onClick={() => setCwd(path)}
                    />
                  )}
                </For>
              </div>
            </LabeledField>
          </Show>
        </Show>
        <LabeledField label={t.sessions.model}>
          <div class="new-session-model">
            <Show when={model()} fallback={modelField()}>
              {(chosen) => (
                <span class="new-session-model-tip" ref={tooltip(() => chosen().selector)}>
                  {modelField()}
                </span>
              )}
            </Show>
            <Show when={model()}>
              <IconButton
                class="new-session-model-default"
                icon={Symbols.close}
                iconSize={18}
                tooltip={t.sessions.modelUseDefault}
                onClick={() => setModel(undefined)}
              />
            </Show>
          </div>
        </LabeledField>
        <Show when={error()}>{(message) => <p class="new-session-error">{message()}</p>}</Show>
      </div>
    </Dialog>
  );
}

/**
 * One recent project directory: a dense row that puts its path in the directory field, `selected` when it is the one
 * the field holds. The full path is the row's tooltip.
 */
function RecentProject(props: {
  readonly path: string;
  readonly home: string | undefined;
  readonly selected: boolean;
  readonly onClick: () => void;
}) {
  // The last segment, with its separator, yields only to the row's own width; the directories above it are cut first,
  // so the segment that tells two long `.cache` paths apart stays readable.
  const parts = createMemo(() => {
    const shown = shortPath(props.path, props.home);
    const cut = Math.max(shown.lastIndexOf("/"), shown.lastIndexOf("\\"));
    return cut <= 0 ? { head: "", tail: shown } : { head: shown.substring(0, cut), tail: shown.substring(cut) };
  });
  return (
    <ListRow selected={props.selected} onClick={props.onClick}>
      <div class="new-session-recent-row" ref={tooltip(() => props.path)}>
        <Icon icon={Symbols.folder} size={16} />
        <span class="new-session-recent-path">
          <Show when={parts().head !== ""}>
            <span class="new-session-recent-head">{parts().head}</span>
          </Show>
          <span class="new-session-recent-tail">{parts().tail}</span>
        </span>
      </div>
    </ListRow>
  );
}

/**
 * Browses directories on the machine over its file access (SFTP or local files) and closes with the chosen one as a
 * host-native path.
 */
function DirectoryPicker(props: {
  readonly link: () => HostLink;
  readonly start: string | undefined;
  readonly close: (path?: string) => void;
}) {
  const browser = new DirectoryBrowser(untrack(() => props.link));
  const [showHidden, setShowHidden] = createSignal(false);
  const parent = () => {
    const path = browser.path();
    return path === undefined ? undefined : parentDirectory(path);
  };
  const shown = createMemo(() => {
    const entries = browser.entries();
    return entries === undefined ? undefined : entries.filter((name) => showHidden() || !name.startsWith("."));
  });

  onSettled(() => {
    void browser.open(props.start);
    return () => void browser.dispose();
  });

  return (
    <Dialog
      class="new-session-picker"
      title={t.sessions.browseTitle}
      actions={
        <>
          <TextButton onClick={() => props.close()}>{t.common.cancel}</TextButton>
          <FilledButton disabled={browser.path() === undefined} onClick={() => props.close(browser.chosen())}>
            {t.sessions.chooseDirectory}
          </FilledButton>
        </>
      }
    >
      <div class="new-session-picker-body">
        <div class="new-session-picker-bar">
          <IconButton
            icon={Symbols.arrow_upward}
            tooltip={t.sessions.up}
            disabled={parent() === undefined}
            onClick={() => {
              const path = parent();
              if (path !== undefined) void browser.list(path);
            }}
          />
          <span class="new-session-picker-path">{hostPath(browser.path() ?? "")}</span>
          <IconButton
            icon={showHidden() ? Symbols.visibility : Symbols.visibility_off}
            tooltip={t.sessions.showHidden}
            variant={showHidden() ? "tonal" : "standard"}
            onClick={() => setShowHidden((value) => !value)}
          />
        </div>
        <div class="new-session-picker-list">
          <Show
            when={browser.error() === undefined}
            fallback={<p class="new-session-picker-center">{browser.error()}</p>}
          >
            <Show
              when={shown()}
              fallback={
                <div class="new-session-picker-center">
                  <ActivityMark size={20} />
                </div>
              }
            >
              {(names) => (
                <For each={names()}>
                  {(name) => (
                    <ListRow onClick={() => void browser.enter(name)}>
                      <div class="new-session-picker-row">
                        <Icon icon={Symbols.folder} size={20} />
                        <span class="new-session-picker-name">{name}</span>
                      </div>
                    </ListRow>
                  )}
                </For>
              )}
            </Show>
          </Show>
        </div>
      </div>
    </Dialog>
  );
}
