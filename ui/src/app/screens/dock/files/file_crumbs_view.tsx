// Breadcrumbs of a Files-tab path: ~ inside the home, otherwise / . The file viewer passes onRoot so the first
// segment returns to the list; other ancestors open that folder.
import { createEffect, createMemo, For, Show } from "solid-js";
import { breadcrumbs } from "../../../files/file_paths";
import { Icon } from "../../../widgets/icon";
import * as Symbols from "../../../widgets/symbols";
import { tooltip } from "../../../widgets/tooltip";
import { crumbKind } from "./file_crumbs";
import "./files_tab.css";

export function FileCrumbs(props: {
  readonly path: string;
  readonly home: string | undefined;
  readonly onOpen: (dir: string) => void;
  /** File viewer: the first segment (`~` or `/`) goes back to the list. */
  readonly onRoot?: () => void;
  readonly rootTooltip?: string;
  readonly class?: string;
}) {
  let strip!: HTMLDivElement;
  const crumbs = createMemo(() => breadcrumbs(props.path, props.home));
  const fileViewer = () => props.onRoot !== undefined;
  createEffect(crumbs, () => {
    strip.scrollLeft = strip.scrollWidth;
  });
  return (
    <div class={["files-tab-crumbs", props.class]} ref={strip}>
      <For each={crumbs()}>
        {(crumb, index) => {
          const kind = () => crumbKind(index(), crumbs().length, { fileViewer: fileViewer() });
          const activate = () => {
            switch (kind()) {
              case "showBrowser":
                props.onRoot?.();
                break;
              case "openDir":
                props.onOpen(crumb.path);
                break;
              case "current":
                break;
            }
          };
          return (
            <>
              <Show when={index() > 0}>
                <Icon icon={Symbols.chevron_right} size={16} class="files-tab-crumb-separator" />
              </Show>
              <Show
                when={kind() !== "current"}
                fallback={<span class="files-tab-crumb files-tab-crumb-last">{crumb.label}</span>}
              >
                <CrumbButton
                  label={crumb.label}
                  root={kind() === "showBrowser"}
                  tooltip={kind() === "showBrowser" ? props.rootTooltip : undefined}
                  onClick={activate}
                />
              </Show>
            </>
          );
        }}
      </For>
    </div>
  );
}

function CrumbButton(props: {
  readonly label: string;
  readonly root: boolean;
  readonly tooltip: string | undefined;
  readonly onClick: () => void;
}) {
  return (
    <button
      type="button"
      data-ripple
      class={["files-tab-crumb", { "files-tab-crumb-root": props.root }]}
      ref={props.tooltip === undefined ? undefined : tooltip(() => props.tooltip ?? "")}
      onClick={() => props.onClick()}
    >
      {props.label}
    </button>
  );
}
