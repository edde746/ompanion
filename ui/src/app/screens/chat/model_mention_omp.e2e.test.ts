// Port of test/screens/chat/model_mention_omp_test.dart: the tested omp on this computer through the core, the fake
// provider, the built companion (see src/core/session/session_omp.e2e.test.ts). A model tagged in the composer becomes
// omp's pseudonym `m1`, the message carries its tag, and `task` with `agent: "m1"` runs a subagent on that model. The
// composer's widgets stay out: the draft gets the chip the `^` list puts in, and the composer's send path sends it.
import { afterAll, beforeAll, expect, test } from "bun:test";
import * as fs from "node:fs/promises";
import { compareOmpVersions } from "../../../core/host/probe";
import { asJsonObject, isJsonObject } from "../../../core/rpc/json_fields";
import type { MachineRuntime } from "../../../core/session/machine_runtime";
import { textOf } from "../../../core/store/content";
import { useCore } from "../../../test/core";
import { FakeProvider, testedOmpVersion } from "../../../test/omp";
import { DevMachine, idle, prompts, viewWhere } from "../../../test/session";
import { collapsedAt, ComposerDraft } from "../../sessions/composer_draft";
import { buildRoster } from "../dock/agents/agent_roster";
import { composerIntent } from "./composer_intent";
import { filterModels, mentionQuery, modelDisplayName, modelSelector } from "./composer_palettes";
import { sendPrompt } from "./composer_send";

let fake: FakeProvider;
let machine: DevMachine;
let runtime: MachineRuntime;

beforeAll(async () => {
  fake = await FakeProvider.start();
  machine = await DevMachine.create(fake.port);
  runtime = machine.runtime("test");
}, 60_000);

afterAll(async () => {
  await runtime.dispose();
  await machine.dispose();
  await fake.stop();
});

// After the hooks above: the machine's runs are stopped through the core, so the core stops last.
useCore();

test("a model picked after ^ becomes m1 in omp, and task runs agent m1 on it", async () => {
  const session = await runtime.open({ kind: "NewSession", cwd: machine.project, model: "fake/fake-1" });
  await fake.enqueue([
    {
      steps: [
        { toolCall: { name: "task", arguments: { i: "Delegating the review", agent: "m1", task: "Review this change" } } },
      ],
    },
    // Only the subagent runs on the tagged model. omp before 18.10.3 has it answer through `yield`; from 18.10.3 its
    // final message is the answer.
    {
      match: '"model":"fake-think"',
      steps:
        compareOmpVersions(testedOmpVersion, "18.10.3") < 0
          ? [{ toolCall: { name: "yield", arguments: { i: "Done", data: "looks fine" } } }]
          : [{ text: "looks fine" }],
    },
    // `task` runs in the background: the spawn's result, then the job's completion notice, each get a turn.
    { match: "Spawned agent", steps: [{ text: "Waiting for the review." }] },
    { match: "has completed", steps: [{ text: "Fake Think says it looks fine." }] },
  ]);

  // The `^` list shows the machine's models matching the token; picking Fake Think puts in its chip.
  const draft = new ComposerDraft();
  draft.text.value = { text: "Have ^thi", selection: collapsedAt("Have ^thi".length) };
  const mention = mentionQuery(draft.text.value)!;
  const picked = filterModels(await session.rpc.getAvailableModels(), mention.query).find(
    (model) => modelDisplayName(model) === "Fake Think",
  )!;
  draft.text.insertChip(mention.start, "Have ^thi".length, {
    name: modelDisplayName(picked),
    source: `^${modelSelector(picked)}`,
  });
  draft.insert("review this change");
  const intent = composerIntent(draft.text.expand(draft.text.text), {
    hasAttachments: false,
    running: false,
    followUp: false,
    commands: session.view.commands,
  });
  expect(intent).toEqual({ kind: "SendPrompt", text: "Have ^fake/fake-think review this change" });
  if (intent.kind !== "SendPrompt") return;
  await sendPrompt(session, draft, intent, {
    link: () => Promise.reject(new Error("a prompt without files needs no machine")),
    onUpload: () => undefined,
    snack: (text) => {
      throw new Error(`the send failed: ${text}`);
    },
  });

  // The run ends with the scripted answer.
  const done = await viewWhere(
    session,
    (view) =>
      idle(view) &&
      view.transcript.some((item) => item.kind === "AssistantItem" && textOf(item.content).includes("looks fine")),
    { timeoutMs: 60_000 },
  );

  const tag = '<model agent="m1" name="Fake Think"/>';
  const entries = (await fs.readFile(session.sessionPath!, "utf8"))
    .trim()
    .split("\n")
    .map((line) => asJsonObject(JSON.parse(line), "session entry"));
  expect(
    entries.filter((entry) => entry.type === "custom" && entry.customType === "model_mention").map((entry) => entry.data),
  ).toEqual([{ agent: "m1", selector: "fake/fake-think", name: "Fake Think" }]);
  const user = entries.flatMap((entry) =>
    isJsonObject(entry.message) && entry.message.role === "user" ? [entry.message] : [],
  )[0];
  expect(prompts(done)).toEqual([`Have ${tag} review this change`]);
  expect(JSON.stringify(user?.content)).toContain(JSON.stringify(`Have ${tag} review this change`));

  // The scripted turns (side requests such as the task's effort estimate get the default reply): the main agent on
  // the session's model, the subagent on the tagged one. The subagent's turn and the main agent's second one run at
  // once.
  const models = (await fake.requests()).flatMap((request) =>
    request.served === "queue" && isJsonObject(request.body) ? [String(request.body.model)] : [],
  );
  expect(models.sort()).toEqual(["fake-1", "fake-1", "fake-1", "fake-think"]);

  // The Agent Hub's row: agent m1 on the tagged model (its thinking level after the colon).
  const roster = buildRoster(session.view.agents, session.view.subagents);
  expect(
    roster.filter((agent) => agent.kind === "sub").map((agent) => [agent.agentType, agent.model?.split(":")[0]]),
  ).toEqual([["m1", "fake/fake-think"]]);
}, 90_000);
