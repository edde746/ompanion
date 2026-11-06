// lib/screens/machines/machine_detail_pane.dart: the center pane of the selected machine (the shell passes the machine;
// one that is gone shows the home pane there).
import { createSignal, For, Match, onSettled, Show, Switch, untrack } from "solid-js";
import { updateOmp } from "../../../core/host/install";
import { keepAwake, setKeepAwake } from "../../../core/host/keep_awake";
import { type HostProbe, hostProbeIsWindows } from "../../../core/host/probe";
import type { MachineRuntime, MachineStatus } from "../../../core/session/machine_runtime";
import { useConnector, useKeys, useKnownHosts, useMachines, useSessions, useShell } from "../../app_state";
import { t } from "../../i18n/i18n";
import { type Machine, type SshEndpoint, sshEndpointLabel, sshMachineHops } from "../../models/machine";
import { homeSelection } from "../../providers/shell_provider";
import { testConnection } from "../../services/machine_connector";
import { appLogger } from "../../utils/app_logger";
import { shortPath } from "../../utils/home_path";
import { ActivityMark } from "../../widgets/activity_mark";
import { FilledButton, IconButton, TextButton, TonalButton } from "../../widgets/button";
import { Icon } from "../../widgets/icon";
import * as Symbols from "../../widgets/symbols";
import { confirmAction, errorText, runReporting } from "../config/config_widgets";
import { machineStatus, machineStatusText } from "../sessions/machine_status";
import { SettingsCard, SettingsSwitchRow } from "../settings/settings_card";
import { describeConnectError, runOnMachine } from "./connect_dialogs";
import "./machine_detail_pane.css";
import { authLabel, showMachineEditor } from "./machine_editor";

/** A connection test or an omp update: running, or how it ended. Undefined before the first. */
interface RunState {
  readonly kind: "Running" | "Succeeded" | "Failed";
  readonly message: string;
}

/** `Linux (glibc)`, `macOS`, `Windows`; the kernel name for anything else. */
export function osLabel(probe: HostProbe): string {
  const name = { macos: "macOS", linux: "Linux", windows: "Windows", other: probe.kernel }[probe.os];
  return probe.libc === undefined ? name : `${name} (${probe.libc})`;
}

/**
 * One machine: what its probe found, how it is reached, a connection test, the omp update, and the host keys trusted
 * for its hops.
 */
export function MachineDetailPane(props: { readonly machine: Machine }) {
  const sessions = useSessions();
  const machines = useMachines();
  const shell = useShell();
  const connector = useConnector();
  const runtime = () => sessions.runtimeFor(props.machine);
  const status = machineStatus(runtime);
  const [test, setTest] = createSignal<RunState>();
  const [update, setUpdate] = createSignal<RunState>();
  const probe = () => {
    const current = status();
    return current.kind === "MachineOnline" || current.kind === "MachineNeedsOmp" ? current.probe : undefined;
  };

  async function runTest() {
    const machine = props.machine;
    setTest({ kind: "Running", message: t.machines.connecting });
    try {
      const elapsedMs = await runOnMachine(connector, machine, testConnection);
      setTest({ kind: "Succeeded", message: t.machines.connectedIn({ ms: Math.floor(elapsedMs) }) });
    } catch (error) {
      appLogger.w(`test connection to ${machine.name} failed`, { error });
      setTest({ kind: "Failed", message: t.machines.failed({ error: describeConnectError(error) }) });
    }
  }

  /**
   * Runs `omp update` on the machine and probes again, so new sessions, the control process and the model cache use
   * the new omp. The probe follows a failed update too and the version decides, because on Windows omp 18.3.3 to
   * 18.3.5 exit 1 after a successful update. omp's own words explain a run that changed nothing (up to date, or a Nix
   * install); a failed run that changed nothing shows its failure, and a failed probe shows its own.
   */
  async function runUpdate(before: HostProbe) {
    const machine = props.machine;
    const current = runtime();
    setUpdate({ kind: "Running", message: t.machines.updatingOmp });
    let said = "";
    let failure: { readonly error: unknown } | undefined;
    try {
      said = await updateOmp(current.link, before);
    } catch (error) {
      appLogger.w(`updating omp on ${machine.name} failed`, { error });
      failure = { error };
    }
    try {
      const updated = await current.reprobe();
      const from = before.ompVersion ?? "?";
      const to = updated.ompVersion ?? "?";
      const now = current.status;
      if (now.kind !== "MachineOnline") setUpdate({ kind: "Failed", message: machineStatusText(now) });
      else if (to !== from) setUpdate({ kind: "Succeeded", message: t.machines.ompUpdated({ from, to }) });
      else if (failure === undefined) setUpdate({ kind: "Succeeded", message: said.trim() });
      else setUpdate({ kind: "Failed", message: t.machines.failed({ error: describeConnectError(failure.error) }) });
    } catch (error) {
      appLogger.w(`probing ${machine.name} after omp update failed`, { error });
      setUpdate({ kind: "Failed", message: t.machines.failed({ error: describeConnectError(error) }) });
    }
  }

  async function remove() {
    const machine = props.machine;
    const confirmed = await confirmAction({
      title: t.machines.deleteTitle({ name: machine.name }),
      body: t.machines.deleteBody,
      action: t.common.delete,
    });
    if (!confirmed) return;
    shell.select(homeSelection);
    await machines.delete(machine);
  }

  const ssh = () => (props.machine.kind === "SshMachine" ? props.machine : undefined);

  return (
    <div class="machine-detail-pane">
      <div class="machine-detail-pane-header">
        <Icon
          icon={ssh() === undefined ? Symbols.computer : ssh()?.tailscale ? Symbols.lan : Symbols.dns}
          size={32}
        />
        <h1 class="machine-detail-pane-name">{props.machine.name}</h1>
      </div>
      <div class="machine-detail-pane-tags">
        <Show when={props.machine.kind === "LocalMachine"}>
          <span class="machine-detail-pane-tag">{t.machines.thisComputer}</span>
        </Show>
        <Show when={ssh()?.tailscale}>
          <span class="machine-detail-pane-tag">{t.machines.tailscale}</span>
        </Show>
        <Show when={ssh()?.sshConfigAlias}>
          {(alias) => <span class="machine-detail-pane-tag">{t.machines.sshConfigAlias({ alias: alias() })}</span>}
        </Show>
      </div>
      <div class="machine-detail-pane-actions">
        <FilledButton icon={Symbols.power} disabled={test()?.kind === "Running"} onClick={() => void runTest()}>
          {t.machines.testConnection}
        </FilledButton>
        <Show when={status().kind === "MachineOnline" ? probe() : undefined}>
          {(online) => (
            <TonalButton
              icon={Symbols.upgrade}
              disabled={update()?.kind === "Running"}
              onClick={() => void runUpdate(online())}
            >
              {t.machines.updateOmp}
            </TonalButton>
          )}
        </Show>
        <TonalButton icon={Symbols.edit} onClick={() => void showMachineEditor({ machine: props.machine })}>
          {t.common.edit}
        </TonalButton>
        <TextButton icon={Symbols.delete} onClick={() => void remove()}>
          {t.common.delete}
        </TextButton>
      </div>
      <RunStatus state={test()} />
      <RunStatus state={update()} />
      <h2 class="machine-detail-pane-section">{t.machines.facts}</h2>
      <Facts status={status()} probe={probe()} onConnect={() => void sessions.refresh(props.machine)} />
      <Show when={probe()?.os === "macos" && status().kind === "MachineOnline"}>
        <KeepAwake runtime={runtime()} />
      </Show>
      <Show when={ssh()}>
        {(machine) => (
          <>
            <h2 class="machine-detail-pane-section">{t.machines.route}</h2>
            <div class="machine-detail-pane-group">
              <For each={machine().jumps}>
                {(jump, index) => <HopTile label={t.editor.jumpHostN({ n: index() + 1 })} hop={jump} />}
              </For>
              <HopTile label={t.machines.target} hop={machine().target} />
            </div>
            <h2 class="machine-detail-pane-section">{t.machines.hostKeys}</h2>
            <HostKeys hops={sshMachineHops(machine())} />
          </>
        )}
      </Show>
    </div>
  );
}

/** One fact: a label column and a selectable value. */
function Fact(props: {
  readonly label: string;
  readonly value: string;
  readonly color?: string;
  /** A path or command: the code font, as design.md sets for paths. */
  readonly mono?: boolean;
}) {
  return (
    <div class="machine-detail-pane-fact">
      <span class="machine-detail-pane-fact-label">{props.label}</span>
      <span
        class={["machine-detail-pane-fact-value", { "machine-detail-pane-fact-mono": props.mono }]}
        style={{ color: props.color }}
      >
        {props.value}
      </span>
    </div>
  );
}

/**
 * What the last probe found: OS, architecture, shell, home, omp and the companion. Before the first connection only
 * the status.
 */
function Facts(props: {
  readonly status: MachineStatus;
  readonly probe: HostProbe | undefined;
  readonly onConnect: () => void;
}) {
  const statusColor = () =>
    props.status.kind === "MachineFailed"
      ? "var(--error)"
      : props.status.kind === "MachineNeedsOmp"
        ? "var(--warning)"
        : undefined;
  return (
    <div class="machine-detail-pane-group">
      <Show when={props.status.kind !== "MachineOnline"}>
        <Fact label={t.machines.status} value={machineStatusText(props.status)} color={statusColor()} />
      </Show>
      <Show
        when={props.probe}
        fallback={
          <div class="machine-detail-pane-unprobed">
            <span class="machine-detail-pane-muted">{t.machines.notProbed}</span>
            <Show when={props.status.kind !== "MachineConnecting"}>
              <TonalButton onClick={() => props.onConnect()}>{t.sessions.connect}</TonalButton>
            </Show>
          </div>
        }
      >
        {(probe) => (
          <>
            <Fact label={t.machines.os} value={osLabel(probe())} />
            <Fact label={t.machines.arch} value={probe().arch} />
            <Fact
              label={t.machines.shell}
              value={probe().shell ?? (hostProbeIsWindows(probe()) ? "cmd.exe" : "—")}
              mono={probe().shell !== undefined}
            />
            {/* omp runs with the machine's own PATH when the login shell gave none, so tools the user's shell has may
                be missing from its bash tool. Say why. */}
            <Show when={probe().loginProblem}>
              {(problem) => <Fact label={t.machines.loginPath} value={problem()} color="var(--warning)" />}
            </Show>
            <Fact label={t.machines.home} value={probe().home} mono />
            {/* Under the home, as `~/…` like every other path the app shows; the line above says where `~` is. */}
            <Show when={probe().ompPath} fallback={<Fact label={t.machines.omp} value={t.machines.notFound} />}>
              {(path) => <Fact label={t.machines.omp} value={shortPath(path(), probe().home)} mono />}
            </Show>
            <Fact label={t.machines.ompVersion} value={probe().ompVersion ?? "—"} />
            <Fact
              label={t.machines.companion}
              value={props.status.kind === "MachineOnline" ? t.machines.companionReady : t.machines.companionMissing}
            />
          </>
        )}
      </Show>
    </div>
  );
}

/** The machine's keep-awake switch (`~/.ompanion/keep-awake`), read from the machine when shown. */
function KeepAwake(props: { readonly runtime: MachineRuntime }) {
  /** The file's state; undefined until read. */
  const [on, setOn] = createSignal<boolean>();
  /** Why the read failed: the switch still sets the file, which ends the doubt. */
  const [readFailure, setReadFailure] = createSignal<string>();
  const [busy, setBusy] = createSignal(false);
  const link = () => untrack(() => props.runtime).link;
  const detail = () => {
    const failure = readFailure();
    return failure === undefined ? t.machines.keepAwakeDetail : t.machines.keepAwakeUnread({ error: failure });
  };

  onSettled(
    () =>
      void keepAwake(link()).then(
        (value) => setOn(value),
        (error: unknown) => {
          appLogger.w("reading keep-awake failed", { error });
          setReadFailure(errorText(error));
        },
      ),
  );

  async function set(value: boolean) {
    setBusy(true);
    await runReporting(async () => {
      await setKeepAwake(link(), value);
      setOn(value);
      setReadFailure(undefined);
    });
    setBusy(false);
  }

  return (
    <>
      <h2 class="machine-detail-pane-section">{t.machines.power}</h2>
      <SettingsCard>
        <SettingsSwitchRow
          label={t.machines.keepAwake}
          detail={detail()}
          value={on() ?? false}
          onChanged={
            (on() === undefined && readFailure() === undefined) || busy() ? undefined : (value) => void set(value)
          }
        />
      </SettingsCard>
    </>
  );
}

function RunStatus(props: { readonly state: RunState | undefined }) {
  return (
    <Show when={props.state}>
      {(state) => (
        <div class={["machine-detail-pane-run", { "machine-detail-pane-run-failed": state().kind === "Failed" }]}>
          <Switch>
            <Match when={state().kind === "Running"}>
              <span class="machine-detail-pane-run-mark">
                <ActivityMark size={16} />
              </span>
            </Match>
            <Match when={state().kind === "Succeeded"}>
              <span class="machine-detail-pane-run-mark machine-detail-pane-run-succeeded">
                <Icon icon={Symbols.check_circle_fill} size={20} />
              </span>
            </Match>
            <Match when={state().kind === "Failed"}>
              <span class="machine-detail-pane-run-mark">
                <Icon icon={Symbols.error_fill} size={20} />
              </span>
            </Match>
          </Switch>
          <span class="machine-detail-pane-run-text">{state().message}</span>
        </div>
      )}
    </Show>
  );
}

function HopTile(props: { readonly label: string; readonly hop: SshEndpoint }) {
  const keys = useKeys();
  const auth = () =>
    props.hop.auth === "key"
      ? `${t.auth.key}: ${keys.byId(props.hop.keyId)?.name ?? t.machines.noKeySelected}`
      : authLabel(props.hop.auth);
  return (
    <div class="machine-detail-pane-hop">
      <Icon icon={Symbols.subdirectory_arrow_right} size={18} class="machine-detail-pane-muted" />
      <span class="machine-detail-pane-hop-text">
        <span>{sshEndpointLabel(props.hop)}</span>
        <span class="machine-detail-pane-small">{`${props.label} · ${auth()}`}</span>
      </span>
    </div>
  );
}

function HostKeys(props: { readonly hops: readonly SshEndpoint[] }) {
  const knownHosts = useKnownHosts();
  const rows = () => knownHosts.watchFor(props.hops);
  return (
    <Show when={rows().length > 0} fallback={<p class="machine-detail-pane-muted">{t.machines.noHostKeys}</p>}>
      <div class="machine-detail-pane-group">
        <For each={rows()}>
          {(row) => (
            <div class="machine-detail-pane-key">
              <Icon icon={Symbols.verified_user} size={18} class="machine-detail-pane-muted" />
              <span class="machine-detail-pane-hop-text">
                <span>
                  {row.port === 22 ? `${row.host} · ${row.keyType}` : `${row.host}:${row.port} · ${row.keyType}`}
                </span>
                <span class="machine-detail-pane-fingerprint">{row.fingerprint}</span>
              </span>
              <IconButton
                icon={Symbols.delete}
                iconSize={20}
                tooltip={t.machines.forgetHostKey}
                onClick={() => void knownHosts.forget(row)}
              />
            </div>
          )}
        </For>
      </div>
    </Show>
  );
}
