// Port of lib/screens/config/config_widgets.dart: the pieces every configuration page is built from.
import type { JSX } from "@solidjs/web";
import { createSignal, For, onSettled, Show } from "solid-js";
import { call } from "../../../bridge";
import type { Provenance } from "../../config/settings_schema";
import { t } from "../../i18n/i18n";
import { appLogger } from "../../utils/app_logger";
import { ActivityMark } from "../../widgets/activity_mark";
import { FilledButton, IconButton, TextButton, TonalButton } from "../../widgets/button";
import { Dialog, showDialog } from "../../widgets/dialog";
import { Icon } from "../../widgets/icon";
import { showSnackBar } from "../../widgets/snackbar";
import * as Symbols from "../../widgets/symbols";
import { tooltip } from "../../widgets/tooltip";
import { ansiRunStyle, parseAnsi } from "../chat/transcript/ansi";
import "./config_widgets.css";

/** What a failure says, as Dart's `'$error'` shows an exception. */
export function errorText(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}

/**
 * The layer a value comes from, as a small tag. An environment variable is the one layer the files cannot change, so
 * it reads as a warning.
 */
export function ProvenanceBadge(props: { readonly provenance: Provenance; readonly envName?: string }) {
  const label = () => {
    const names = t.config.provenance;
    switch (props.provenance) {
      case "env":
        return names.env({ name: props.envName ?? "?" });
      case "runtime":
        return names.runtime;
      case "overlay":
        return names.overlay;
      case "project":
        return names.project;
      case "global":
        return names.global;
      case "default":
        return names.defaults;
    }
  };
  const hint = () => {
    const names = t.config.provenance;
    switch (props.provenance) {
      case "env":
        return names.envHint({ name: props.envName ?? "?" });
      case "runtime":
        return names.runtimeHint;
      case "overlay":
        return names.overlayHint;
      case "project":
        return names.projectHint;
      case "global":
        return names.globalHint;
      case "default":
        return names.defaultsHint;
    }
  };
  return (
    <span class="config-provenance" ref={tooltip(hint)}>
      <ConfigTag
        label={label()}
        color={
          props.provenance === "env"
            ? "var(--warning)"
            : props.provenance === "default"
              ? "var(--on-surface-variant)"
              : "var(--on-surface)"
        }
      />
    </span>
  );
}

/** A short status word on a tone-lighter pill: provenance, "in use", "installed". */
export function ConfigTag(props: {
  readonly label: string;
  /** Text colour, a CSS value; secondary text by default. */
  readonly color?: string;
}) {
  return (
    <span class="config-tag" style={props.color === undefined ? undefined : { color: props.color }}>
      {props.label}
    </span>
  );
}

/** A flat group: a `surfaceContainer` block with the card radius, 12 px inside unless [padding] says otherwise. */
export function ConfigBlock(props: {
  readonly children: JSX.Element;
  /** CSS padding. */
  readonly padding?: string;
  readonly class?: string;
}) {
  return (
    <div class={["config-block", props.class]} style={props.padding === undefined ? undefined : { padding: props.padding }}>
      {props.children}
    </div>
  );
}

/** A ref for an element and its content width, followed as it resizes; 0 until it is laid out. */
export function createWidth(): [width: () => number, ref: (element: HTMLElement) => void] {
  const [width, setWidth] = createSignal(0);
  let element: HTMLElement | undefined;
  onSettled(() => {
    if (element === undefined) return;
    const observer = new ResizeObserver(([entry]) => setWidth(entry?.contentRect.width ?? 0));
    observer.observe(element);
    return () => observer.disconnect();
  });
  return [width, (next) => (element = next)];
}

export interface StatTile {
  readonly label: string;
  readonly value: string;
  /** A muted line under the value; `""` keeps the line's height, so a row where some tiles have one stays even. */
  readonly detail?: string;
}

/**
 * Headline numbers (design.md, Stat tiles): equal tiles of 160 px or more, in rows that hold the same number of tiles
 * where they can, so 8 tiles are 4 + 4, never 6 + 2.
 */
export function StatTiles(props: { readonly tiles: readonly StatTile[] }) {
  const [width, measure] = createWidth();
  const perRow = () => {
    const count = props.tiles.length;
    const fit = Math.max(2, Math.min(count, Math.floor((width() + 12) / (160 + 12))));
    return Math.ceil(count / Math.ceil(count / fit));
  };
  return (
    <div ref={measure} class="stat-tiles" style={{ "grid-template-columns": `repeat(${perRow()}, minmax(0, 1fr))` }}>
      <For each={props.tiles}>
        {(tile) => (
          <ConfigBlock padding="12px 14px">
            <div class="stat-tiles-label">{tile.label}</div>
            <div class="stat-tiles-value">{tile.value}</div>
            <Show when={tile.detail !== undefined}>
              <div class="stat-tiles-detail">{tile.detail}</div>
            </Show>
          </ConfigBlock>
        )}
      </For>
    </div>
  );
}

/** A note above content: secondary text on a flat block, or an error on the muted error surface. */
export function ConfigBanner(props: { readonly text: string; readonly error?: boolean }) {
  return (
    <div class={["config-banner", { "config-banner-error": props.error }]}>
      <Icon icon={props.error ? Symbols.error : Symbols.info} size={16} class="config-banner-icon" />
      <span class="config-banner-text">{props.text}</span>
    </div>
  );
}

export interface ConfigPill<T> {
  readonly value: T;
  readonly label: string;
  readonly icon?: string;
}

/**
 * A horizontally scrolling strip of flat pills; the selected one is a stadium one tone lighter (design.md rule 8).
 * Section switchers and settings tabs.
 */
export function ConfigPills<T>(props: {
  readonly value: T;
  readonly items: readonly ConfigPill<T>[];
  readonly onChanged: (value: T) => void;
  /** Padding at the strip's ends, e.g. `0 12px`. */
  readonly class?: string;
}) {
  return (
    <div class={["config-pills", props.class]} role="tablist">
      <For each={props.items}>
        {(item) => {
          const selected = () => item.value === props.value;
          return (
            <button
              type="button"
              role="tab"
              data-ripple={!selected()}
              aria-selected={selected() ? "true" : "false"}
              class={["config-pill", { "config-pill-selected": selected() }]}
              onClick={() => {
                if (!selected()) props.onChanged(item.value);
              }}
            >
              <Show when={item.icon}>{(icon) => <Icon icon={icon()} size={16} />}</Show>
              <span>{item.label}</span>
            </button>
          );
        }}
      </For>
    </div>
  );
}

/** A small heading inside a page's list. */
export function ConfigSectionTitle(props: { readonly text: string; readonly trailing?: JSX.Element }) {
  return (
    <div class={["config-section-title", { "config-section-title-control": props.trailing !== undefined }]}>
      <h3>{props.text}</h3>
      {props.trailing}
    </div>
  );
}

const ansiEscape = /\x1B\[[0-9;?]*[A-Za-z]/g;

/** ANSI text from omp (`command_output`, CLI output), selectable, in a monospace block as tall as its text. */
export function CommandOutputView(props: { readonly text: string }) {
  return (
    <ConfigBlock class="config-output" padding="8px 4px 8px 12px">
      <pre class="config-output-text">
        <For each={parseAnsi(props.text)}>{(run) => <span style={ansiRunStyle(run.style)}>{run.text}</span>}</For>
      </pre>
      <IconButton
        icon={Symbols.content_copy}
        tooltip={t.common.copy}
        size={28}
        iconSize={16}
        onClick={() => void call("shell.clipboardWrite", { text: props.text.replace(ansiEscape, "") })}
      />
    </ConfigBlock>
  );
}

/** The command a page ran, the activity mark while it runs, and its output. */
export function CommandRun(props: { readonly command: string; readonly running: boolean; readonly output?: string }) {
  return (
    <div class="config-run">
      <div class="config-run-command">
        <span>{props.command}</span>
        <Show when={props.running}>
          <ActivityMark size={14} />
        </Show>
      </div>
      <Show when={props.output !== undefined}>
        <CommandOutputView text={props.output === "" ? t.config.noOutput : (props.output ?? "")} />
      </Show>
    </div>
  );
}

/** A failure shown in place of content, with a retry. */
export function ConfigError(props: { readonly error: unknown; readonly onRetry?: () => void }) {
  return (
    <div class="config-error">
      <p class="config-error-text">{errorText(props.error)}</p>
      <Show when={props.onRetry}>
        {(retry) => (
          <TonalButton icon={Symbols.refresh} onClick={() => retry()()}>
            {t.common.retry}
          </TonalButton>
        )}
      </Show>
    </div>
  );
}

/** A page title row with trailing actions, and an optional secondary line under it. */
export function ConfigHeader(props: {
  readonly title: string;
  readonly subtitle?: string;
  readonly actions?: JSX.Element;
}) {
  return (
    <div class="config-header">
      <div class="config-header-text">
        <h2>{props.title}</h2>
        <Show when={props.subtitle}>{(subtitle) => <p>{subtitle()}</p>}</Show>
      </div>
      <Show when={props.actions}>
        <div class="config-header-actions">{props.actions}</div>
      </Show>
    </div>
  );
}

/** The refresh button of a page; the activity mark takes the icon's place while the page loads. */
export function RefreshAction(props: { readonly loading: boolean; readonly onPressed: () => void }) {
  return (
    <Show
      when={props.loading}
      fallback={<IconButton icon={Symbols.refresh} tooltip={t.config.refresh} onClick={() => props.onPressed()} />}
    >
      <span class="config-refresh-busy" ref={tooltip(() => t.config.refresh)}>
        <ActivityMark size={16} />
      </span>
    </Show>
  );
}

/**
 * Runs [action], shows its failure as a snack bar, and returns whether it succeeded. Failures are logged unless
 * [secret]: errors about a secret value may quote it.
 */
export async function runReporting(
  action: () => Promise<unknown>,
  options: { done?: string; secret?: boolean } = {},
): Promise<boolean> {
  try {
    await action();
    if (options.done !== undefined) showSnackBar(options.done);
    return true;
  } catch (error) {
    if (options.secret !== true) appLogger.w("config action failed", { error });
    showSnackBar(errorText(error), { error: true, durationMs: 8000 });
    return false;
  }
}

/** Asks a yes/no question; true when confirmed. */
export async function confirmAction(options: { title: string; body: string; action: string }): Promise<boolean> {
  const confirmed = await showDialog<boolean>((close) => (
    <Dialog
      title={options.title}
      actions={
        <>
          <TextButton onClick={() => close(false)}>{t.common.cancel}</TextButton>
          <FilledButton onClick={() => close(true)}>{options.action}</FilledButton>
        </>
      }
    >
      <p class="config-dialog-text">{options.body}</p>
    </Dialog>
  ));
  return confirmed ?? false;
}
