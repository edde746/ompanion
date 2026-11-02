// lib/screens/sessions/install_omp_dialog.dart.
import { createMemo, createSignal, Show } from "solid-js";
import { call } from "../../../bridge";
import {
  defaultInstallDir,
  fetchOmpAsset,
  installRoute,
  ompReleases,
  posixInstallCommand,
  uploadOmp,
  windowsInstallCommand,
} from "../../../core/host/install";
import { type HostProbe, hostProbeIsWindows, hostProbeReleaseAsset } from "../../../core/host/probe";
import { runPosixScript, runPowerShell, scriptResultFailure } from "../../../core/host/scripts";
import { HostLinkException } from "../../../core/transport/host_link";
import type { BridgeLink } from "../../../core/transport/bridge_link";
import { useSessions } from "../../app_state";
import { t } from "../../i18n/i18n";
import type { Machine } from "../../models/machine";
import { ActivityMark } from "../../widgets/activity_mark";
import { FilledButton, IconButton, TextButton } from "../../widgets/button";
import { Dialog, showDialog } from "../../widgets/dialog";
import * as Symbols from "../../widgets/symbols";
import { describeConnectError } from "../machines/connect_dialogs";
import { osLabel } from "../machines/machine_detail_pane";
import { machineStatus, machineStatusText } from "./machine_status";
import "./install_omp_dialog.css";

/**
 * Installs omp on `machine` (docs/PLAN.md D12): a machine with curl or wget, and every Windows machine, downloads the
 * pinned release asset itself; otherwise the core downloads it and uploads it. Either way the machine checks its
 * SHA-256 before installing it. Shows the manual script too.
 */
export function showInstallOmpDialog(machine: Machine): Promise<void> {
  return showDialog<void>((close) => <InstallOmpDialog machine={machine} close={close} />, {
    dismissible: false,
  }).then(() => undefined);
}

type Phase =
  | { readonly kind: "Ready" }
  | { readonly kind: "Running"; readonly message: string }
  | { readonly kind: "Done"; readonly version: string }
  | { readonly kind: "Failed"; readonly message: string };

const newest = ompReleases[ompReleases.length - 1];
if (newest === undefined) throw new RangeError("no omp release is pinned");

/** The newest release the app supports. */
const version = newest.version;

function manualCommand(probe: HostProbe): string {
  return hostProbeIsWindows(probe) ? windowsInstallCommand(probe, version) : posixInstallCommand(probe, version);
}

function InstallOmpDialog(props: { readonly machine: Machine; readonly close: () => void }) {
  const sessions = useSessions();
  const runtime = () => sessions.runtimeFor(props.machine);
  const status = machineStatus(runtime);
  const [phase, setPhase] = createSignal<Phase>({ kind: "Ready" });
  const [showManual, setShowManual] = createSignal(false);

  const probe = createMemo(() => {
    const current = status();
    return current.kind === "MachineNeedsOmp" || current.kind === "MachineOnline" ? current.probe : undefined;
  });
  const running = () => phase().kind === "Running";
  const reason = () => {
    const current = status();
    return current.kind === "MachineNeedsOmp" ? current.reason : undefined;
  };

  /** What the install is doing: nothing yet, a step under way, done, or why it failed. */
  const phaseView = () => {
    const current = phase();
    switch (current.kind) {
      case "Ready":
        return undefined;
      case "Running":
        return (
          <div class="install-omp-running">
            <ActivityMark />
            <span>{current.message}</span>
          </div>
        );
      case "Done":
        return <p class="install-omp-done">{t.install.done({ version: current.version })}</p>;
      case "Failed":
        return <p class="install-omp-failed">{current.message}</p>;
    }
  };

  /** Has the core download the release asset and upload it; the page never holds the binary. */
  const upload = async (link: BridgeLink, target: HostProbe) => {
    const asset = hostProbeReleaseAsset(target);
    if (asset === undefined) throw new HostLinkException(t.install.noAsset({ os: target.os, arch: target.arch }));
    setPhase({ kind: "Running", message: t.install.downloading({ asset }) });
    const cached = await fetchOmpAsset(target, version);
    setPhase({ kind: "Running", message: t.install.installing });
    await uploadOmp(link, target, version, { asset: cached });
  };

  const install = async (target: HostProbe) => {
    const current = runtime();
    try {
      const link = current.link;
      switch (installRoute(target)) {
        case "download": {
          setPhase({ kind: "Running", message: t.install.installing });
          const result = hostProbeIsWindows(target)
            ? await runPowerShell(link, target.commandShell, windowsInstallCommand(target, version))
            : await runPosixScript(link, posixInstallCommand(target, version));
          if (result.exit.code !== 0) throw scriptResultFailure(result, t.install.installFailed);
          break;
        }
        case "upload":
          await upload(link, target);
          break;
      }
      setPhase({ kind: "Running", message: t.install.checking });
      const installed = await current.reprobe();
      const installedVersion = installed.ompVersion;
      const after = current.status;
      if (after.kind !== "MachineOnline" || installedVersion === undefined) {
        const reason = after.kind === "MachineNeedsOmp" ? after.reason : machineStatusText(after);
        throw new HostLinkException(t.install.stillMissing({ reason }));
      }
      void sessions.refresh(props.machine);
      setPhase({ kind: "Done", version: installedVersion });
    } catch (error) {
      setPhase({ kind: "Failed", message: describeConnectError(error) });
    }
  };

  return (
    <Dialog
      class="install-omp-dialog"
      title={t.install.title({ machine: props.machine.name })}
      actions={
        <>
          <TextButton disabled={running()} onClick={() => props.close()}>
            {phase().kind === "Done" ? t.common.close : t.common.cancel}
          </TextButton>
          <Show when={phase().kind !== "Done" && probe()}>
            {(target) => (
              <FilledButton disabled={running()} onClick={() => void install(target())}>
                {phase().kind === "Failed" ? t.common.retry : t.install.install}
              </FilledButton>
            )}
          </Show>
        </>
      }
    >
      <Show when={probe()} fallback={<p class="install-omp-text">{t.install.notConnected}</p>}>
        {(target) => (
          <div class="install-omp-body">
            <p class="install-omp-text">
              {installRoute(target()) === "download" ? t.install.viaDownload : t.install.viaUpload}
            </p>
            <Show when={reason()}>{(text) => <p class="install-omp-reason">{text()}</p>}</Show>
            <div class="install-omp-facts">
              <Fact label={t.install.os} value={osLabel(target())} />
              <Fact label={t.install.arch} value={target().arch} />
              <Fact label={t.install.release} value={`omp ${version}`} />
              <Fact label={t.install.directory} value={defaultInstallDir(target())} />
            </div>
            {phaseView()}
            <div class="install-omp-manual-toggle">
              <TextButton
                icon={showManual() ? Symbols.expand_more : Symbols.chevron_right}
                onClick={() => setShowManual((shown) => !shown)}
              >
                {t.install.manual}
              </TextButton>
            </div>
            <Show when={showManual()}>
              <div class="install-omp-manual">
                <pre class="install-omp-script">{manualCommand(target())}</pre>
                <IconButton
                  icon={Symbols.content_copy}
                  iconSize={18}
                  tooltip={t.common.copy}
                  onClick={() => void call("shell.clipboardWrite", { text: manualCommand(target()) })}
                />
              </div>
            </Show>
          </div>
        )}
      </Show>
    </Dialog>
  );
}

function Fact(props: { readonly label: string; readonly value: string }) {
  return (
    <div class="install-omp-fact">
      <span class="install-omp-fact-label">{props.label}</span>
      <span class="install-omp-fact-value">{props.value}</span>
    </div>
  );
}
