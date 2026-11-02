// Port of test/screens/chat/queue_list_test.dart: what a queued row's edit and remove do to omp's queue and the draft.
// Left out as markup: that a row shows a mentioned file by its name and a tagged model as a chip (mention parsing is
// message_mentions.test.ts).
import { expect, test } from "bun:test";
import type { JsonObject } from "../../../core/rpc/json_fields";
import { type ComposerAttachment, imageAttachment, textAttachment } from "../../sessions/composer_attachments";
import { ComposerDraft } from "../../sessions/composer_draft";
import { takeQueued } from "./queue_take";

/** A companion that answers every call with the message it took back, as `queue.take` does; calls are recorded. */
function companion(steering: string) {
  const calls: { verb: string; args: JsonObject }[] = [];
  return {
    calls,
    call: async (verb: string, args: JsonObject = {}): Promise<unknown> => {
      calls.push({ verb, args });
      return { text: steering, images: [{ data: "QUEUED", mimeType: "image/png" }] };
    },
  };
}

function halfTyped(): ComposerDraft {
  const draft = new ComposerDraft();
  draft.replace("half typed", {
    attachments: [imageAttachment({ data: "DRAFT", mimeType: "image/png" }), textAttachment("pasted")],
  });
  return draft;
}

function describe(attachment: ComposerAttachment): string {
  switch (attachment.kind) {
    case "ImageAttachment":
      return `image ${attachment.image.data}`;
    case "FileAttachment":
      return `file ${attachment.name}`;
    case "TextAttachment":
      return `text ${attachment.text}`;
  }
}

test("editing a queued message takes it back ahead of the draft and its images after the draft's attachments", async () => {
  const omp = companion("queued message");
  const draft = halfTyped();

  await takeQueued(omp, draft, { mode: "steering", index: 0, edit: true });

  expect(omp.calls).toEqual([{ verb: "queue.take", args: { mode: "steering", index: 0 } }]);
  expect(draft.text.text).toBe("queued message\n\nhalf typed");
  expect(draft.attachments.map(describe)).toEqual(["image DRAFT", "text pasted", "image QUEUED"]);
});

test("removing a queued message leaves the draft alone", async () => {
  const omp = companion("queued message");
  const draft = halfTyped();

  await takeQueued(omp, draft, { mode: "followUp", index: 0, edit: false });

  expect(omp.calls).toEqual([{ verb: "queue.take", args: { mode: "followUp", index: 0 } }]);
  expect(draft.text.text).toBe("half typed");
  expect(draft.attachments.map(describe)).toEqual(["image DRAFT", "text pasted"]);
});

test("editing a queued message with a mentioned file gives back the message as sent", async () => {
  const message = 'Check @"/home/u/.omp/agent/sessions/-p/1/local/meeting notes.txt" too';
  const draft = halfTyped();

  await takeQueued(companion(message), draft, { mode: "steering", index: 0, edit: true });

  expect(draft.text.text).toBe(`${message}\n\nhalf typed`);
});

test("editing a queued message puts its tagged model back as a chip, sending the tag", async () => {
  const message = 'Ask <model agent="m1" name="Fake Think"/> too';
  const draft = halfTyped();

  await takeQueued(companion(message), draft, { mode: "steering", index: 0, edit: true });

  expect(draft.text.text).not.toContain("<model");
  expect(draft.text.expand(draft.text.text)).toBe(`${message}\n\nhalf typed`);
});
