// Port of lib/screens/dock/terminal/terminal_tab.dart, on xterm.js. This file is the Terminal tab's chunk, which the
// dock loads when the tab first shows: xterm.js comes with it and is never on the first frame's path.
import { FitAddon } from "@xterm/addon-fit";
import { type ITheme, Terminal } from "@xterm/xterm";
import "@xterm/xterm/css/xterm.css";
import { createEffect, createMemo, For, onSettled, Show } from "solid-js";
import { call } from "../../../../bridge";
import type { LiveSession } from "../../../../core/session/live_session";
import { useDock, useSessions } from "../../../app_state";
import { t } from "../../../i18n/i18n";
import type { Machine } from "../../../models/machine";
import { osc52ClipboardText, remoteShellLaunch } from "../../../terminal/shell_launch";
import { HostTerminalBackend, type TerminalPhase, TerminalSession } from "../../../terminal/terminal_session";
import { appLogger } from "../../../utils/app_logger";
import { ActivityMark } from "../../../widgets/activity_mark";
import { IconButton, TextButton, TonalButton } from "../../../widgets/button";
import { showMenu } from "../../../widgets/popup_menu";
import * as Symbols from "../../../widgets/symbols";
import { openExternalLink } from "../../external_links";
import { type DockController, maxTerminalFontSize, minTerminalFontSize } from "../dock_controller";
import { DockEmptyState } from "../dock_empty_state";
import { machineAccess } from "../machine_access";
import "./terminal_tab.css";

/**
 * Terminals on the machine, as tabs: PTYs through the core, over SSH or on this computer. New terminals start in the
 * session's directory. The dock remounts the tab per machine; the terminals live in the dock's deck for the machine.
 */
export function TerminalTab(props: { readonly machine: Machine; readonly session: LiveSession | undefined }) {
  const dock = useDock();
  const sessions = useSessions();
  const deck = createMemo(() => dock.terminals(props.machine.id));
  const tabs = createMemo(() => {
    deck().changed();
    return deck().sessions;
  });
  const selected = createMemo(() => {
    deck().changed();
    return deck().current;
  });

  const newSession = (): TerminalSession => {
    const machine = props.machine;
    const cwd = props.session?.cwd;
    const runtime = sessions.runtimeFor(machine);
    return new TerminalSession({
      title: machine.name,
      terminal: createTerminal(dock),
      open: async (columns, rows) => {
        const [link, probe] = await machineAccess(runtime);
        const launch = remoteShellLaunch({ commandShell: probe.commandShell, shell: probe.shell, cwd });
        return HostTerminalBackend.start(link, launch, { columns, rows });
      },
    });
  };
  const open = () => deck().add(newSession());
  const restart = (session: TerminalSession) => {
    deck().close(session);
    deck().add(newSession());
  };

  return (
    <div class="terminal-tab">
      <div class="terminal-tab-bar">
        <div class="terminal-tab-strip">
          <For each={tabs()}>
            {(session, index) => (
              <TerminalTabButton
                title={(session.changed(), session.title)}
                selected={session === selected()}
                onSelect={() => deck().select(index())}
                onClose={() => deck().close(session)}
              />
            )}
          </For>
        </div>
        <IconButton
          icon={Symbols.text_decrease}
          iconSize={20}
          tooltip={t.dock.terminals.smaller}
          disabled={dock.terminalFontSize() <= minTerminalFontSize}
          onClick={() => zoom(dock, -1)}
        />
        <IconButton
          icon={Symbols.text_increase}
          iconSize={20}
          tooltip={t.dock.terminals.larger}
          disabled={dock.terminalFontSize() >= maxTerminalFontSize}
          onClick={() => zoom(dock, 1)}
        />
        <IconButton icon={Symbols.add} tooltip={t.dock.terminals.newTerminal} onClick={open} />
      </div>
      <Show
        when={selected()}
        keyed
        fallback={
          <DockEmptyState
            icon={Symbols.terminal}
            message={t.dock.terminals.empty({ machine: props.machine.name })}
            action={
              <TonalButton icon={Symbols.add} onClick={open}>
                {t.dock.terminals.newTerminal}
              </TonalButton>
            }
          />
        }
      >
        {(session) => (
          <TerminalPane
            session={session}
            fontSize={dock.terminalFontSize()}
            onRestart={() => restart(session)}
            onClose={() => deck().close(session)}
          />
        )}
      </Show>
    </div>
  );
}

function zoom(dock: DockController, delta: number): void {
  dock.setTerminalFontSize(dock.terminalFontSize() + delta);
}

/** One terminal in the tab strip: its title, selected by a stadium in a lighter tone, and a close button. */
function TerminalTabButton(props: {
  readonly title: string;
  readonly selected: boolean;
  readonly onSelect: () => void;
  readonly onClose: () => void;
}) {
  return (
    <div
      class={["terminal-tab-button", { "terminal-tab-button-selected": props.selected }]}
      data-ripple
      role="tab"
      aria-selected={props.selected ? "true" : "false"}
      tabindex="0"
      onClick={() => props.onSelect()}
      onKeyDown={(event) => {
        if (event.target !== event.currentTarget || (event.key !== "Enter" && event.key !== " ")) return;
        event.preventDefault();
        props.onSelect();
      }}
    >
      <span class="terminal-tab-button-title">{props.title}</span>
      <IconButton
        icon={Symbols.close}
        iconSize={16}
        size={28}
        class="terminal-tab-button-close"
        tooltip={t.dock.terminals.close}
        onClick={(event) => {
          event.stopPropagation();
          props.onClose();
        }}
      />
    </div>
  );
}

/** Each terminal's fit addon, which sizes its grid to the element it shows in. */
const fits = new WeakMap<Terminal, FitAddon>();

function fit(terminal: Terminal): void {
  fits.get(terminal)?.fit();
}

/** A terminal as terminal_tab.dart's TerminalView draws it: the code font, the dock's zoom, Cmd/Ctrl zoom keys. */
function createTerminal(dock: DockController): Terminal {
  const terminal = new Terminal({
    fontFamily: getComputedStyle(document.documentElement).getPropertyValue("--font-mono").trim(),
    fontSize: dock.terminalFontSize(),
    // xterm2's TerminalStyle line height.
    lineHeight: 1.2,
    scrollback: 10000,
    // A secondary click opens the pane's menu, as in the Flutter app, without selecting the word under it.
    rightClickSelectsWord: false,
    linkHandler: {
      activate: (_event, url) => void openExternalLink(url),
      // openExternalLink asks before it opens any scheme but a web page or a mail draft.
      allowNonHttpProtocols: true,
    },
  });
  const addon = new FitAddon();
  terminal.loadAddon(addon);
  fits.set(terminal, addon);
  // xterm.js answers no clipboard query; writes (a remote editor's yank) go to this device's clipboard.
  terminal.parser.registerOscHandler(52, (data) => {
    const text = osc52ClipboardText(data);
    if (text !== undefined) writeClipboard(text);
    return true;
  });
  terminal.attachCustomKeyEventHandler((event) => {
    const delta = zoomKey(event);
    if (delta === 0) return true;
    event.preventDefault();
    if (event.type === "keydown") zoom(dock, delta);
    return false;
  });
  return terminal;
}

/** Cmd+= and Cmd+- (Ctrl+Shift+= and Ctrl+Shift+- elsewhere) zoom the terminal: +1, -1, else 0. */
function zoomKey(event: KeyboardEvent): number {
  const command = event.metaKey && !event.ctrlKey && !event.shiftKey && !event.altKey;
  const control = event.ctrlKey && event.shiftKey && !event.metaKey && !event.altKey;
  if (!command && !control) return 0;
  return event.code === "Equal" ? 1 : event.code === "Minus" ? -1 : 0;
}

function writeClipboard(text: string): void {
  call("shell.clipboardWrite", { text }).catch((error: unknown) => appLogger.w("copying failed", { error }));
}

/**
 * The terminal's colours: the theme's text, background and selection tones for text, cursor and selection; its 16
 * ANSI tokens as they are. Read from the custom properties where the terminal shows, so a Custom theme's picks apply.
 */
function terminalTheme(element: HTMLElement): ITheme {
  const style = getComputedStyle(element);
  const token = (name: string) => style.getPropertyValue(`--${name}`).trim();
  const [red, green, blue] = token("on-surface-rgb").split(/\s+/);
  return {
    foreground: token("on-surface"),
    background: token("surface"),
    cursor: token("on-surface"),
    cursorAccent: token("surface"),
    selectionBackground: `rgba(${red}, ${green}, ${blue}, 0.25)`,
    black: token("ansi-black"),
    red: token("ansi-red"),
    green: token("ansi-green"),
    yellow: token("ansi-yellow"),
    blue: token("ansi-blue"),
    magenta: token("ansi-magenta"),
    cyan: token("ansi-cyan"),
    white: token("ansi-white"),
    brightBlack: token("ansi-bright-black"),
    brightRed: token("ansi-bright-red"),
    brightGreen: token("ansi-bright-green"),
    brightYellow: token("ansi-bright-yellow"),
    brightBlue: token("ansi-bright-blue"),
    brightMagenta: token("ansi-bright-magenta"),
    brightCyan: token("ansi-bright-cyan"),
    brightWhite: token("ansi-bright-white"),
  };
}

type PaneAction = "copy" | "paste" | "selectAll" | "clear";

function TerminalPane(props: {
  readonly session: TerminalSession;
  readonly fontSize: number;
  readonly onRestart: () => void;
  readonly onClose: () => void;
}) {
  let screen!: HTMLDivElement;
  let slot!: HTMLDivElement;
  const phase = createMemo((): TerminalPhase => {
    props.session.changed();
    return props.session.phase;
  });
  const banner = createMemo(() => {
    const current = phase();
    switch (current.kind) {
      case "TerminalFailed":
        return t.dock.terminals.failed({ error: String(current.error) });
      case "TerminalExited":
        return current.code === undefined
          ? t.dock.terminals.exitedBySignal
          : t.dock.terminals.exited({ code: String(current.code) });
      default:
        return undefined;
    }
  });

  createEffect(
    () => props.fontSize,
    (size) => {
      const terminal = props.session.terminal;
      if (terminal.options.fontSize === size) return;
      terminal.options.fontSize = size;
      fit(terminal);
    },
  );

  // The terminal's element moves into this pane's slot and out again when the pane goes: the session keeps it.
  onSettled(() => {
    const terminal = props.session.terminal;
    terminal.options.theme = terminalTheme(screen);
    let attached = true;
    const resizes = new ResizeObserver(() => fit(terminal));
    // The theme on <html> changes (Light, Dark, a Custom pick): the terminal takes its colours again.
    const themes = new MutationObserver(() => (terminal.options.theme = terminalTheme(screen)));
    themes.observe(document.documentElement, { attributes: true, attributeFilter: ["data-base", "style"] });
    const attach = async () => {
      if (terminal.element === undefined) {
        // xterm.js measures its cell once, when it opens: the code font has to be there by then.
        await document.fonts.load(`${terminal.options.fontSize ?? 13}px ${terminal.options.fontFamily ?? ""}`);
        if (!attached) return;
        terminal.open(slot);
      } else {
        slot.append(terminal.element);
      }
      fit(terminal);
      resizes.observe(slot);
      terminal.focus();
    };
    attach().catch((error: unknown) => appLogger.w("opening the terminal failed", { error }));
    return () => {
      attached = false;
      resizes.disconnect();
      themes.disconnect();
    };
  });

  const menu = async (event: MouseEvent) => {
    event.preventDefault();
    const terminal = props.session.terminal;
    const action = await showMenu<PaneAction>({
      anchor: { x: event.clientX, y: event.clientY },
      items: [
        { value: "copy", label: t.common.copy, disabled: !terminal.hasSelection() },
        { value: "paste", label: t.dock.terminals.paste },
        { value: "selectAll", label: t.dock.terminals.selectAll },
        { value: "clear", label: t.dock.terminals.clear },
      ],
    });
    switch (action) {
      case "copy":
        writeClipboard(terminal.getSelection());
        terminal.clearSelection();
        break;
      case "paste": {
        const text = await navigator.clipboard.readText();
        if (text !== "") terminal.paste(text);
        terminal.focus();
        break;
      }
      case "selectAll":
        terminal.selectAll();
        break;
      case "clear":
        terminal.clear();
        break;
      case undefined:
        break;
    }
  };

  return (
    <div class="terminal-tab-pane">
      <Show when={banner()}>
        {(message) => (
          <div class={["terminal-tab-banner", { "terminal-tab-banner-failed": phase().kind === "TerminalFailed" }]}>
            <p class="terminal-tab-banner-message">{message()}</p>
            <div class="terminal-tab-banner-actions">
              <TextButton onClick={() => props.onClose()}>{t.dock.terminals.close}</TextButton>
              <TextButton onClick={() => props.onRestart()}>{t.dock.terminals.restart}</TextButton>
            </div>
          </div>
        )}
      </Show>
      <div
        class="terminal-tab-screen"
        ref={screen}
        onContextMenu={(event) => {
          menu(event).catch((error: unknown) => appLogger.w("the terminal menu failed", { error }));
        }}
      >
        <div class="terminal-tab-slot" ref={slot} />
        {/* Where the prompt appears once the shell is up. */}
        <Show when={phase().kind === "TerminalStarting"}>
          <div class="terminal-tab-starting">
            <ActivityMark />
          </div>
        </Show>
      </div>
    </div>
  );
}
