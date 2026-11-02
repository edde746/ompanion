// Port of test/dock/dock_controller_test.dart, plus the requests other screens hand the dock.
import { afterEach, expect, spyOn, test } from "bun:test";
import { flush } from "solid-js";
import { Emitter } from "../../../core/util/stream";
import { MemoryFiles, memoryAccess } from "../../../test/memory_host";
import type { DockTab } from "../../models/dock_tab";
import { localMachine, type Machine } from "../../models/machine";
import { DockController, maxTerminalFontSize, minTerminalFontSize } from "./dock_controller";

/** The part of MachinesProvider the dock follows. */
function machineList(initial: readonly Machine[]) {
  let list = initial;
  const changes = new Emitter<void>();
  return {
    machines: () => list,
    changes: changes.stream,
    set(next: readonly Machine[]) {
      list = next;
      changes.add();
    },
  };
}

const local = localMachine({ id: "local", name: "This computer", createdAt: 0, updatedAt: 0 });
let dock: DockController;

afterEach(() => dock.dispose());

test("deleting a machine ends its shells and closes its open files", async () => {
  const machines = machineList([local]);
  dock = new DockController(machines);
  const deck = dock.terminals("local");
  const endShells = spyOn(deck, "dispose");
  const workspace = dock.files("local");
  workspace.connect = memoryAccess(new MemoryFiles({ "/home/test/notes.txt": "one\n" }));
  await workspace.open("/home/test/notes.txt");
  workspace.current()!.setText("unsaved\n");
  machines.set([local]);
  expect(endShells).not.toHaveBeenCalled();
  expect(workspace.documents()).toHaveLength(1);

  machines.set([]);
  expect(endShells).toHaveBeenCalledTimes(1);
  expect(workspace.documents()).toEqual([]);
  // The machine's next terminals and files start afresh.
  expect(dock.terminals("local")).not.toBe(deck);
  expect(dock.files("local")).not.toBe(workspace);
});

test("a file or agent request is taken once, and reveals its tab", () => {
  dock = new DockController(machineList([local]));
  const revealed: DockTab[] = [];
  dock.reveals.listen((tab) => revealed.push(tab));
  dock.openFile("src/main.ts", { line: 12 });
  dock.openSubagent("Echo");
  flush();
  expect(dock.requests()).toBe(2);
  expect(revealed).toEqual(["files", "agents"]);
  expect(dock.takeFileRequest()).toEqual({ path: "src/main.ts", line: 12 });
  expect(dock.takeFileRequest()).toBeUndefined();
  expect(dock.takeAgentRequest()).toBe("Echo");
  expect(dock.takeAgentRequest()).toBeUndefined();
});

test("the terminal font size stays within its bounds", () => {
  dock = new DockController(machineList([local]));
  dock.setTerminalFontSize(100);
  flush();
  expect(dock.terminalFontSize()).toBe(maxTerminalFontSize);
  dock.setTerminalFontSize(1);
  flush();
  expect(dock.terminalFontSize()).toBe(minTerminalFontSize);
});
