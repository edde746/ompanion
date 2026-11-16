// Breadcrumbs of a Files-tab path: ~ inside the home, otherwise / . Each ancestor opens that folder.
import { createEffect, createMemo, For, Show } from "solid-js";
import { breadcrumbs } from "../../../files/file_paths";
import { Icon } from "../../../widgets/icon";
import * as Symbols from "../../../widgets/symbols";
import { crumbKind } from "./file_crumbs";
import "./files_tab.css";

export function FileCrumbs(props: {
  readonly path: string;
  readonly home: string | undefined;
  readonly onOpen: (dir: string) => void;
  readonly class?: string;
}) {
  let strip!: HTMLDivElement;
  const crumbs = createMemo(() => breadcrumbs(props.path, props.home));
  createEffect(crumbs, () => {
    strip.scrollLeft = strip.scrollWidth;
  });
  return (
    <div class={["files-tab-crumbs", props.class]} ref={strip}>
      <For each={crumbs()}>
        {(crumb, index) => (
          <>
            <Show when={index() > 0}>
              <Icon icon={Symbols.chevron_right} size={16} class="files-tab-crumb-separator" />
            </Show>
            <Show
              when={crumbKind(index(), crumbs().length) !== "current"}
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
