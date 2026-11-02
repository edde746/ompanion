import { describe, expect, test } from "bun:test";
import { FormatException } from "../rpc/json_fields";
import { parseSshG, parseSshJumpSpec, type SshIdentities, sshIdentities } from "./openssh_config";

describe("parseSshG", () => {
  // Trimmed `ssh -G` output from OpenSSH 10.3.
  const output = `host app
user deploy
hostname app.internal
port 2200
identitiesonly yes
identityfile ~/.ssh/id_app
identityfile /abs/key
userknownhostsfile /home/me/.ssh/known_hosts /home/me/.ssh/known_hosts2
proxyjump ops@bastion:2222,ssh://gw.example.com,[fe80::1]:22,root@2001:db8::7
identityagent /run/agent.sock
`;

  test("reads the effective host, user, port and identity files", () => {
    const host = parseSshG(output);
    expect(host.hostname).toBe("app.internal");
    expect(host.user).toBe("deploy");
    expect(host.port).toBe(2200);
    expect(host.identityFiles).toEqual(["~/.ssh/id_app", "/abs/key"]);
    expect(host.identitiesOnly).toBe(true);
    expect(host.userKnownHostsFiles).toEqual(["/home/me/.ssh/known_hosts", "/home/me/.ssh/known_hosts2"]);
    expect(host.identityAgent).toBe("/run/agent.sock");
    expect(host.proxyCommand).toBeUndefined();
  });

  test("splits ProxyJump into hops in dial order", () => {
    expect(parseSshG(output).proxyJump.map((jump) => [jump.user, jump.host, jump.port])).toEqual([
      ["ops", "bastion", 2222],
      [undefined, "gw.example.com", undefined],
      [undefined, "fe80::1", 22],
      ["root", "2001:db8::7", undefined],
    ]);
  });

  test('no jump and "none" values', () => {
    const host = parseSshG("user u\nhostname h\nport 22\nproxycommand none\nidentityagent none\n");
    expect(host.proxyJump).toEqual([]);
    expect(host.proxyCommand).toBeUndefined();
    // `IdentityAgent none` turns the agent off; unset means SSH_AUTH_SOCK.
    expect(host.identityAgent).toBe("none");
    expect(parseSshG("user u\nhostname h\nport 22\n").identityAgent).toBeUndefined();
    expect(host.identitiesOnly).toBe(false);
  });

  test("ProxyCommand is reported", () => {
    expect(parseSshG("user u\nhostname h\nport 22\nproxycommand nc %h %p\n").proxyCommand).toBe("nc %h %p");
  });

  test("missing required keys fail", () => {
    expect(() => parseSshG("user u\nport 22\n")).toThrow(FormatException);
    expect(() => parseSshG("user u\nhostname h\nport x\n")).toThrow(FormatException);
  });
});

describe("parseSshJumpSpec", () => {
  test("rejects malformed hops", () => {
    for (const bad of ["", "user@", "@host", "host:0", "host:99999", "host:x", "[::1", "[::1]x"]) {
      expect(() => parseSshJumpSpec(bad), bad).toThrow(FormatException);
    }
  });
});

describe("sshIdentities", () => {
  const resolve = (lines: string, environment: Record<string, string> = {}): SshIdentities =>
    sshIdentities(parseSshG(`host app\nuser deploy\nhostname app.internal\nport 2200\n${lines}`), {
      home: "/home/me",
      environment,
      localHostname: "laptop.local",
    });

  test("the agent is SSH_AUTH_SOCK unless IdentityAgent names another, a variable or none", () => {
    const env = { SSH_AUTH_SOCK: "/run/default.sock", OP_AGENT: "/run/1password.sock" };
    expect(resolve("", env).agentSocket).toBe("/run/default.sock");
    expect(resolve("identityagent SSH_AUTH_SOCK\n", env).agentSocket).toBe("/run/default.sock");
    expect(resolve("identityagent $OP_AGENT\n", env).agentSocket).toBe("/run/1password.sock");
    expect(resolve("identityagent ~/My Agent/%r@%h.sock\n", env).agentSocket).toBe(
      "/home/me/My Agent/deploy@app.internal.sock",
    );

    const none = resolve("identityagent none\n", env);
    expect([none.agentSocket, none.agentProblem]).toEqual([undefined, "IdentityAgent is none"]);
    const unset = resolve("");
    expect([unset.agentSocket, unset.agentProblem]).toEqual([undefined, "SSH_AUTH_SOCK is not set"]);
    // ssh unsets the agent for an IdentityAgent variable that is not set.
    const unsetVariable = resolve("identityagent $OP_AGENT\n");
    expect([unsetVariable.agentSocket, unsetVariable.agentProblem]).toEqual([undefined, "OP_AGENT is not set"]);
  });

  test("identity files keep config order with ~, %-tokens and ${VAR} expanded", () => {
    const identities = resolve(
      "identitiesonly yes\n" +
        "identityfile ~/keys/app key\n" +
        "identityfile %d/.ssh/%r@%n_%p\n" +
        "identityfile ${KEYS}/%u-%L-100%%\n",
      { KEYS: "/vault", USER: "me" },
    );
    expect(identities.files).toEqual([
      { configured: "~/keys/app key", path: "/home/me/keys/app key" },
      { configured: "%d/.ssh/%r@%n_%p", path: "/home/me/.ssh/deploy@app_2200" },
      { configured: "${KEYS}/%u-%L-100%%", path: "/vault/me-laptop-100%" },
    ]);
    expect(identities.identitiesOnly).toBe(true);
  });

  test("a token or variable ssh would reject fails", () => {
    expect(() => resolve("identityfile ~/%x\n")).toThrow(FormatException);
    expect(() => resolve("identityfile ${NOPE}/key\n")).toThrow(FormatException);
  });
});
