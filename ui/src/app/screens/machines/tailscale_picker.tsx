// lib/screens/machines/tailscale_picker.dart.
import { createMemo, createSignal, Errored, For, Loading, Show } from "solid-js";
import { call } from "../../../bridge";
import { asJsonObject } from "../../../core/rpc/json_fields";
import { t } from "../../i18n/i18n";
import type { MachineDraft } from "../../models/machine_draft";
import {
  draftFromTailscalePeer,
  type TailscalePeer,
  tailscalePeerDialHost,
  tailscaleStatusRunning,
} from "../../models/tailscale_status";
import { readTailscaleStatus } from "../../services/tailscale_cli";
import { ActivityMark } from "../../widgets/activity_mark";
import { AppSearchField } from "../../widgets/app_search_field";
import { TextButton } from "../../widgets/button";
import { Dialog, showDialog } from "../../widgets/dialog";
import { Icon } from "../../widgets/icon";
import * as Symbols from "../../widgets/symbols";
import { errorText } from "../config/config_widgets";
import "./tailscale_picker.css";

/** Lists the tailnet's devices from the desktop's Tailscale client; resolves with a draft for the chosen one. */
export function showTailscalePicker(): Promise<MachineDraft | undefined> {
  return showDialog<MachineDraft>((close) => <TailscalePicker close={close} />);
}

/** The user this computer's core runs as, whom a Tailscale SSH machine logs in as by default. */
async function localUser(): Promise<string> {
  const { env } = asJsonObject(await call<unknown>("core.env", { names: ["USER", "USERNAME"] }), "core.env");
  const vars = asJsonObject(env, "core.env env");
  const user = vars.USER ?? vars.USERNAME;
  return typeof user === "string" ? user : "";
}

function TailscalePicker(props: { readonly close: (draft?: MachineDraft) => void }) {
  const lookup = createMemo(() => readTailscaleStatus());
  const [query, setQuery] = createSignal("");
  const [error, setError] = createSignal<string>();
  /** What the dialog says instead of the device list, if anything. */
  const notice = (): string | undefined => {
    const found = lookup();
    switch (found.kind) {
      case "TailscaleNotInstalled":
        return t.tailscale.notInstalled;
      case "TailscaleFailed":
        return t.tailscale.failed({ message: found.message });
      case "TailscaleFound":
        if (!tailscaleStatusRunning(found.status)) return t.tailscale.notRunning({ state: found.status.backendState });
        return found.status.peers.length === 0 ? t.tailscale.noPeers : undefined;
    }
  };
  const peers = () => {
    const found = lookup();
    return (found.kind === "TailscaleFound" ? found.status.peers : []).filter(
      (peer) =>
        query() === "" || `${peer.hostName} ${tailscalePeerDialHost(peer)} ${peer.os}`.toLowerCase().includes(query()),
    );
  };

  async function pick(peer: TailscalePeer) {
    try {
      props.close(draftFromTailscalePeer(peer, { user: await localUser(), now: Date.now() }));
    } catch (failure) {
      setError(errorText(failure));
    }
  }

  return (
    <Dialog
      class="tailscale-picker"
      title={t.tailscale.title}
      actions={<TextButton onClick={() => props.close()}>{t.common.close}</TextButton>}
    >
      <Errored fallback={(failure) => <p>{t.tailscale.failed({ message: errorText(failure()) })}</p>}>
        <Loading
          fallback={
            <div class="tailscale-picker-loading">
              <ActivityMark size={20} />
            </div>
          }
        >
          <Show
            when={notice()}
            fallback={
              <>
                <div class="tailscale-picker-search">
                  <AppSearchField
                    hint={t.tailscale.search}
                    autofocus
                    onChanged={(text) => setQuery(text.trim().toLowerCase())}
                  />
                </div>
                <Show when={error()}>{(text) => <p class="tailscale-picker-error">{text()}</p>}</Show>
                <For each={peers()}>{(peer) => <PeerTile peer={peer} onClick={() => void pick(peer)} />}</For>
              </>
            }
          >
            {(text) => <p>{text()}</p>}
          </Show>
        </Loading>
      </Errored>
    </Dialog>
  );
}

function PeerTile(props: { readonly peer: TailscalePeer; readonly onClick: () => void }) {
  const dialHost = () => tailscalePeerDialHost(props.peer);
  const details = () => {
    const { os, online } = props.peer;
    return [dialHost(), ...(os === "" ? [] : [os]), ...(online ? [] : [t.tailscale.offline])].join(" · ");
  };
  return (
    <button type="button" data-ripple class="tailscale-picker-peer" onClick={() => props.onClick()}>
      <span class={["tailscale-picker-dot", { "tailscale-picker-online": props.peer.online }]}>
        <Icon icon={Symbols.circle_fill} size={10} />
      </span>
      <span class="tailscale-picker-text">
        <span class="tailscale-picker-name">{props.peer.hostName === "" ? dialHost() : props.peer.hostName}</span>
        <span class="tailscale-picker-details">{details()}</span>
      </span>
    </button>
  );
}
