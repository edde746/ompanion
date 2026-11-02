// The contract of test/screens/shell/connect_prompt_host_test.dart, on the order ConnectPromptHost shows prompts in.
import { expect, test } from "bun:test";
import { pumpEventQueue } from "../../../test/scripted_channel";
import { type Deferred, deferred } from "../../../deferred";
import { sshEndpoint, sshMachine } from "../../models/machine";
import { ConnectPromptQueue } from "../../sessions/connect_prompt_queue";
import type { PassphraseAnswer } from "../../services/machine_connector";
import { ConnectPromptPump, type PromptDialog, type PromptDialogs } from "./connect_prompt_pump";

const machine = sshMachine({
  id: "m1",
  name: "box",
  createdAt: 0,
  updatedAt: 0,
  target: sshEndpoint({ id: "m1", host: "box.example", user: "me", auth: "password" }),
});

const other = sshMachine({
  id: "m2",
  name: "relay",
  createdAt: 0,
  updatedAt: 0,
  target: sshEndpoint({ id: "m2", host: "relay.example", user: "me", auth: "password" }),
});

interface Shown {
  readonly kind: keyof PromptDialogs;
  closed: boolean;
  readonly answer: Deferred<unknown>;
}

/** Dialogs that record what they show and answer when the test says. */
function fakeDialogs(): { shown: Shown[]; dialogs: PromptDialogs } {
  const shown: Shown[] = [];
  function show<T>(kind: keyof PromptDialogs): PromptDialog<T> {
    const answer = deferred<T | undefined>();
    const entry: Shown = { kind, closed: false, answer };
    shown.push(entry);
    return {
      answer: answer.promise,
      close: () => {
        entry.closed = true;
        answer.resolve(undefined);
      },
    };
  }
  return {
    shown,
    dialogs: {
      password: () => show("password"),
      keyboardInteractive: () => show("keyboardInteractive"),
      hostKey: () => show("hostKey"),
      passphrase: () => show("passphrase"),
    },
  };
}

test("a password prompt cancelled while it shows closes its dialog", async () => {
  const queue = new ConnectPromptQueue();
  const { shown, dialogs } = fakeDialogs();
  const pump = new ConnectPromptPump(queue, dialogs, () => true);
  const password = queue.promptsFor(machine).password(machine.target);
  pump.pump();
  expect(shown.map((dialog) => dialog.kind)).toEqual(["password"]);

  // The machine was deleted.
  queue.cancelFor(machine.id);
  expect(await password).toBeUndefined();
  await pumpEventQueue();
  expect(shown[0]?.closed).toBe(true);
  expect(queue.next()).toBeUndefined();
});

test("a retry's identical question replaces the dialog and gets the answer", async () => {
  const queue = new ConnectPromptQueue();
  const { shown, dialogs } = fakeDialogs();
  const pump = new ConnectPromptPump(queue, dialogs, () => true);
  const prompts = queue.promptsFor(machine);
  const first = prompts.password(machine.target);
  pump.pump();
  const retry = prompts.password(machine.target);
  pump.pump();
  expect(await first).toBeUndefined();
  await pumpEventQueue();
  expect(shown.map((dialog) => [dialog.kind, dialog.closed])).toEqual([
    ["password", true],
    ["password", false],
  ]);

  shown[1]?.answer.resolve("secret");
  expect(await retry).toBe("secret");
  await pumpEventQueue();
  expect(queue.next()).toBeUndefined();
});

// A reconnect in the background unlocks a key from ~/.ssh/config through the same host as the other prompts.
test("a passphrase prompt answers with the passphrase and whether to remember it", async () => {
  const queue = new ConnectPromptQueue();
  const { shown, dialogs } = fakeDialogs();
  const pump = new ConnectPromptPump(queue, dialogs, () => true);
  const answer = queue
    .promptsFor(machine)
    .passphrase({ hop: "me@box.example", path: "~/.ssh/id_ed25519", wrong: false });
  pump.pump();
  expect(shown.map((dialog) => dialog.kind)).toEqual(["passphrase"]);

  const given: PassphraseAnswer = { passphrase: "secret", remember: true };
  shown[0]?.answer.resolve(given);
  expect(await answer).toEqual(given);
});

test("a dismissed host key dialog declines the key", async () => {
  const queue = new ConnectPromptQueue();
  const { shown, dialogs } = fakeDialogs();
  const pump = new ConnectPromptPump(queue, dialogs, () => true);
  const check = {
    host: "box.example",
    port: 22,
    keyType: "ssh-ed25519",
    keyBlob: new Uint8Array(),
    sha256Fingerprint: "SHA256:x",
  };
  const trusted = queue.promptsFor(machine).hostKey(check, { kind: "HostKeyUnknown" });
  pump.pump();
  shown[0]?.answer.resolve(undefined);
  expect(await trusted).toBe(false);
});

test("prompts wait while the app is in the background, then show one at a time, oldest first", async () => {
  const queue = new ConnectPromptQueue();
  const { shown, dialogs } = fakeDialogs();
  let foreground = false;
  const pump = new ConnectPromptPump(queue, dialogs, () => foreground);
  const first = queue.promptsFor(machine).password(machine.target);
  const second = queue.promptsFor(other).password(other.target);
  pump.pump();
  expect(shown).toHaveLength(0);

  foreground = true;
  pump.pump();
  pump.pump();
  expect(shown).toHaveLength(1);

  shown[0]?.answer.resolve("one");
  expect(await first).toBe("one");
  await pumpEventQueue();
  expect(shown).toHaveLength(2);
  shown[1]?.answer.resolve("two");
  expect(await second).toBe("two");
});
