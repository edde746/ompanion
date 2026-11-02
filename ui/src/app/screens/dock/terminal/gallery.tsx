// Dev gallery (`?gallery=terminal`): the Terminal tab on this computer, at the inline dock's width on wide screens and
// the whole screen on phones, with no session shown.
import { localMachine } from "../../../models/machine";
import { TerminalTab } from "./terminal_tab";

const machine = localMachine({ id: "local", name: "This computer", createdAt: 0, updatedAt: 0 });

export default function TerminalGallery() {
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
        <TerminalTab machine={machine} session={undefined} />
      </div>
    </div>
  );
}
