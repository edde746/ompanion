// The dev bridge transport (src/bridge.ts) against the real core.
import { expect, test } from "bun:test";
import { call } from "./bridge";
import { measureFlood } from "./bridge_measure";
import { useCore } from "./test/core";

useCore();

test("a test that waits on the core between messages loses none of them", async () => {
  // Each await below resumes from a message while the flood's frames arrive, and bun:test's expect(...).resolves then
  // runs the event loop until its echo comes back. Done inside Bun's read of the socket, that lost, repeated and
  // garbled the frames the read had brought after the message (file_workspace.e2e.test.ts on Linux).
  const flood = measureFlood(64 * 4000, 64);
  let flooding = true;
  const stop = () => {
    flooding = false;
  };
  flood.then(stop, stop);
  let waits = 0;
  for (let n = 0; flooding; n++) {
    await call("core.echo", { n });
    await expect(call("core.echo", { n })).resolves.toEqual({ n });
    waits++;
  }
  expect((await flood).chunks).toBe(4000);
  expect(waits).toBeGreaterThan(0);
});
