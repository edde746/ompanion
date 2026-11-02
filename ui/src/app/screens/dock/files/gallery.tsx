// Dev gallery (`?gallery=files`): the Files tab on this computer, at the inline dock's width on wide screens and the
// whole screen on phones, with no session shown, so it browses the home directory. It takes the machine boot adds for
// this computer: the dock forgets the files of a machine that is not in the list.
import { Show } from "solid-js";
import { useMachines } from "../../../app_state";
import { FilesTab } from "./files_tab";

export default function FilesGallery() {
  const machines = useMachines();
  return (
    <div
      style={{
        display: "flex",
        "justify-content": "flex-end",
        height: "100dvh",
        "padding-top": "var(--inset-top)",
        "padding-bottom": "var(--inset-bottom)",
        background: "var(--surface)",
      }}
    >
      <div style={{ width: "min(100%, 340px)", background: "var(--surface-container-low)" }}>
        <Show when={machines.machines().find((machine) => machine.kind === "LocalMachine")} keyed>
          {(machine) => <FilesTab machine={machine} session={undefined} />}
        </Show>
      </div>
    </div>
  );
}
