// lib/models/machine_draft.dart: prefill for the machine editor, from `~/.ssh/config` or Tailscale discovery.
import type { AuthMethod, KnownHostRow } from "../database/tables";

export interface EndpointDraft {
  readonly host: string;
  readonly port: number;
  readonly user: string;
  readonly auth: AuthMethod;
  readonly keyId?: string;
}

export interface MachineDraft {
  readonly name: string;
  readonly target: EndpointDraft;
  readonly jumps: readonly EndpointDraft[];
  readonly sshConfigAlias?: string;
  readonly tailscale: boolean;
  /** Host keys to trust when the machine is saved (Tailscale's control-plane keys). */
  readonly hostKeys: readonly KnownHostRow[];
  /** A `ProxyCommand` from `~/.ssh/config`; the app dials directly or through jumps instead. */
  readonly ignoredProxyCommand?: string;
}
