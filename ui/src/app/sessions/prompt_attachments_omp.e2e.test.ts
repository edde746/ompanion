// Port of test/sessions/prompt_attachments_omp_test.dart: the tested omp on this computer through the core, the fake
// provider, the built companion (see src/core/session/session_omp.e2e.test.ts). What a prompt with a file, a paste, a
// large paste and an image makes omp send to the model. The file has a path on this device, and the session's machine
// is seen as another machine, so the file goes there over the machine's files.
import { afterAll, beforeAll, expect, test } from "bun:test";
import * as fs from "node:fs/promises";
import type { MachineRuntime } from "../../core/session/machine_runtime";
import type { HostLink } from "../../core/transport/host_link";
import { useCore } from "../../test/core";
import { FakeProvider } from "../../test/omp";
import { answers, DevMachine, idle, viewWhere } from "../../test/session";
import { machineAccess } from "../screens/dock/machine_access";
import { imageAttachment, pathAttachment, textAttachment } from "./composer_attachments";
import { preparePrompt } from "./prompt_attachments";

/** A 2×2 PNG. */
const png = "iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAIAAAD91JpzAAAAEUlEQVR4nGP4z8DA8B+MgBgAHfAD/dPQfSYAAAAASUVORK5CYII=";

let fake: FakeProvider;
let machine: DevMachine;
let runtime: MachineRuntime;

beforeAll(async () => {
  fake = await FakeProvider.start();
  machine = await DevMachine.create(fake.port);
  runtime = machine.runtime("test");
  // The fake models take text only, and omp sends no image to such a model; fake-1 takes images here.
  const models = `${machine.home}/.omp/agent/models.yml`;
  await fs.writeFile(models, (await fs.readFile(models, "utf8")).replace("input: [text]", "input: [text, image]"));
}, 60_000);

afterAll(async () => {
  await runtime.dispose();
  await machine.dispose();
  await fake.stop();
});

// After the hooks above: the machine's runs are stopped through the core, so the core stops last.
useCore();

/** `text` as it appears inside a JSON string. */
function inJson(text: string): string {
  return JSON.stringify(text).slice(1, -1);
}

test("omp reads the uploaded file, and the model gets it with the pastes and the image", async () => {
  const session = await runtime.open({ kind: "NewSession", cwd: machine.project, model: "fake/fake-1" });
  const big = "large paste line\n".repeat(20000);
  const progress: [number, number][] = [];
  const device = `${machine.home}/device`;
  await fs.mkdir(device);
  const notes = `${device}/release notes.txt`;
  await fs.writeFile(notes, "uploaded body 4b7e\n");

  const prepared = await preparePrompt({
    text: "Summarize these.",
    attachments: [
      pathAttachment("release notes.txt", 19, notes),
      textAttachment("pasted body 91d0"),
      textAttachment(big),
      imageAttachment({ data: png, mimeType: "image/png" }),
    ],
    session,
    // The session's machine seen as another machine: its files go there over HostFiles, as over SFTP.
    link: async () => {
      const link = (await machineAccess(runtime))[0];
      return { files: () => link.files() } as HostLink;
    },
    onUploadProgress: (sent, total) => progress.push([sent, total]),
  });

  const local = `${session.sessionPath!.slice(0, -".jsonl".length)}/local`;
  const uploaded = `${local}/release notes.txt`;
  expect(prepared.message).toBe(`Summarize these. @"${uploaded}" pasted body 91d0 local://paste-1.md`);
  expect(await fs.readFile(uploaded, "utf8")).toBe("uploaded body 4b7e\n");
  expect(await fs.readFile(`${local}/paste-1.md`, "utf8")).toBe(big);
  const total = 19 + new TextEncoder().encode(big).length;
  expect(progress.at(0)).toEqual([0, total]);
  expect(progress.at(-1)).toEqual([total, total]);

  await session.rpc.prompt(prepared.message, { images: prepared.images });
  await viewWhere(session, (view) => idle(view) && answers(view).length > 0);

  const request = JSON.stringify((await fake.requests()).at(-1)!.body);
  // omp wraps a mentioned file as `<file path="…">` with its lines numbered (hashline display).
  expect(request).toContain(inJson(`<file path="${uploaded}">`));
  expect(request).toContain("1:uploaded body 4b7e");
  // The image follows the message text as image content; omp re-encodes it on the way (image-loading.ts).
  expect(request).toContain(`${inJson(prepared.message)}"},{"type":"image_url","image_url":{"url":"data:image/`);
  expect(request).not.toContain("large paste line");
});
