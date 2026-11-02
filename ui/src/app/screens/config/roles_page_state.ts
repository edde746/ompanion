// The state of lib/screens/config/roles_page.dart's _RolesPageState, apart from its markup (roles_page.tsx), so its
// contracts run in a test without a page.
import { createSignal } from "solid-js";
import { asJsonObject } from "../../../core/rpc/json_fields";
import type { RpcModel } from "../../../core/rpc/results";
import type { LiveSession } from "../../../core/session/live_session";
import type { Subscription } from "../../../core/util/stream";
import { type ModelRole, type RolesState, rolesStateFromJson } from "../../config/accounts";
import type { ConfigTarget } from "../../config/config_target";

/**
 * omp's model roles: the effective model per role with its layer, and the global and project assignments. Global
 * writes go through the control process; project writes through the active session, whose working directory is the
 * project (`roles.set` writes `<cwd>/.omp/config.yml`).
 */
export class RolesPageState {
  private readonly rolesSignal = createSignal<RolesState | undefined>(undefined);
  private readonly errorSignal = createSignal<unknown>(undefined);
  private readonly loadingSignal = createSignal(true);
  private readonly busySignal = createSignal<ReadonlySet<string>>(new Set());
  private events: Subscription | undefined;
  private disposed = false;

  constructor(private readonly target: ConfigTarget) {}

  readonly roles = this.rolesSignal[0];
  readonly error = this.errorSignal[0];
  readonly loading = this.loadingSignal[0];
  readonly busy = this.busySignal[0];

  /**
   * The session whose view of the roles the page shows: the project's when there is one, since it also holds the
   * project layer.
   */
  private async source(): Promise<LiveSession> {
    return this.target.projectSession() ?? (await this.target.control());
  }

  async load(): Promise<void> {
    // Also called after awaited work, when the page may be gone.
    if (this.disposed) return;
    this.loadingSignal[1](true);
    this.errorSignal[1](undefined);
    try {
      const source = await this.source();
      if (this.disposed) return;
      this.events?.cancel();
      this.events = source.companion.events.listen((event) => {
        if (event.event !== "roles.changed") return;
        this.rolesSignal[1](rolesStateFromJson(asJsonObject(event.data, "roles.changed")));
      });
      const roles = rolesStateFromJson(asJsonObject(await source.companion.call("roles.get"), "roles.get"));
      if (!this.disposed) this.rolesSignal[1](roles);
    } catch (error) {
      if (!this.disposed) this.errorSignal[1](error);
    } finally {
      if (!this.disposed) this.loadingSignal[1](false);
    }
  }

  async models(options: { refresh?: boolean } = {}): Promise<RpcModel[]> {
    const control = await this.target.control();
    return this.target.sessions.models(this.target.machine, control.rpc, options);
  }

  /** Assigns [model] (undefined: auto) to [role]; a failure reaches the caller, which reports it. */
  async set(role: ModelRole, model: string | undefined, options: { project: boolean }): Promise<void> {
    this.busySignal[1]((busy) => new Set([...busy, role.role]));
    try {
      const project = this.target.projectSession();
      if (options.project && project === undefined) throw new Error("no project session");
      const session = options.project && project !== undefined ? project : await this.target.control();
      const result = await session.companion.call("roles.set", {
        role: role.role,
        model: model ?? null,
        scope: options.project ? "project" : "global",
      });
      const roles = rolesStateFromJson(asJsonObject(result, "roles.set"));
      // The reply of the control process lacks the project layer; the page's own source reports it.
      const source = await this.source();
      const shown =
        source === session
          ? roles
          : rolesStateFromJson(asJsonObject(await source.companion.call("roles.get"), "roles.get"));
      if (!this.disposed) this.rolesSignal[1](shown);
    } finally {
      if (!this.disposed) this.busySignal[1]((busy) => new Set([...busy].filter((name) => name !== role.role)));
    }
  }

  dispose(): void {
    this.disposed = true;
    this.events?.cancel();
  }
}
