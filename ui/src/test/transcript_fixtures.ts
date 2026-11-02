// Port of test/transcript/fixtures.dart: the recorded omp sessions of harness/fixtures, replayed into views.
import { asJsonObject, type JsonObject } from "../core/rpc/json_fields";
import {
  reduce,
  withCompanionSnapshot,
  withEntries,
  withMessages,
  withState,
  withSubagents,
} from "../core/store/reducer";
import { sessionView, type SessionView } from "../core/store/session_view";
import { outFrames, uiAnswers } from "./fixtures";

function objects(value: unknown): JsonObject[] {
  if (!Array.isArray(value)) throw new Error("expected an array");
  return value.map((item) => asJsonObject(item, "element"));
}

/**
 * Every view a session store builds while replaying scenario `name`: frames through `reduce`, state and history
 * responses through the seeding functions, and each dialog answered by the line the recorder sent. `reference` is omp's
 * own final transcript (`get_messages`), as a view.
 */
export function replayFixture(name: string): { views: SessionView[]; reference?: SessionView } {
  const answers = uiAnswers(name);
  let view = sessionView();
  let reference: SessionView | undefined;
  let entriesSeeded = false;
  const views: SessionView[] = [];
  for (const frame of outFrames(name)) {
    if (frame.type === "response" && frame.success === true && typeof frame.command === "string") {
      const data = frame.data;
      switch (frame.command) {
        case "get_state":
          view = withState(view, asJsonObject(data, "get_state"));
          break;
        case "get_messages_page":
          view = withMessages(view, objects(asJsonObject(data, "get_messages_page").messages));
          break;
        case "get_entries": {
          if (entriesSeeded) break;
          entriesSeeded = true;
          const result = asJsonObject(data, "get_entries");
          const leafId = typeof result.leafId === "string" ? result.leafId : undefined;
          view = withEntries(view, objects(result.entries), { leafId });
          break;
        }
        case "get_subagents":
          view = withSubagents(view, objects(asJsonObject(data, "get_subagents").subagents));
          break;
        case "get_messages":
          if (frame.id === "final-messages") {
            reference = withMessages(sessionView(), objects(asJsonObject(data, "get_messages").messages));
          }
          break;
      }
    }
    if (frame.type === "ompx" && frame.kind === "reply" && frame.ok === true && typeof frame.callId === "string") {
      const result = asJsonObject(frame.result, "ompx result");
      if (frame.callId.endsWith(":snapshot")) view = withCompanionSnapshot(view, result);
      if (frame.callId.endsWith(":queue")) view = withCompanionSnapshot(view, { queue: result });
    }
    view = reduce(view, frame);
    views.push(view);
    const answer =
      (frame.type === "extension_ui_request" || frame.type === "ompx") && typeof frame.id === "string"
        ? answers.get(frame.id)
        : undefined;
    if (answer !== undefined) {
      view = reduce(view, answer);
      views.push(view);
    }
  }
  return { views, reference };
}
