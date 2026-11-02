// lib/screens/shell/connect_prompt_host.dart.
import type { JSX } from "@solidjs/web";
import { createEffect } from "solid-js";
import { useSessions } from "../../app_state";
import { appActive } from "../../platform";
import { promptDialogs } from "../machines/connect_dialogs";
import { ConnectPromptPump } from "./connect_prompt_pump";

/**
 * Shows the connection prompts machine runtimes queue (passwords, keyboard-interactive, passphrases, host keys), one at
 * a time and only while the app is in the foreground: a background reconnect waits for the user instead of failing on
 * a prompt nobody sees.
 */
export function ConnectPromptHost(props: { readonly children: JSX.Element }) {
  const queue = useSessions().prompts;
  const pump = new ConnectPromptPump(queue, promptDialogs, appActive);
  createEffect(
    () => [queue.next(), appActive()],
    () => pump.pump(),
  );
  return <>{props.children}</>;
}
