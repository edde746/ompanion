// Port of lib/screens/chat/composer.dart.
import { createEffect, createMemo, createSignal, onSettled, Show, untrack } from "solid-js";
import type { RpcModel } from "../../../core/rpc/results";
import { ExternalSession } from "../../../core/session/external_session";
import type { LiveSession } from "../../../core/session/live_session";
import type { ExternalWriter } from "../../../core/store/external_writer";
import { type SessionView, sessionViewUsageTotals } from "../../../core/store/session_view";
import { useSessions } from "../../app_state";
import { t } from "../../i18n/i18n";
import type { Machine } from "../../models/machine";
import { clipboardFiles, isAndroid, isIOS, pastedFiles, pickFiles, shellInfo } from "../../platform";
import type { ComposerAttachment } from "../../sessions/composer_attachments";
import { collapsedAt } from "../../sessions/composer_draft";
import { linkState, sessionView } from "../../sessions/session_view_builder";
import { formatBytes } from "../../utils/byte_size";
import { ActivityMark } from "../../widgets/activity_mark";
import { FilledButton, IconButton, TextButton } from "../../widgets/button";
import { Icon } from "../../widgets/icon";
import { RingProgress } from "../../widgets/progress";
import { showSnackBar } from "../../widgets/snackbar";
import * as Symbols from "../../widgets/symbols";
import { tooltip } from "../../widgets/tooltip";
import { resumeModelChooser } from "../config/model_picker";
import { machineAccess } from "../dock/machine_access";
import { describeConnectError } from "../machines/connect_dialogs";
import { AttachmentChips } from "./attachment_chips";
import { attachmentsFrom, attachmentsFromPasted, attachmentsFromPaths, readPaste } from "./attachment_input";
import { type ComposerFieldHandle, ComposerField } from "./composer_field";
import { composerIntent, findCommand } from "./composer_intent";
import {
  filterCommands,
  filterModels,
  type MentionQuery,
  mentionQuery,
  modelDisplayName,
  modelSelector,
  paletteQuery,
} from "./composer_palettes";
import { sendPrompt } from "./composer_send";
import { ComposerBlock, ComposerMenu, ComposerMenuItem, ContextMeter, ThinkingPicker } from "./composer_toolbar";
import { GoalControl, LoopControl } from "./mode_controls";
import { showsGoal, showsLoop } from "./mode_verbs";
import { ModelMentionPalette } from "./model_mention_palette";
import { ModelPicker } from "./model_picker";
import { QueueList } from "./queue_list";
import { SlashPalette } from "./slash_palette";
import "./composer.css";

/** Below this toolbar width Follow-up and Steer are icons, so the pickers keep their room. */
const narrowWidth = 480;

/** Below this toolbar width the goal and the loop take a row of their own above the toolbar. */
const modesRowWidth = 640;

/**
 * The prompt box: one flat block with the queued messages on top, the attachments and the text in the middle and a
 * toolbar with the model, thinking level and context meter, the goal and the loop while there are any, attach and
 * send at the bottom. Enter sends (Shift+Enter is a new line; on phones and tablets the keyboard's return key is one
 * too); while a run streams Enter steers and Alt/Option+Enter queues a follow-up. `/` opens the palette of the
 * session's commands, `!`/`!!` run shell commands and `$`/`$$` Python through the companion. A paste of copied files,
 * an image or a large text becomes an attachment chip, as in the TUI.
 */
export function Composer(props: { readonly session: LiveSession }) {
  const sessions = useSessions();
  const session = () => props.session;
  const view = sessionView(session);
  const link = linkState(session);
  const machine = () => sessions.machineOf(props.session);
  return (
    <Show
      when={!(props.session instanceof ExternalSession)}
      fallback={<ExternalComposer session={props.session} writer={view().external} machine={machine()} />}
    >
      <SessionComposer session={props.session} view={view()} closed={link().kind === "LinkClosed"} machine={machine()} />
    </Show>
  );
}

function SessionComposer(props: {
  readonly session: LiveSession;
  readonly view: SessionView;
  readonly closed: boolean;
  readonly machine: Machine | undefined;
}) {
  const sessions = useSessions();
  // The chat screen shows one session per composer: it builds a new one for another session.
  const draft = untrack(() => sessions.draftOf(props.session));
  let field: ComposerFieldHandle | undefined;
  let fileInput!: HTMLInputElement;
  // Refs write these while the composer renders.
  const [block, setBlock] = createSignal<HTMLElement | undefined>(undefined, { ownedWrite: true });
  const [width, setWidth] = createSignal(Infinity);
  const [paletteIndex, setPaletteIndex] = createSignal(0);
  /** The palette query the user dismissed with Esc; it reopens once the text changes. */
  const [dismissedQuery, setDismissedQuery] = createSignal<string>();
  /** The `^` token the user dismissed with Esc; its list reopens once the token changes. */
  const [dismissedMention, setDismissedMention] = createSignal<MentionQuery>();
  /** The machine's models for the `^` list, loaded when a `^` is typed first; `modelsError` when that failed. */
  const [models, setModels] = createSignal<readonly RpcModel[]>();
  const [modelsError, setModelsError] = createSignal<{ readonly error: unknown }>();
  const [modelsLoading, setModelsLoading] = createSignal(false);
  const [sending, setSending] = createSignal(false);
  /** Bytes of this prompt's files uploaded so far, while a send uploads. */
  const [upload, setUpload] = createSignal<{ readonly sent: number; readonly total: number }>();
  const [attachMenu, setAttachMenu] = createSignal(false);
  const [attachButton, setAttachButton] = createSignal<HTMLButtonElement | undefined>(undefined, { ownedWrite: true });
  let modelsRequested = false;

  const text = createMemo(() => {
    draft.text.changed();
    return draft.text.text;
  });
  const attachments = createMemo(() => {
    draft.changed();
    return draft.attachments;
  });
  const mentionAtCursor = createMemo(
    () => {
      draft.text.changed();
      return mentionQuery(draft.text.value);
    },
    { equals: (a, b) => a?.start === b?.start && a?.query === b?.query },
  );
  const running = () => props.view.run.running;

  const palette = createMemo(() => {
    const query = paletteQuery(text());
    if (query === undefined || query === dismissedQuery()) return [];
    return filterCommands(props.view.commands, query);
  });

  /**
   * The `^` list at the cursor: undefined while closed, else the models matching the token (`models` undefined while
   * they load, `error` when they could not). Closed when nothing matches, so Enter sends the token as typed.
   */
  const mention = createMemo(() => {
    if (palette().length > 0) return undefined;
    const live = mentionAtCursor();
    const dismissed = dismissedMention();
    if (live === undefined || (dismissed?.start === live.start && dismissed.query === live.query)) return undefined;
    const failure = modelsError();
    if (failure !== undefined) return { models: undefined, error: failure.error };
    const loaded = models();
    if (loaded === undefined) return modelsLoading() ? { models: undefined, error: undefined } : undefined;
    const matching = filterModels(loaded, live.query);
    return matching.length === 0 ? undefined : { models: matching, error: undefined };
  });

  // The text changed: the lists start over at their first row, and a dismissed list reopens once its query changes.
  createEffect(
    () => ({ query: paletteQuery(text()), mention: mentionAtCursor() }),
    ({ query, mention: live }) => {
      if (live !== undefined) loadModels();
      setPaletteIndex(0);
      setDismissedQuery((dismissed) => (dismissed === query ? dismissed : undefined));
      setDismissedMention((dismissed) =>
        dismissed?.start === live?.start && dismissed?.query === live?.query ? dismissed : undefined,
      );
      // A list that failed loads again for the next `^`.
      if (live === undefined) setModelsError(undefined);
    },
  );

  // A draft filled from elsewhere (set_editor_text, a branch, a dialog that closed) asks for the focus.
  createEffect(
    () => draft.changed(),
    () => {
      if (draft.takeFocusRequest()) field?.focus();
    },
  );

  onSettled(() => {
    const element = untrack(block);
    if (!element) return;
    const observer = new ResizeObserver(() => setWidth(element.clientWidth - 12));
    observer.observe(element);
    return () => observer.disconnect();
  });

  /** Loads the machine's model list for the `^` list, once per composer; again after a failure. */
  function loadModels() {
    const machine = untrack(() => props.machine);
    if (modelsRequested || machine === undefined) return;
    modelsRequested = true;
    setModelsLoading(true);
    sessions.models(machine, untrack(() => props.session).rpc).then(
      (loaded) => {
        setModels(loaded);
        setModelsLoading(false);
      },
      (error: unknown) => {
        modelsRequested = false;
        setModelsError({ error });
        setModelsLoading(false);
      },
    );
  }

  function onKey(event: KeyboardEvent) {
    // IME composition owns Enter and the arrows until it commits.
    if (event.isComposing) return;
    const items = palette();
    const picks = mention()?.models ?? [];
    const rows = items.length > 0 ? items.length : picks.length;
    if (rows > 0 && (event.key === "ArrowDown" || event.key === "ArrowUp" || event.key === "Tab")) {
      event.preventDefault();
      if (event.key === "Tab") {
        const index = Math.min(paletteIndex(), rows - 1);
        if (items.length > 0) pick(items[index]!);
        else pickModel(picks[index]!);
        return;
      }
      setPaletteIndex((index) => (index + (event.key === "ArrowDown" ? 1 : rows - 1)) % rows);
      return;
    }
    if (event.key === "Escape") {
      if (items.length > 0) setDismissedQuery(paletteQuery(text()));
      else if (mention() !== undefined) setDismissedMention(mentionAtCursor());
      else return;
      // The list closes; the chat's Esc, which aborts a run, does not see it.
      event.preventDefault();
      event.stopPropagation();
      return;
    }
    if (event.key !== "Enter") return;
    // On phones and tablets the keyboard's return key is a new line, as Flutter's multiline field takes it there.
    if (isIOS() || isAndroid()) return;
    event.preventDefault();
    if (event.shiftKey) {
      field?.sync();
      draft.insert("\n");
      return;
    }
    const typed = paletteQuery(text());
    // Enter completes the highlighted command unless the typed name already is one.
    if (items.length > 0 && (typed === undefined || findCommand(props.view.commands, typed) === undefined)) {
      pick(items[Math.min(paletteIndex(), items.length - 1)]!);
      return;
    }
    if (picks.length > 0) {
      pickModel(picks[Math.min(paletteIndex(), picks.length - 1)]!);
      return;
    }
    void send(event.altKey);
  }

  function pick(command: { readonly name: string }) {
    const value = `/${command.name} `;
    draft.text.value = { text: value, selection: collapsedAt(value.length) };
    field?.focus();
  }

  /** Puts `model` over the `^` token at the cursor: a chip with its name that sends `^provider/id `, as omp's completion. */
  function pickModel(model: RpcModel) {
    field?.sync();
    const live = mentionQuery(draft.text.value);
    const cursor = draft.text.selection?.start;
    if (live === undefined || cursor === undefined) return;
    draft.text.insertChip(live.start, cursor, { name: modelDisplayName(model), source: `^${modelSelector(model)}` });
    field?.focus();
  }

  async function send(followUp: boolean) {
    if (sending()) return;
    field?.sync();
    let session = props.session;
    // An idle exit ended omp with nothing to lose: the send opens the session in a new run, then goes there.
    if (session.linkState.kind === "LinkClosed" && session.view.idleExitMs !== undefined) {
      setSending(true);
      try {
        session = await sessions.reopen(session, { chooseModel: resumeModelChooser(sessions) });
      } catch (error) {
        showSnackBar(t.chat.reopenFailed({ error: describeConnectError(error) }));
        return;
      } finally {
        setSending(false);
      }
      // Another omp process holds the file now: the reopened session is its read-only reader, which takes no prompt.
      if (session instanceof ExternalSession) return;
    }
    const view = session.view;
    const typed = draft.text.text;
    const attached = draft.attachments;
    // A tagged model goes out as omp's `^provider/id`, which omp turns into its `<model agent="m1" …/>` tag.
    const intent = composerIntent(draft.text.expand(typed), {
      hasAttachments: attached.length > 0,
      running: view.run.running,
      followUp,
      commands: view.commands,
    });
    switch (intent.kind) {
      case "NothingToSend":
        return;
      case "UnknownCommand":
        showSnackBar(t.composer.unknownCommand({ name: intent.name }));
        return;
      case "RunBash":
      case "RunPython":
        // Without the companion a `/ompx` call would reach the model as a prompt.
        if (session.companionHello === undefined) {
          showSnackBar(t.chat.noCompanion);
          return;
        }
        sessions
          .execRunsOf(session)
          .start(
            session,
            intent.kind === "RunBash" ? "bash" : "python",
            intent.kind === "RunBash" ? intent.command : intent.code,
            { excludeFromContext: intent.excludeFromContext },
          );
        draft.clear();
        return;
      case "SendPrompt":
        setSending(true);
        await sendPrompt(session, draft, intent, {
          link: async () => {
            const machine = sessions.machineOf(session);
            if (machine === undefined) throw new Error("The session has no machine.");
            return (await machineAccess(sessions.runtimeFor(machine)))[0];
          },
          onUpload: (progress) => setUpload(progress),
          snack: showSnackBar,
        });
        setSending(false);
    }
  }

  /**
   * The attach button: any files; images omp takes as image content become images, as a paste of them does. A desktop
   * shell's open panel names them by path, so on this computer the prompt mentions them where they are.
   */
  async function attachFiles(read: () => Promise<ComposerAttachment[]>) {
    try {
      draft.addAttachments(await read());
    } catch (error) {
      showSnackBar(t.composer.attachFailed({ error: String(error) }));
    }
    field?.focus();
  }

  function chooseFiles(photos: boolean) {
    setAttachMenu(false);
    if (shellInfo().paths) {
      void attachFiles(async () => attachmentsFromPaths(await pickFiles({ multiple: true })));
      return;
    }
    // iOS keeps the photo library out of its file picker; an image type opens the library.
    fileInput.accept = photos ? "image/*" : "";
    fileInput.click();
  }

  /** A paste (Cmd/Ctrl+V, the context menu's Paste): copied files, an image and a large text become chips. */
  async function paste(event: ClipboardEvent) {
    event.preventDefault();
    try {
      const pasted = await readPaste(event.clipboardData, shellInfo().paths ? clipboardFiles : undefined);
      if (pasted?.kind === "PasteText") {
        field?.sync();
        draft.insert(pasted.text);
      } else if (pasted?.kind === "PasteAttachments") {
        draft.addAttachments(pasted.attachments);
      }
    } catch (error) {
      showSnackBar(t.composer.pasteFailed({ error: String(error) }));
    }
  }

  // iOS's menu Paste of a copied image and an Android keyboard's image go to the composer that has the focus.
  onSettled(() => {
    const subscription = pastedFiles.listen((files) => {
      if (field === undefined || !field.element.contains(document.activeElement)) return;
      attachmentsFromPasted(files).then(
        (attachments) => draft.addAttachments(attachments),
        (error: unknown) => showSnackBar(t.composer.pasteFailed({ error: String(error) })),
      );
    });
    return () => subscription.cancel();
  });

  const reopens = () => props.closed && props.view.idleExitMs !== undefined;
  const canSend = () => !sending() && (!props.closed || reopens());
  const narrow = () => width() < narrowWidth;
  const goal = () => (props.closed || !showsGoal(props.session, props.view.goal) ? undefined : props.view.goal);
  const loop = () => (props.closed || !showsLoop(props.session, props.view.loop) ? undefined : props.view.loop);
  const modesRow = () => width() < modesRowWidth && (goal() !== undefined || loop() !== undefined);
  const modes = () => (
    <>
      <Show when={goal()}>{(current) => <GoalControl session={props.session} goal={current()} />}</Show>
      <Show when={loop()}>{(current) => <LoopControl session={props.session} loop={current()} />}</Show>
    </>
  );

  return (
    <ComposerBlock value={block}>
      <div class="composer">
        <Show when={palette().length > 0}>
          <SlashPalette
            commands={palette()}
            selected={Math.min(paletteIndex(), palette().length - 1)}
            onPick={(command) => pick(command)}
          />
        </Show>
        <Show when={mention()}>
          {(current) => (
            <ModelMentionPalette
              models={current().models}
              error={current().error}
              selected={Math.min(paletteIndex(), Math.max(0, (current().models?.length ?? 1) - 1))}
              onPick={(model) => pickModel(model)}
            />
          )}
        </Show>
        <div class="composer-block" ref={setBlock}>
          <QueueList session={props.session} />
          <Show when={attachments().length > 0}>
            <AttachmentChips
              attachments={attachments()}
              onRemove={(attachment) => draft.removeAttachment(attachment)}
              onInline={(attachment) => draft.inline(attachment)}
            />
          </Show>
          <ComposerField
            draft={draft}
            placeholder={running() && !props.closed ? t.composer.hintRunning : t.composer.hint}
            onKeyDown={onKey}
            onPaste={(event) => void paste(event)}
            ref={(handle) => (field = handle)}
          />
          <Show when={modesRow()}>
            <div class="composer-modes">{modes()}</div>
          </Show>
          <div class="composer-toolbar">
            <div class="composer-pickers">
              <Show when={!props.closed}>
                <span class="composer-model">
                  <ModelPicker session={props.session} machine={props.machine} model={props.view.config.model} />
                </span>
                <span class="composer-thinking">
                  <ThinkingPicker session={props.session} level={props.view.config.thinkingLevel} />
                </span>
                <ContextMeter usage={props.view.contextUsage} cost={sessionViewUsageTotals(props.view).cost} />
                <Show when={!modesRow()}>{modes()}</Show>
              </Show>
            </div>
            <IconButton
              icon={Symbols.attach_file}
              iconSize={20}
              size={36}
              tooltip={t.composer.attach}
              disabled={props.closed && !reopens()}
              ref={setAttachButton}
              onClick={() => (isIOS() ? setAttachMenu(!attachMenu()) : chooseFiles(false))}
            />
            <ComposerMenu open={attachMenu()} onClose={() => setAttachMenu(false)} button={attachButton()}>
              <ComposerMenuItem icon={Symbols.photo_library} label={t.composer.attachPhotos} onClick={() => chooseFiles(true)} />
              <ComposerMenuItem icon={Symbols.folder_open} label={t.composer.attachFiles} onClick={() => chooseFiles(false)} />
            </ComposerMenu>
            <input
              ref={fileInput}
              type="file"
              multiple
              hidden
              onChange={(event) => {
                const files = Array.from(event.currentTarget.files ?? []);
                event.currentTarget.value = "";
                if (files.length > 0) void attachFiles(() => attachmentsFrom(files));
              }}
            />
            <span class="composer-gap" />
            <Show
              when={upload()}
              fallback={
                <Show
                  when={running() && !props.closed}
                  fallback={
                    <IconButton
                      icon={Symbols.arrow_upward}
                      iconSize={20}
                      size={36}
                      variant="filled"
                      tooltip={t.composer.send}
                      disabled={!canSend()}
                      onClick={() => void send(false)}
                    />
                  }
                >
                  <Show
                    when={narrow()}
                    fallback={
                      <>
                        <TextButton disabled={!canSend()} onClick={() => void send(true)}>
                          {t.composer.followUp}
                        </TextButton>
                        <span class="composer-gap" />
                        <FilledButton disabled={!canSend()} onClick={() => void send(false)}>
                          {t.composer.steer}
                        </FilledButton>
                      </>
                    }
                  >
                    <IconButton
                      icon={Symbols.schedule}
                      iconSize={20}
                      size={36}
                      tooltip={t.composer.followUp}
                      disabled={!canSend()}
                      onClick={() => void send(true)}
                    />
                    <span class="composer-gap" />
                    <IconButton
                      icon={Symbols.subdirectory_arrow_right}
                      iconSize={20}
                      size={36}
                      variant="filled"
                      tooltip={t.composer.steer}
                      disabled={!canSend()}
                      onClick={() => void send(false)}
                    />
                  </Show>
                </Show>
              }
            >
              {(progress) => (
                <span
                  class="composer-upload"
                  ref={tooltip(() =>
                    t.composer.uploading({ sent: formatBytes(progress().sent), total: formatBytes(progress().total) }),
                  )}
                >
                  {/* A known fraction is a ring that moves only when the count does. */}
                  <Show when={progress().total > 0} fallback={<ActivityMark size={20} />}>
                    <RingProgress value={progress().sent / progress().total} size={20} />
                  </Show>
                </span>
              )}
            </Show>
          </div>
        </div>
      </div>
    </ComposerBlock>
  );
}

/**
 * The composer of a session another omp process is writing: there is no run here to send to, so the field and its
 * toolbar are replaced by what is true about the session and the one action that is safe, the take-over.
 */
function ExternalComposer(props: {
  readonly session: LiveSession;
  /** The writer the last poll found; undefined once the other process is gone, when the session can be taken over. */
  readonly writer: ExternalWriter | undefined;
  readonly machine: Machine | undefined;
}) {
  const sessions = useSessions();

  async function takeOver() {
    try {
      const taken = await sessions.reopen(props.session, { chooseModel: resumeModelChooser(sessions) });
      if (taken === props.session) showSnackBar(t.composer.externalWait);
    } catch (error) {
      showSnackBar(t.sessions.openFailed({ error: describeConnectError(error) }));
    }
  }

  const state = () => {
    const name = props.machine?.name;
    if (props.writer === undefined) return t.composer.externalGone;
    if (props.writer.busy) {
      return name === undefined ? t.composer.externalRunningNoMachine : t.composer.externalRunning({ machine: name });
    }
    return name === undefined ? t.composer.externalIdleNoMachine : t.composer.externalIdle({ machine: name });
  };
  const detail = () => {
    const terminal = props.writer?.terminal;
    return [
      ...(terminal === undefined ? [] : [t.composer.externalTerminal({ terminal })]),
      props.writer === undefined ? t.composer.externalBodyGone : t.composer.externalBody,
    ].join(" · ");
  };

  return (
    <div class="composer">
      <div class="composer-block composer-external">
        <Icon icon={Symbols.terminal} size={18} class="composer-external-icon" />
        <div class="composer-external-text">
          <span class="composer-external-state">{state()}</span>
          <span class="composer-external-detail">{detail()}</span>
        </div>
        <span ref={tooltip(() => (props.writer === undefined ? t.composer.takeOver : t.composer.externalWait))}>
          {/* Only once the other process is gone: taking the file over while an omp still holds it in memory would
              leave two writers on one session. */}
          <TextButton disabled={props.writer !== undefined} onClick={() => void takeOver()}>
            {t.composer.takeOver}
          </TextButton>
        </span>
      </div>
    </div>
  );
}
