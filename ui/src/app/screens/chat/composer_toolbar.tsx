// Port of lib/screens/chat/composer_toolbar.dart, with what the composer toolbar's menus share: ToolbarButton and
// menuOffsetAbove of lib/screens/chat/model_picker.dart, as ComposerMenu (the menu above the composer block) here.
import { Portal, type JSX } from "@solidjs/web";
import { type Accessor, createContext, createEffect, createSignal, For, Show, useContext } from "solid-js";
import type { LiveSession } from "../../../core/session/live_session";
import type { ContextUsage } from "../../../core/store/session_view";
import { t } from "../../i18n/i18n";
import { insets, isDesktop, onBack } from "../../platform";
import { formatFixed, formatUsd } from "../../utils/number_format";
import { formatTokens } from "../../utils/token_count";
import { ActivityMark } from "../../widgets/activity_mark";
import { Icon } from "../../widgets/icon";
import { safeArea } from "../../widgets/menu_placement";
import { menuMotion } from "../../widgets/popup_menu";
import { showSnackBar } from "../../widgets/snackbar";
import * as Symbols from "../../widgets/symbols";
import { tooltip } from "../../widgets/tooltip";
import "./composer_toolbar.css";

/** The composer block (the flat surface around queue, attachments, text and toolbar) the toolbar's menus open above. */
export const ComposerBlock = createContext<Accessor<HTMLElement | undefined>>();

const gap = 8;

/** The tallest a menu above the composer gets (docs/design.md, Menu from the composer toolbar). */
export const composerMenuMaxHeight = 420;

export interface ComposerMenuProps {
  readonly open: boolean;
  /** A click outside the menu and its button, Escape and back ask it to close. */
  readonly onClose: () => void;
  /**
   * The button that opened the menu: the menu starts at its left edge, moved left as far as it takes to end by the
   * block's right edge. Without one the menu starts at the block's left edge.
   */
  readonly button?: HTMLElement;
  /** At most this wide; never wider than the block. Without it the menu is as wide as its content. */
  readonly maxWidth?: number;
  /** As wide as `maxWidth` allows, as the model list is. */
  readonly fill?: boolean;
  readonly label?: string;
  readonly children: JSX.Element;
}

/**
 * A menu of the composer toolbar: it opens `gap` above the composer block, never over it, within the block's and the
 * safe area's sides, and is at most as tall as the room between the safe area's top (plus `gap`) and the block, up to
 * composerMenuMaxHeight. It follows the block every frame while open, so it stays above the composer while the
 * on-screen keyboard raises or lowers it. It moves as the other menus do (menuMotion), opening upward, and stays on
 * screen, inert, until its closing motion ends.
 */
export function ComposerMenu(props: ComposerMenuProps) {
  const block = useContext(ComposerBlock);
  const [shown, setShown] = createSignal<boolean>((was) => props.open || was === true);
  let menu: HTMLDivElement | undefined;
  let motion: ((open: boolean) => Promise<boolean>) | undefined;

  createEffect(
    () => (props.open ? { button: props.button, maxWidth: props.maxWidth, fill: props.fill, close: props.onClose } : undefined),
    (open) => {
      if (!open) {
        void (motion?.(false) ?? Promise.resolve(true)).then((ended) => {
          if (ended && !props.open) setShown(false);
        });
        return;
      }
      let frame = 0;
      let placed = false;
      const follow = () => {
        const element = block();
        if (menu && element) {
          const rect = element.getBoundingClientRect();
          const area = safeArea(window.innerWidth, window.innerHeight, insets());
          const left = Math.max(rect.left, area.left);
          const right = Math.min(rect.right, area.right);
          const width = Math.min(open.maxWidth ?? right - left, right - left);
          menu.style.maxWidth = `${width}px`;
          if (open.fill) menu.style.width = `${width}px`;
          const start = open.button?.getBoundingClientRect().left ?? left;
          menu.style.left = `${Math.max(left, Math.min(start, right - menu.offsetWidth))}px`;
          const bottom = Math.min(rect.top - gap, area.bottom);
          menu.style.bottom = `${window.innerHeight - bottom}px`;
          menu.style.maxHeight = `${Math.max(0, Math.min(composerMenuMaxHeight, bottom - area.top))}px`;
          if (!placed) {
            placed = true;
            // The model list's search field takes the focus itself; anything else, so Escape reaches the menu.
            if (isDesktop() && !menu.contains(document.activeElement)) menu.focus();
            motion ??= menuMotion(menu, true);
            void motion(true);
          }
        }
        frame = requestAnimationFrame(follow);
      };
      follow();
      const outside = (event: PointerEvent) => {
        const target = event.target as Node;
        if (menu?.contains(target) || open.button?.contains(target)) return;
        open.close();
      };
      window.addEventListener("pointerdown", outside, true);
      const removeBack = onBack(() => open.close());
      return () => {
        cancelAnimationFrame(frame);
        window.removeEventListener("pointerdown", outside, true);
        removeBack();
      };
    },
  );

  return (
    <Show when={shown()}>
      <Portal mount={document.body}>
        <div
          class="composer-menu"
          role="menu"
          aria-label={props.label}
          tabindex="-1"
          inert={!props.open}
          aria-hidden={props.open ? undefined : "true"}
          ref={(element) => {
            menu = element;
            motion = undefined;
          }}
          onKeyDown={(event) => {
            // Esc closes the menu before the chat's shortcut, which would abort a run, sees it.
            if (event.key !== "Escape") return;
            event.preventDefault();
            event.stopPropagation();
            props.onClose();
          }}
        >
          {props.children}
        </div>
      </Portal>
    </Show>
  );
}

export interface ComposerMenuItemProps {
  readonly label: string;
  readonly icon?: string;
  /** The leading check slot: a check while true; absent leaves no slot. */
  readonly checked?: boolean;
  readonly disabled?: boolean;
  readonly onClick: () => void;
}

/** One row of a ComposerMenu, as a MenuItemButton: one control tall. */
export function ComposerMenuItem(props: ComposerMenuItemProps) {
  return (
    <button
      type="button"
      class="composer-menu-item"
      role={props.checked === undefined ? "menuitem" : "menuitemcheckbox"}
      aria-checked={props.checked === undefined ? undefined : props.checked ? "true" : "false"}
      disabled={props.disabled}
      data-ripple
      onClick={() => props.onClick()}
    >
      <Show when={props.checked !== undefined}>
        <span class="composer-menu-item-check">
          <Show when={props.checked}>
            <Icon icon={Symbols.check} size={18} />
          </Show>
        </span>
      </Show>
      <Show when={props.icon}>{(icon) => <Icon icon={icon()} size={18} class="composer-menu-item-icon" />}</Show>
      <span class="composer-menu-item-label">{props.label}</span>
    </button>
  );
}

export interface ToolbarButtonProps {
  readonly icon: string;
  readonly label: string;
  readonly tooltip?: string;
  /** Absent: disabled. */
  readonly onClick?: () => void;
  /** Shows the activity mark in place of `icon`. */
  readonly busy?: boolean;
  /** Icon and label colour when they carry a state (docs/design.md rule 2), a CSS colour; onSurfaceVariant otherwise. */
  readonly color?: string;
  readonly ref?: (element: HTMLButtonElement) => void;
}

/** A low-emphasis toolbar control: icon, label and a chevron, the height of every other control. */
export function ToolbarButton(props: ToolbarButtonProps) {
  return (
    <button
      type="button"
      class="toolbar-button"
      style={{ color: props.color }}
      disabled={props.onClick === undefined}
      data-ripple
      onClick={() => props.onClick?.()}
      ref={[(element: HTMLButtonElement) => props.ref?.(element), tooltip(() => props.tooltip ?? props.label)]}
    >
      <Show when={props.busy} fallback={<Icon icon={props.icon} size={16} />}>
        <ActivityMark size={16} color="currentColor" />
      </Show>
      <span class="toolbar-button-label">{props.label}</span>
      <Icon icon={Symbols.expand_more} size={16} />
    </button>
  );
}

/** The level omp reports for a model without thinking. */
const off = "off";

/** A level in the app's language; omp's ids for levels it adds later stay as they are. */
function thinkingLevelLabel(level: string): string {
  const labels = t.chat.thinkingLevels;
  return Object.hasOwn(labels, level) ? labels[level as keyof typeof labels] : level;
}

/** The thinking level button: loads the model's levels when opened and marks the current one. */
export function ThinkingPicker(props: {
  readonly session: LiveSession;
  /** Undefined when the model reports none, which omp treats as off. */
  readonly level: string | undefined;
}) {
  const [loading, setLoading] = createSignal(false);
  const [levels, setLevels] = createSignal<readonly string[]>([]);
  const [open, setOpen] = createSignal(false);
  // The button's ref writes it while the picker renders.
  const [button, setButton] = createSignal<HTMLButtonElement | undefined>(undefined, { ownedWrite: true });
  const current = () => props.level ?? off;

  async function show() {
    setLoading(true);
    let available: string[];
    try {
      available = await props.session.rpc.getAvailableThinkingLevels();
    } catch (error) {
      showSnackBar(t.chat.thinkingFailed({ error: String(error) }));
      return;
    } finally {
      setLoading(false);
    }
    if (available.length === 0) {
      showSnackBar(t.chat.noThinking);
      return;
    }
    setLevels(available);
    setOpen(true);
  }

  async function set(level: string) {
    setOpen(false);
    if (level === current()) return;
    try {
      await props.session.rpc.setThinkingLevel(level);
    } catch (error) {
      showSnackBar(t.chat.thinkingFailed({ error: String(error) }));
    }
  }

  return (
    <>
      <ToolbarButton
        icon={Symbols.neurology}
        label={thinkingLevelLabel(current())}
        tooltip={t.chat.thinking({ level: thinkingLevelLabel(current()) })}
        busy={loading()}
        ref={setButton}
        onClick={() => (open() ? setOpen(false) : loading() ? undefined : void show())}
      />
      <ComposerMenu open={open()} onClose={() => setOpen(false)} button={button()}>
        <For each={levels()}>
          {(level) => (
            <ComposerMenuItem
              label={thinkingLevelLabel(level)}
              checked={level === current()}
              onClick={() => void set(level)}
            />
          )}
        </For>
      </ComposerMenu>
    </>
  );
}

/** Context use of the session as a ring and a percentage; the tooltip adds tokens and cost. */
export function ContextMeter(props: { readonly usage: ContextUsage | undefined; readonly cost: number }) {
  const fraction = () => (props.usage === undefined ? 0 : Math.min(1, Math.max(0, props.usage.percent / 100)));
  const color = () =>
    fraction() >= 0.9 ? "var(--error)" : fraction() >= 0.7 ? "var(--warning)" : "var(--on-surface-variant)";
  const message = () => {
    const cost = formatUsd(props.cost, props.cost < 1 ? 4 : 2);
    const usage = props.usage;
    return usage === undefined
      ? t.chat.contextUnknown({ cost })
      : t.chat.contextTooltip({
          tokens: formatTokens(usage.tokens),
          window: formatTokens(usage.contextWindow),
          percent: formatFixed(usage.percent, 1),
          cost,
        });
  };
  const radius = 5.75;
  const circumference = 2 * Math.PI * radius;
  return (
    <span class="context-meter" ref={tooltip(message)} tabindex="0">
      <svg width="14" height="14" viewBox="0 0 14 14" aria-hidden="true">
        <circle cx="7" cy="7" r={radius} fill="none" stroke="var(--surface-container-highest)" stroke-width="2.5" />
        <circle
          cx="7"
          cy="7"
          r={radius}
          fill="none"
          stroke={color()}
          stroke-width="2.5"
          stroke-dasharray={`${fraction() * circumference} ${circumference}`}
          transform="rotate(-90 7 7)"
        />
      </svg>
      <span class="context-meter-label">
        {props.usage === undefined ? "–" : t.units.percent({ value: Math.round(props.usage.percent) })}
      </span>
    </span>
  );
}
