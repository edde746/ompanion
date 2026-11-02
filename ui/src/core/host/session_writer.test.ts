import { describe, expect, test } from "bun:test";
import type { JsonObject } from "../rpc/json_fields";
import { turnInFlight } from "../store/external_writer";
import { parseSessionWriter } from "./session_writer";

// The rule that says whether the other process is in a turn; session_writer.e2e.test.ts probes this computer.
describe("turnInFlight", () => {
  const message = (role: string, stopReason?: string): JsonObject => ({
    type: "message",
    message: stopReason === undefined ? { role } : { role, stopReason },
  });
  const compaction: JsonObject = { type: "compaction", summary: "earlier turns" };

  test("a turn is open from the prompt until an assistant message ends it", () => {
    // The model has not answered yet.
    expect(turnInFlight([message("user")])).toBe(true);
    expect(turnInFlight([message("user"), message("assistant", "toolUse")])).toBe(true);
    // The next assistant message is streaming; omp appends it when it ends.
    expect(turnInFlight([message("user"), message("assistant", "toolUse"), message("toolResult")])).toBe(true);
    for (const reason of ["stop", "length", "error", "aborted"]) {
      expect(turnInFlight([message("user"), message("assistant", reason)])).toBe(false);
    }
  });

  test("entries that are not messages leave the answer to the last message", () => {
    expect(turnInFlight([message("user"), message("assistant", "stop"), compaction])).toBe(false);
    expect(turnInFlight([message("user"), compaction])).toBe(true);
    expect(turnInFlight([compaction])).toBe(false);
    expect(turnInFlight([message("assistant", "stop"), message("bashExecution")])).toBe(false);
  });
});

describe("parseSessionWriter", () => {
  test("reads holders and a terminal", () => {
    const writer = parseSessionWriter("holder 41\nholder 42\nterminal ttys004 41\n");
    expect(writer?.pids).toEqual([41, 42]);
    expect(writer?.terminal).toBe("ttys004");
  });

  test("no holder and no terminal is no writer", () => {
    expect(parseSessionWriter("")).toBeUndefined();
    // An unparsable pid is not a holder.
    expect(parseSessionWriter("holder x\nterminal ttys004\n")).toBeUndefined();
  });

  test("the app's own run is not a holder", () => {
    expect(parseSessionWriter("holder 41\nholder 42\n", { runPid: 41 })?.pids).toEqual([42]);
    expect(parseSessionWriter("holder 41\n", { runPid: 41 })).toBeUndefined();
  });
});
