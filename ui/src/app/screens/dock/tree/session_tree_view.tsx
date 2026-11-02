// The rows of lib/screens/dock/tree/tree_tab.dart (_TreeRowTile, _rowText, _kindIcon): how one entry of the session tree
// (session_tree.ts) looks in the Tree tab.
import { Show } from "solid-js";
import { t } from "../../../i18n/i18n";
import { formatTokens } from "../../../utils/token_count";
import { Icon } from "../../../widgets/icon";
import { ListRow } from "../../../widgets/list_row";
import * as Symbols from "../../../widgets/symbols";
import { tooltip } from "../../../widgets/tooltip";
import type { TreeEntry, TreeEntryKind, TreeRow } from "./session_tree";
import "./session_tree_view.css";

/** A row's text; entries without text of their own describe themselves. */
export function treeRowText(entry: TreeEntry): string {
  const strings = t.dock.sessionTree;
  switch (entry.kind) {
    case "assistant":
      if (entry.aborted) return strings.aborted;
      return entry.text.length === 0 ? strings.noContent : entry.text;
    case "compaction":
      return strings.compaction({ tokens: formatTokens(entry.tokensBefore ?? 0) });
    case "branchSummary":
      return strings.branchSummary({ summary: entry.text });
    case "modelChange":
      return strings.model({ model: entry.text });
    case "thinkingChange":
      return strings.thinking({ level: entry.text });
    case "label":
      return entry.text.length === 0 ? strings.labelCleared : strings.labelSet({ label: entry.text });
    case "advisor":
      return entry.advisorTags.length === 0
        ? strings.advisor({ notes: entry.text })
        : strings.advisorTagged({ tags: entry.advisorTags, notes: entry.text });
    case "other": {
      const type = `[${entry.type.replaceAll("_", " ")}]`;
      return entry.text.length === 0 ? type : `${type} ${entry.text}`;
    }
    default:
      return entry.text;
  }
}

const kindIcons: Readonly<Record<TreeEntryKind, string>> = {
  user: Symbols.person,
  assistant: Symbols.smart_toy,
  toolResult: Symbols.build,
  bash: Symbols.terminal,
  python: Symbols.code,
  custom: Symbols.extension,
  advisor: Symbols.rate_review,
  compaction: Symbols.compress,
  branchSummary: Symbols.call_split,
  modelChange: Symbols.swap_horiz,
  thinkingChange: Symbols.neurology,
  label: Symbols.label,
  other: Symbols.circle,
};

/**
 * One row: the active path's bar at the left edge, the indent, the branch head's toggle, the kind's icon, the label
 * chip, the text cut to one line, the count a collapsed branch hides and the current position's mark.
 */
export function SessionTreeRow(props: {
  readonly row: TreeRow;
  readonly selected: boolean;
  readonly onClick: () => void;
  /** Branch heads only: collapses or expands the branch. */
  readonly onToggle?: () => void;
  readonly onMenu: (point: { x: number; y: number }) => void;
}) {
  const entry = () => props.row.entry;
  return (
    <ListRow class="session-tree-row" selected={props.selected} onClick={props.onClick} onMenu={props.onMenu}>
      <span class={["session-tree-row-path", { "session-tree-row-path-active": props.row.onActivePath }]} />
      <span class="session-tree-row-toggle" style={{ "margin-left": `${4 + props.row.depth * 14}px` }}>
        <Show when={props.onToggle}>
          {(toggle) => (
            <button
              type="button"
              data-ripple
              class="session-tree-row-toggle-button"
              aria-expanded={props.row.collapsedCount === undefined ? "true" : "false"}
              onClick={(event) => {
                event.stopPropagation();
                toggle()();
              }}
            >
              <Icon icon={props.row.collapsedCount === undefined ? Symbols.expand_more : Symbols.chevron_right} size={18} />
            </button>
          )}
        </Show>
      </span>
      <Icon
        icon={kindIcons[entry().kind]}
        size={15}
        class={entry().kind === "user" ? "session-tree-row-icon-user" : "session-tree-row-icon"}
      />
      <Show when={entry().label}>{(label) => <span class="session-tree-row-label">{label()}</span>}</Show>
      <span
        class={[
          "session-tree-row-text",
          {
            "session-tree-row-text-muted": entry().bookkeeping || entry().kind === "toolResult",
            "session-tree-row-text-error": entry().error,
            "session-tree-row-text-leaf": props.row.isLeaf,
            "session-tree-row-text-empty": entry().text.length === 0,
          },
        ]}
      >
        {treeRowText(entry())}
      </span>
      <Show when={props.row.collapsedCount !== undefined}>
        <span class="session-tree-row-hidden">+{props.row.collapsedCount}</span>
      </Show>
      <Show when={props.row.isLeaf}>
        <span class="session-tree-row-leaf" ref={tooltip(() => t.dock.sessionTree.currentLeaf)}>
          <Icon icon={Symbols.my_location_fill} size={14} />
        </span>
      </Show>
    </ListRow>
  );
}
