// Port of packages/omp_core/test/store/fixtures.dart: the recorded omp sessions in harness/fixtures.
import * as fs from "node:fs";
import * as path from "node:path";
import { RpcFrameDecoder } from "../core/rpc/frame_decoder";
import { asJsonObject, type JsonObject } from "../core/rpc/json_fields";
import { splitLines } from "../core/util/text";

/** Sessions recorded from omp 18.3.1 (`harness/README.md`). */
export const fixtureDir = path.resolve(import.meta.dir, "../../../harness/fixtures");

/** Scenario names, from the `<name>.out.jsonl` files. */
export function fixtureNames(): string[] {
  return fs
    .readdirSync(fixtureDir)
    .filter((name) => name.endsWith(".out.jsonl"))
    .map((name) => name.slice(0, -".out.jsonl".length))
    .sort();
}

/** The lines of `<name>.out.jsonl` (omp's stdout from byte 0) or `<name>.in.jsonl` (the lines sent). */
export function fixtureLines(name: string, direction: "out" | "in"): string[] {
  return splitLines(fs.readFileSync(path.join(fixtureDir, `${name}.${direction}.jsonl`), "utf8"));
}

/** The frames omp wrote in scenario [name], decoded like the RPC client does: `rpc_chunk` sequences reassembled. */
export function outFrames(name: string): JsonObject[] {
  const decoder = new RpcFrameDecoder();
  const frames: JsonObject[] = [];
  for (const line of fixtureLines(name, "out")) {
    const frame = decoder.push(line);
    if (frame !== undefined) frames.push(frame);
  }
  return frames;
}

/** The `extension_ui_response` lines sent in scenario [name], by the id of the request they answer. */
export function uiAnswers(name: string): Map<string, JsonObject> {
  const answers = new Map<string, JsonObject>();
  for (const line of fixtureLines(name, "in")) {
    const answer = asJsonObject(JSON.parse(line), `${name}.in.jsonl line`);
    if (answer.type === "extension_ui_response" && typeof answer.id === "string") answers.set(answer.id, answer);
  }
  return answers;
}
