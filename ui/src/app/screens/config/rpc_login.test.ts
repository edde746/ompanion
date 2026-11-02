// Port of test/screens/config/login_dialogs_test.dart, plus the link handling of login_dialogs.dart. The dialog
// (login_dialogs.tsx) routes Cancel, system back and Escape to RpcLogin.cancel, so the Dart test's back button is
// `cancel` here.
import { expect, test } from "bun:test";
import { RpcCommandException } from "../../../core/rpc/exceptions";
import { RpcClient } from "../../../core/rpc/rpc_client";
import type { LocalForward } from "../../../core/session/machine_runtime";
import {
  type InputRequest,
  type OpenUrlRequest,
  type SessionView,
  sessionView,
} from "../../../core/store/session_view";
import { FakeLiveSession, settle } from "../../../test/live_session";
import { ScriptedChannel, startClient } from "../../../test/scripted_channel";
import { RpcLogin } from "./rpc_login";

/** The control session, over a channel where `login` stays pending until the test answers it; records `detach`. */
class Control extends FakeLiveSession {
  readonly channel = new ScriptedChannel();
  override readonly rpc = new RpcClient(this.channel, { deviceId: "test" });
  detached = false;

  override async detach(): Promise<void> {
    this.detached = true;
  }
}

const link: OpenUrlRequest = {
  kind: "OpenUrlRequest",
  id: "link",
  url: "https://auth.openai.com/oauth/authorize?redirect_uri=http%3A%2F%2Flocalhost%3A1455%2Fauth%2Fcallback",
  launchUrl: "http://127.0.0.1:1455/launch",
};

const codePrompt: InputRequest = {
  kind: "InputRequest",
  id: "code",
  title: "Paste the authorization code",
  toolCallIds: [],
};

async function startLogin(options: { remote: boolean; view?: SessionView }) {
  const control = new Control(options.view);
  await startClient(control.rpc, control.channel);
  const forwarded: number[] = [];
  const closedForwards: number[] = [];
  const opened: string[] = [];
  const login = new RpcLogin({
    target: {
      isThisComputer: !options.remote,
      runtime: {
        forwardLocal: async (remotePort, forward = {}): Promise<LocalForward> => {
          forwarded.push(remotePort);
          return {
            localPort: forward.localPort ?? 0,
            remotePort,
            close: async () => {
              closedForwards.push(remotePort);
            },
          };
        },
      },
    },
    control,
    providerId: "openai-codex",
    openBrowser: async (url) => {
      opened.push(url);
    },
  });
  const command = control.channel.next("login");
  login.start();
  return { control, login, forwarded, closedForwards, opened, command: await command };
}

test("Cancel ends a pending login: omp's question is cancelled and the control session detached", async () => {
  const { control, login, command } = await startLogin({ remote: false });
  expect(command.providerId).toBe("openai-codex");
  control.emit(sessionView({ requests: [codePrompt] }));
  await settle();
  expect(login.question()).toEqual(codePrompt);

  await login.cancel();

  expect(control.channel.sent).toContainEqual({ type: "extension_ui_response", id: "code", cancelled: true });
  expect(control.dismissed).toEqual(["code"]);
  expect(control.detached).toBe(true);
});

test("a finished or failed login closes without detaching the control session", async () => {
  const finished = await startLogin({ remote: false });
  finished.control.channel.respond(finished.command);
  await settle();
  expect(finished.login.done()).toBe(true);
  await finished.login.cancel();
  expect(finished.control.detached).toBe(false);

  const failed = await startLogin({ remote: false });
  failed.control.channel.reject(failed.command, "login failed");
  await settle();
  expect(failed.login.error()).toBeInstanceOf(RpcCommandException);
  await failed.login.cancel();
  expect(failed.control.detached).toBe(false);
});

test("an OpenUrlRequest is handled once and dismissed; only a remote machine gets its ports forwarded", async () => {
  const remote = await startLogin({ remote: true });
  remote.control.emit(sessionView({ requests: [link] }));
  await settle();
  // The fake keeps the request in its view, as a replay would.
  remote.control.emit(sessionView({ requests: [link, codePrompt] }));
  await settle();
  expect(remote.control.dismissed).toEqual(["link"]);
  expect(remote.forwarded).toEqual([1455]);
  expect(remote.login.forwarding()).toEqual([1455]);
  expect(remote.opened).toEqual([link.url]);
  expect(remote.login.link()).toEqual(link);
  await remote.login.close();
  expect(remote.closedForwards).toEqual([1455]);

  // A link omp sent before the login started, on this computer: omp's callback server listens here.
  const local = await startLogin({ remote: false, view: sessionView({ requests: [link] }) });
  await settle();
  expect(local.control.dismissed).toEqual(["link"]);
  expect(local.forwarded).toEqual([]);
  expect(local.opened).toEqual([link.url]);
  expect(local.login.link()).toEqual(link);
});

test("a question is answered and dismissed; only omp's messages since the login started show", async () => {
  const { control, login } = await startLogin({
    remote: false,
    view: sessionView({ nextSeq: 3, notices: [{ kind: "MessageNotice", seq: 2, level: "info", message: "earlier" }] }),
  });
  control.emit(
    sessionView({
      nextSeq: 4,
      requests: [codePrompt],
      notices: [
        { kind: "MessageNotice", seq: 2, level: "info", message: "earlier" },
        { kind: "MessageNotice", seq: 3, level: "info", message: "Waiting for the browser" },
      ],
    }),
  );
  await settle();
  expect(login.notices()).toEqual(["Waiting for the browser"]);

  await login.answer(codePrompt, { value: "abc123" });

  expect(control.channel.sent).toContainEqual({ type: "extension_ui_response", id: "code", value: "abc123" });
  expect(control.dismissed).toEqual(["code"]);
});
