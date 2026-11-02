// Port of lib/screens/chat/mode_controls.dart; its decisions are in mode_verbs.ts.
import type { JSX } from "@solidjs/web";
import { createEffect, createMemo, createSignal, For, onSettled, Show, untrack } from "solid-js";
import type { JsonObject } from "../../../core/rpc/json_fields";
import type { LiveSession } from "../../../core/session/live_session";
import { type Goal, type GoalStatus, type LoopState, loopStatePhase } from "../../../core/store/session_view";
import { t } from "../../i18n/i18n";
import { compactDuration } from "../../utils/compact_duration";
import { formatTokens } from "../../utils/token_count";
import { FilledButton, IconButton, TextButton } from "../../widgets/button";
import { Dialog, showDialog } from "../../widgets/dialog";
import { LabeledField } from "../../widgets/labeled_field";
import { showSnackBar } from "../../widgets/snackbar";
import * as Symbols from "../../widgets/symbols";
import { TextField } from "../../widgets/text_field";
import { ComposerMenu, ComposerMenuItem, ToolbarButton } from "./composer_toolbar";
import { goalActions, loopActions, parseBudget, verbFailure } from "./mode_verbs";
import "./mode_controls.css";

/** `status` in words, for the goal control and the `goal` tool's line. */
export function goalStatusLabel(status: GoalStatus): string {
  return t.goal.status[status];
}

/** Tokens used against the budget: `12.4K of 50K tokens (37.6K left)`, or `12.4K tokens, no budget`. */
export function goalUsage(used: number, budget?: number): string {
  return budget === undefined
    ? t.goal.usageNoBudget({ used: formatTokens(used) })
    : t.goal.usage({
        used: formatTokens(used),
        budget: formatTokens(budget),
        left: formatTokens(Math.max(0, budget - used)),
      });
}

/**
 * Calls `verb`; a failure shows as a snack bar with the companion's own message, also when the control is gone by the
 * reply, e.g. because the goal completed meanwhile.
 */
async function modeCall(
  session: LiveSession,
  verb: string,
  args: JsonObject,
  failed: (args: { error: string }) => string,
): Promise<void> {
  try {
    await session.companion.call(verb, args);
  } catch (error) {
    showSnackBar(failed({ error: verbFailure(error) }));
  }
}

/** Widest a goal or loop menu gets; narrower where the composer is. */
const menuWidth = 360;

const held = "var(--warning)";

/**
 * The goal's toolbar control: its tokens against the budget, as the TUI's footer shows them, and a menu with the
 * objective and its usage over pause or resume, the budget and drop.
 */
export function GoalControl(props: { readonly session: LiveSession; readonly goal: Goal }) {
  const [open, setOpen] = createSignal(false);
  // The button's ref sets it while the component renders.
  const [button, setButton] = createSignal<HTMLButtonElement | undefined>(undefined, { ownedWrite: true });
  let mounted = true;
  onSettled(() => () => {
    mounted = false;
  });

  const status = () => goalStatusLabel(props.goal.status);
  const usage = () => goalUsage(props.goal.tokensUsed, props.goal.tokenBudget);
  const isHeld = () => props.goal.status !== "active";
  const label = () => {
    const used = formatTokens(props.goal.tokensUsed);
    const budget = props.goal.tokenBudget;
    return t.goal.label({ usage: budget === undefined ? used : `${used}/${formatTokens(budget)}` });
  };

  function call(verb: string, args: JsonObject = {}) {
    setOpen(false);
    void modeCall(props.session, verb, args, t.goal.failed);
  }

  async function drop() {
    setOpen(false);
    const confirmed = await showDialog<boolean>((close) => (
      <Dialog
        title={t.goal.dropTitle}
        actions={
          <>
            <TextButton onClick={() => close(false)}>{t.common.cancel}</TextButton>
            <FilledButton onClick={() => close(true)}>{t.goal.dropConfirm}</FilledButton>
          </>
        }
      >
        {t.goal.dropBody}
      </Dialog>
    ));
    if (confirmed !== true || !mounted) return;
    await modeCall(props.session, "goal.drop", {}, t.goal.failed);
  }

  return (
    <>
      <ToolbarButton
        icon={
          props.goal.status === "paused"
            ? Symbols.pause_fill
            : props.goal.status === "budgetLimited"
              ? Symbols.warning
              : Symbols.flag
        }
        color={isHeld() ? held : undefined}
        label={label()}
        tooltip={t.goal.tooltip({ status: status(), usage: usage() })}
        ref={setButton}
        onClick={() => setOpen((shown) => !shown)}
      />
      <ComposerMenu
        open={open()}
        onClose={() => setOpen(false)}
        button={button()}
        maxWidth={menuWidth}
        fill
        label={label()}
      >
        <MenuHeader text={props.goal.objective}>
          {/* Each fact stays whole: the line breaks only between them. */}
          <span class="mode-controls-fact">
            <span class={["mode-controls-whole", { "mode-controls-held": isHeld() }]}>{status()}</span>
            {"  ·  "}
            <span class="mode-controls-whole">{usage()}</span>
            <Show when={props.goal.timeUsedSeconds > 0}>
              {"  ·  "}
              <span class="mode-controls-whole">
                {t.goal.spent({ time: compactDuration(props.goal.timeUsedSeconds * 1000) })}
              </span>
            </Show>
          </span>
        </MenuHeader>
        <For each={goalActions(props.session, props.goal)}>
          {(action) => {
            switch (action) {
              case "resume":
                return (
                  <ComposerMenuItem
                    icon={Symbols.play_arrow_fill}
                    label={t.goal.resume}
                    onClick={() => call("goal.resume")}
                  />
                );
              case "pause":
                return (
                  <ComposerMenuItem icon={Symbols.pause_fill} label={t.goal.pause} onClick={() => call("goal.pause")} />
                );
              case "budget":
                return (
                  <BudgetField
                    budget={props.goal.tokenBudget}
                    onSet={(tokens) => call("goal.budget", { tokenBudget: tokens ?? null })}
                  />
                );
              case "drop":
                return <ComposerMenuItem icon={Symbols.close} label={t.goal.drop} onClick={() => void drop()} />;
            }
          }}
        </For>
      </ComposerMenu>
    </>
  );
}

/**
 * The goal's token budget, typed in the menu: a number, or `off` for none. Enter or the check button sets it; empty
 * leaves it as it is, as the TUI's budget editor does.
 */
function BudgetField(props: { readonly budget: number | undefined; readonly onSet: (tokens: number | undefined) => void }) {
  const [text, setText] = createSignal(untrack(() => props.budget?.toString() ?? ""));
  const [error, setError] = createSignal<string>();

  function submit(value: string) {
    const entry = parseBudget(value);
    if (entry.kind === "empty") return;
    if (entry.kind === "invalid") {
      setError(t.goal.budgetInvalid);
      return;
    }
    props.onSet(entry.tokens);
  }

  return (
    <div class="mode-controls-budget">
      <LabeledField label={t.goal.budget} error={error()}>
        <TextField
          value={text()}
          hint={t.goal.budgetHint}
          enterKeyHint="done"
          onInput={(value) => {
            setText(value);
            setError(undefined);
          }}
          onSubmit={submit}
          suffix={
            <IconButton
              icon={Symbols.check}
              iconSize={18}
              size={32}
              tooltip={t.goal.setBudget}
              onClick={() => submit(text())}
            />
          }
        />
      </LabeledField>
    </div>
  );
}

/** The loop's state as the TUI's footer shows it: iterations left, time left, or the state word. */
function loopLabel(loop: LoopState, nowMs: number): string {
  switch (loopStatePhase(loop)) {
    case "paused":
      return t.loop.paused;
    case "waiting":
      return t.loop.waiting;
    case "running": {
      const limit = loop.limit;
      if (limit === undefined) return t.loop.running;
      return limit.kind === "LoopIterations"
        ? t.loop.iterations({ remaining: limit.remaining, total: limit.total })
        : t.loop.timeLeft({ time: compactDuration(limit.deadline - nowMs) });
    }
  }
}

function loopLimit(loop: LoopState, nowMs: number): string | undefined {
  const limit = loop.limit;
  if (limit === undefined) return undefined;
  return limit.kind === "LoopIterations"
    ? t.loop.iterationsLeft({ remaining: limit.remaining, total: limit.total })
    : t.loop.timeLeftOf({ time: compactDuration(limit.deadline - nowMs), total: compactDuration(limit.durationMs) });
}

function loopCondition(loop: LoopState): string | undefined {
  const condition = loop.condition;
  if (condition === undefined) return undefined;
  return condition.until
    ? t.loop.untilCondition({ command: condition.command })
    : t.loop.whileCondition({ command: condition.command });
}

/**
 * The loop's toolbar control: its state as the TUI's footer shows it (iterations left, time left, or the state word),
 * the condition in the tooltip, and a menu with its settings over suspend and turn off.
 */
export function LoopControl(props: { readonly session: LiveSession; readonly loop: LoopState }) {
  const [open, setOpen] = createSignal(false);
  // The button's ref sets it while the component renders.
  const [button, setButton] = createSignal<HTMLButtonElement | undefined>(undefined, { ownedWrite: true });
  const [now, setNow] = createSignal(Date.now());
  const timed = createMemo(() => props.loop.limit?.kind === "LoopDuration");
  // Ticks once a second while the loop has a time limit, so the time left counts down.
  createEffect(timed, (ticking) => {
    if (!ticking) return;
    setNow(Date.now());
    const clock = setInterval(() => setNow(Date.now()), 1000);
    return () => clearInterval(clock);
  });

  const paused = () => loopStatePhase(props.loop) === "paused";
  const label = () => loopLabel(props.loop, now());
  const limit = () => loopLimit(props.loop, now());

  function call(verb: string) {
    setOpen(false);
    void modeCall(props.session, verb, {}, t.loop.failed);
  }

  return (
    <>
      <ToolbarButton
        icon={paused() ? Symbols.pause_fill : Symbols.repeat}
        color={paused() ? held : undefined}
        label={label()}
        tooltip={[label(), limit(), loopCondition(props.loop)].filter((part) => part !== undefined).join("  ·  ")}
        ref={setButton}
        onClick={() => setOpen((shown) => !shown)}
      />
      <ComposerMenu
        open={open()}
        onClose={() => setOpen(false)}
        button={button()}
        maxWidth={menuWidth}
        fill
        label={label()}
      >
        <MenuHeader
          text={props.loop.prompt ?? (paused() ? t.loop.pausedPrompt : t.loop.waitingPrompt)}
          quiet={props.loop.prompt === undefined}
        >
          <Show when={limit()}>{(text) => <span class="mode-controls-fact">{text()}</span>}</Show>
          <Show when={props.loop.condition}>
            {(condition) => (
              <>
                <span class="mode-controls-fact">{condition().until ? t.loop.untilLabel : t.loop.whileLabel}</span>
                <span class="mode-controls-fact mode-controls-command">{condition().command}</span>
              </>
            )}
          </Show>
          <Show when={props.loop.iterations > 0}>
            <span class="mode-controls-fact">{t.loop.done({ n: props.loop.iterations })}</span>
          </Show>
        </MenuHeader>
        <For each={loopActions(props.session, props.loop)}>
          {(action) =>
            action === "suspend" ? (
              <ComposerMenuItem icon={Symbols.pause_fill} label={t.loop.suspend} onClick={() => call("loop.suspend")} />
            ) : (
              <ComposerMenuItem icon={Symbols.stop_fill} label={t.loop.disable} onClick={() => call("loop.disable")} />
            )
          }
        </For>
      </ComposerMenu>
    </>
  );
}

/** The top of a goal or loop menu: the objective or the loop's prompt, then its facts. Long texts scroll. */
function MenuHeader(props: {
  readonly text: string;
  /** `text` says what the loop waits for rather than quoting a prompt. */
  readonly quiet?: boolean;
  readonly children: JSX.Element;
}) {
  return (
    <div class="mode-controls-header">
      <div class={["mode-controls-text", { "mode-controls-quiet": props.quiet }]}>{props.text}</div>
      {props.children}
    </div>
  );
}
