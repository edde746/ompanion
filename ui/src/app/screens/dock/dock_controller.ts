// Port of lib/screens/dock/dock_controller.dart.
import { type Accessor, createSignal } from "solid-js";
import { Emitter, type EventStream, type Subscription } from "../../../core/util/stream";
import { FileWorkspace } from "../../files/file_workspace";
import type { DockTab } from "../../models/dock_tab";
import type { MachinesProvider } from "../../providers/machines_provider";
import { TerminalDeck } from "../../terminal/terminal_deck";

/** A file another screen asked the Files tab to open. */
export interface FileRequest {
  /** Absolute, host-native, `~/…`, or relative to the session's directory. */
  readonly path: string;
  /** 1-based line to reveal. */
  readonly line?: number;
}

export const minTerminalFontSize = 8;
export const maxTerminalFontSize = 28;

/**
 * The right dock's state that outlives its components: requests from other screens (switch tab, open a file, open a
 * subagent), the terminals and the Files workspaces of every machine, and the terminal font size.
 */
export class DockController {
  /** Bumps with every request; the Files and Agents tabs read it, then take their request. */
  readonly requests: Accessor<number>;
  readonly terminalFontSize: Accessor<number>;
  private readonly setRequests: (update: (count: number) => number) => void;
  private readonly setFontSize: (size: number) => void;
  private readonly revealEmitter = new Emitter<DockTab>();
  private readonly decks = new Map<string, TerminalDeck>();
  private readonly workspaces = new Map<string, FileWorkspace>();
  private fileRequest: FileRequest | undefined;
  private agentRequest: string | undefined;
  private readonly machinesWatch: Subscription;

  constructor(machines: Pick<MachinesProvider, "machines" | "changes">) {
    const [requests, setRequests] = createSignal(0);
    const [fontSize, setFontSize] = createSignal(13);
    this.requests = requests;
    this.setRequests = setRequests;
    this.terminalFontSize = fontSize;
    this.setFontSize = setFontSize;
    this.machinesWatch = machines.changes.listen(() =>
      this.forgetMachinesExcept(new Set(machines.machines().map((machine) => machine.id))),
    );
  }

  /** Tabs to bring into view. The shell shows the dock (inline, drawer, or the narrow panels page) and selects the tab. */
  get reveals(): EventStream<DockTab> {
    return this.revealEmitter.stream;
  }

  show(tab: DockTab): void {
    this.revealEmitter.add(tab);
  }

  /** Opens `path` in the Files tab of the active session's machine and reveals `line`. */
  openFile(path: string, options: { line?: number } = {}): void {
    this.fileRequest = { path, line: options.line };
    this.setRequests((count) => count + 1);
    this.show("files");
  }

  /** Selects the agent `id` in the Agent Hub. */
  openSubagent(id: string): void {
    this.agentRequest = id;
    this.setRequests((count) => count + 1);
    this.show("agents");
  }

  /** The pending file request, once. */
  takeFileRequest(): FileRequest | undefined {
    const request = this.fileRequest;
    this.fileRequest = undefined;
    return request;
  }

  /** The pending agent selection, once. */
  takeAgentRequest(): string | undefined {
    const request = this.agentRequest;
    this.agentRequest = undefined;
    return request;
  }

  terminals(machineId: string): TerminalDeck {
    let deck = this.decks.get(machineId);
    if (deck === undefined) {
      deck = new TerminalDeck();
      this.decks.set(machineId, deck);
    }
    return deck;
  }

  files(machineId: string): FileWorkspace {
    let workspace = this.workspaces.get(machineId);
    if (workspace === undefined) {
      workspace = new FileWorkspace();
      this.workspaces.set(machineId, workspace);
    }
    return workspace;
  }

  setTerminalFontSize(size: number): void {
    this.setFontSize(Math.min(maxTerminalFontSize, Math.max(minTerminalFontSize, size)));
  }

  dispose(): void {
    this.machinesWatch.cancel();
    for (const deck of this.decks.values()) deck.dispose();
    for (const workspace of this.workspaces.values()) workspace.dispose();
    this.decks.clear();
    this.workspaces.clear();
    this.revealEmitter.close();
  }

  /** A deleted machine's shells end and its open files close, unsaved edits included: nothing reaches it any more. */
  private forgetMachinesExcept(ids: ReadonlySet<string>): void {
    for (const [id, deck] of [...this.decks]) {
      if (ids.has(id)) continue;
      this.decks.delete(id);
      deck.dispose();
    }
    for (const [id, workspace] of [...this.workspaces]) {
      if (ids.has(id)) continue;
      this.workspaces.delete(id);
      workspace.dispose();
    }
  }
}
