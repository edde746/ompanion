// Port of test/screens/config/roles_page_test.dart: the page's contract, on its state without the markup.
import { afterEach, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { createRoot, flush } from "solid-js";
import type { LiveSession } from "../../../core/session/live_session";
import { deferred } from "../../../deferred";
import { FakeSession, FakeSessions, testMachine } from "../../../test/config_fakes";
import { ConfigTarget } from "../../config/config_target";
import { RolesPageState } from "./roles_page_state";

const roles: unknown = JSON.parse(readFileSync(join(import.meta.dir, "../../config/fixtures/roles-get.json"), "utf8"));

let dispose: (() => void) | undefined;

afterEach(() => dispose?.());

function pageState(sessions: FakeSessions): RolesPageState {
  return createRoot((done) => {
    dispose = done;
    return new RolesPageState(new ConfigTarget(testMachine, sessions));
  });
}

test("closing the page before the control process answers leaves no listener behind", async () => {
  const control = await new FakeSession({
    reply: (verb) => {
      if (verb === "roles.get") return roles;
      throw new Error(`unexpected ${verb}`);
    },
  }).attach();
  const started = deferred<LiveSession>();
  const sessions = new FakeSessions();
  sessions.onControl = () => started.promise;
  const state = pageState(sessions);
  const loading = state.load();
  state.dispose();

  started.resolve(control);
  await loading;
  // Companion events reach listeners synchronously as omp writes them.
  control.omp.emit({ kind: "event", event: "roles.changed", data: roles });
  flush();
  expect(state.roles()).toBeUndefined();
});

test("roles.changed of the page's source replaces the roles", async () => {
  const control = await new FakeSession({
    reply: (verb) => (verb === "roles.get" ? { storage: "global", roles: [] } : undefined),
  }).attach();
  const sessions = new FakeSessions();
  sessions.onControl = async () => control;
  const state = pageState(sessions);
  await state.load();
  flush();
  expect(state.roles()?.roles).toEqual([]);
  control.omp.emit({ kind: "event", event: "roles.changed", data: roles });
  flush();
  expect(state.roles()?.roles.length).toBeGreaterThan(0);
  state.dispose();
});
