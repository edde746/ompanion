// Dev gallery (`?gallery=overlays`): what opens over the app, for the shots of where it goes and how it moves
// (scripts/shots/overlays.ts). A menu button in each corner of the safe area, a context menu wherever the background is
// right-clicked, a long menu, a dialog, a snack bar with an action, a tooltip, and a composer menu above a stand-in
// composer block.
import { createSignal, For } from "solid-js";
import { TextButton, TonalButton } from "../../widgets/button";
import { Dialog, showDialog } from "../../widgets/dialog";
import { type MenuEntry, showMenu } from "../../widgets/popup_menu";
import { showSnackBar } from "../../widgets/snackbar";
import * as Symbols from "../../widgets/symbols";
import { ComposerBlock, ComposerMenu, ComposerMenuItem, ToolbarButton } from "../chat/composer_toolbar";

const items: MenuEntry<string>[] = [
  { value: "pin", label: "Pin", icon: Symbols.push_pin },
  { value: "read", label: "Mark read", icon: Symbols.check },
  { value: "refresh", label: "Refresh", icon: Symbols.refresh },
  { value: "configure", label: "Configure", detail: "Settings of this machine's omp", icon: Symbols.tune },
  { value: "install", label: "Install omp", icon: Symbols.download, disabled: true },
  { value: "remove", label: "Remove", icon: Symbols.close },
];

const longItems: MenuEntry<number>[] = Array.from({ length: 30 }, (_, index) => ({
  value: index,
  label: `Option ${index + 1}`,
  checked: index === 3,
}));

const corners = [
  { name: "Top left", style: { top: "calc(var(--inset-top) + 8px)", left: "calc(var(--inset-left) + 8px)" } },
  { name: "Top right", style: { top: "calc(var(--inset-top) + 8px)", right: "calc(var(--inset-right) + 8px)" } },
  { name: "Bottom left", style: { bottom: "calc(var(--inset-bottom) + 8px)", left: "calc(var(--inset-left) + 8px)" } },
  { name: "Bottom right", style: { bottom: "calc(var(--inset-bottom) + 8px)", right: "calc(var(--inset-right) + 8px)" } },
] as const;

export default function OverlaysGallery() {
  const [block, setBlock] = createSignal<HTMLElement | undefined>(undefined, { ownedWrite: true });
  const [button, setButton] = createSignal<HTMLButtonElement | undefined>(undefined, { ownedWrite: true });
  const [composerMenu, setComposerMenu] = createSignal(false);
  const anchored = (event: MouseEvent) => {
    if (event.currentTarget instanceof HTMLElement) void showMenu({ anchor: event.currentTarget, items });
  };
  return (
    <ComposerBlock value={block}>
      <div
        style={{ position: "relative", height: "100dvh", overflow: "hidden", background: "var(--surface)" }}
        onContextMenu={(event) => {
          event.preventDefault();
          void showMenu({ anchor: { x: event.clientX, y: event.clientY }, items });
        }}
      >
        <For each={corners}>
          {(corner) => (
            <div style={{ position: "absolute", ...corner.style }}>
              <TonalButton onClick={anchored}>{corner.name}</TonalButton>
            </div>
          )}
        </For>
        <div
          style={{
            position: "absolute",
            inset: "calc(var(--inset-top) + 64px) calc(var(--inset-right) + 16px) calc(var(--inset-bottom) + 64px) calc(var(--inset-left) + 16px)",
            display: "flex",
            "flex-direction": "column",
            "align-items": "center",
            "justify-content": "center",
            gap: "12px",
          }}
        >
          <TonalButton
            onClick={(event) => {
              if (event.currentTarget instanceof HTMLElement) {
                void showMenu({ anchor: event.currentTarget, items: longItems, matchWidth: true });
              }
            }}
          >
            Long menu
          </TonalButton>
          <TonalButton
            onClick={() =>
              void showDialog<boolean>((close) => (
                <Dialog
                  title="Delete this session?"
                  actions={
                    <>
                      <TextButton onClick={() => close(false)}>Cancel</TextButton>
                      <TextButton onClick={() => close(true)}>Delete</TextButton>
                    </>
                  }
                >
                  The session's history stays on the machine; only this app forgets it.
                </Dialog>
              ))
            }
          >
            Dialog
          </TonalButton>
          <TonalButton
            onClick={() =>
              showSnackBar("Copied the session's path", { action: { label: "Undo", onPressed: () => undefined } })
            }
          >
            Snack bar
          </TonalButton>
          <TonalButton tooltip="Shows under the button after a moment">Tooltip</TonalButton>
          <div
            ref={setBlock}
            style={{
              display: "flex",
              width: "min(100%, 520px)",
              padding: "8px",
              "border-radius": "var(--card-radius)",
              background: "var(--surface-container)",
            }}
          >
            <ToolbarButton
              icon={Symbols.neurology}
              label="medium"
              ref={setButton}
              onClick={() => setComposerMenu((open) => !open)}
            />
          </div>
          <ComposerMenu open={composerMenu()} onClose={() => setComposerMenu(false)} button={button()}>
            <For each={["off", "minimal", "low", "medium", "high"]}>
              {(level) => (
                <ComposerMenuItem label={level} checked={level === "medium"} onClick={() => setComposerMenu(false)} />
              )}
            </For>
          </ComposerMenu>
        </div>
      </div>
    </ComposerBlock>
  );
}
