// SshLink and the BridgeLink it returns, over real sshd: a bastion and a target behind it, started by
// harness/studio-sshd.sh (key auth only, the same user on both).
import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import * as fs from "node:fs/promises";
import * as os from "node:os";
import * as path from "node:path";
import { deferred } from "../../deferred";
import { useCore } from "../../test/core";
import { asJsonObject, integer, object, string } from "../rpc/json_fields";
import { HostLinkException } from "../transport/host_link";
import { withTimeout } from "../util/async";
import type { EventStream } from "../util/stream";
import { generateEd25519Key, parseSshPublicKey, sshPublicKeyFingerprint } from "./keys";
import { checkKnownHost, type KnownHostEntry, parseKnownHosts } from "./known_hosts";
import {
  type HostKeyCheck,
  type KeyPassphraseRequest,
  type SshAuth,
  type SshConfigAuth,
  type SshTarget,
  sshHop,
  sshTarget,
} from "./ssh_config";
import { SshConnectException, SshLink } from "./ssh_link";

useCore();

const script = path.resolve(import.meta.dir, "../../../../harness/studio-sshd.sh");

interface Servers {
  bastion: { host: string; port: number };
  target: { host: string; port: number };
  user: string;
  privateKeyPath: string;
  knownHosts: string;
}

let dir: string;
let servers: Servers;
let running = false;
let privateKeyPem: string;
let knownHosts: KnownHostEntry[];

async function sshd(command: "start" | "stop"): Promise<string> {
  const child = Bun.spawn(["sh", script, command, dir], { stdout: "pipe", stderr: "pipe" });
  const [code, out, err] = await Promise.all([
    child.exited,
    new Response(child.stdout).text(),
    new Response(child.stderr).text(),
  ]);
  if (code !== 0) throw new Error(`studio-sshd.sh ${command} exited ${code}: ${err.trim()}`);
  running = command === "start";
  return out;
}

/** studio-sshd.sh's one JSON line. */
function parseServers(line: string): Servers {
  const json = asJsonObject(JSON.parse(line), "studio-sshd.sh");
  const endpoint = (key: string) => {
    const hop = object(json, key);
    return { host: string(hop, "host"), port: integer(hop, "port") };
  };
  return {
    bastion: endpoint("bastion"),
    target: endpoint("target"),
    user: string(json, "user"),
    privateKeyPath: string(json, "privateKeyPath"),
    knownHosts: string(json, "knownHosts"),
  };
}

beforeAll(async () => {
  dir = await fs.mkdtemp(path.join(os.tmpdir(), "studio-sshd-"));
  servers = parseServers((await sshd("start")).trim().split("\n").pop() ?? "");
  privateKeyPem = await fs.readFile(servers.privateKeyPath, "utf8");
  knownHosts = parseKnownHosts(await fs.readFile(servers.knownHosts, "utf8"));
}, 60_000);

afterAll(async () => {
  if (running) await sshd("stop");
  await fs.rm(dir, { recursive: true, force: true });
});

const keyAuth = (): SshAuth => ({ kind: "SshKeyAuth", privateKeyPem, name: "studio key" });

function throughBastion(auth: () => SshAuth = keyAuth): SshTarget {
  return sshTarget({
    jumps: [sshHop({ ...servers.bastion, user: servers.user, auth: auth() })],
    target: sshHop({ ...servers.target, user: servers.user, auth: auth() }),
  });
}

/** Trusts the hosts studio-sshd wrote to its known_hosts, and records what it was asked. */
function knownHostsVerifier(checks: HostKeyCheck[]) {
  return async (check: HostKeyCheck) => {
    checks.push(check);
    return checkKnownHost(knownHosts, check) === "match";
  };
}

async function text(stream: EventStream<Uint8Array>): Promise<string> {
  const decoder = new TextDecoder();
  return (await stream.toArray()).map((chunk) => decoder.decode(chunk, { stream: true })).join("") + decoder.decode();
}

/** The SshConnectException [open] fails with. */
async function connectFailure(open: Promise<SshLink>): Promise<SshConnectException> {
  const error: unknown = await open.then(
    async (link) => {
      await link.close();
      return new Error("connected");
    },
    (thrown: unknown) => thrown,
  );
  if (!(error instanceof SshConnectException)) throw error;
  return error;
}

describe("through a jump host", () => {
  let link: SshLink;
  const checks: HostKeyCheck[] = [];

  beforeAll(async () => {
    link = await SshLink.open(throughBastion(), { verifyHostKey: knownHostsVerifier(checks) });
  });

  afterAll(async () => {
    await link.close();
  });

  test("every hop's host key is checked against known_hosts, bastion first", () => {
    expect(checks.map((check) => check.port)).toEqual([servers.bastion.port, servers.target.port]);
    expect(checks.every((check) => checkKnownHost(knownHosts, check) === "match")).toBe(true);
    expect(link.label).toBe(`${servers.user}@${servers.target.host}:${servers.target.port}`);
  });

  test("exec runs on the target with stdin, stdout, stderr and the exit code", async () => {
    const process = await link.exec("cat; echo oops >&2; exit 3");
    process.write(new TextEncoder().encode("hello\n"));
    await process.closeStdin();
    const [out, err, exit] = await Promise.all([text(process.stdout), text(process.stderr), process.exit]);
    expect([out, err, exit.code]).toEqual(["hello\n", "oops\n", 3]);
  });

  test("a PTY session gets the asked size, and close hangs it up", async () => {
    const process = await link.exec("stty size; exec cat", { pty: { columns: 91, rows: 17 } });
    let seen = "";
    const decoder = new TextDecoder();
    const sized = deferred<void>();
    process.stdout.listen((chunk) => {
      seen += decoder.decode(chunk, { stream: true });
      if (seen.includes("17 91")) sized.resolve();
    });
    await sized.promise;
    await process.close();
    await process.exit;
  });

  test("files work in SFTP path space", async () => {
    const files = await link.files();
    const home = await files.home();
    expect(home.startsWith("/")).toBe(true);
    const made = await link.exec("mktemp -d");
    await made.closeStdin();
    const tmp = (await text(made.stdout)).trim();
    try {
      await files.write(`${tmp}/a`, new TextEncoder().encode("abc"));
      await files.write(`${tmp}/a`, new TextEncoder().encode("def"), { append: true });
      expect(new TextDecoder().decode(await files.read(`${tmp}/a`, { offset: 1, length: 4 }))).toBe("bcde");
      await files.mkdir(`${tmp}/lock`);
      expect(files.mkdir(`${tmp}/lock`)).rejects.toThrow("already exists");
      expect((await files.list(tmp)).map((entry) => entry.name).sort()).toEqual(["a", "lock"]);
      expect(await files.stat(`${tmp}/missing`)).toBeNull();
    } finally {
      const removed = await link.exec(`rm -rf '${tmp}'`);
      await removed.closeStdin();
      await removed.exit;
    }
  });

  test("connect opens a TCP connection from the target", async () => {
    const socket = await link.connect("127.0.0.1", servers.target.port);
    const banner = await socket.input.first();
    expect(new TextDecoder().decode(banner)).toStartWith("SSH-2.0-");
    await socket.close();
  });

  test("forward carries a local port to the target's view of a host and port", async () => {
    const forward = await link.forward("127.0.0.1", servers.target.port);
    try {
      const received = deferred<string>();
      const socket = await Bun.connect({
        hostname: "127.0.0.1",
        port: forward.localPort,
        socket: { data: (_, data) => received.resolve(new TextDecoder().decode(data)) },
      });
      expect(await received.promise).toStartWith("SSH-2.0-");
      socket.end();
    } finally {
      await forward.close();
    }
  });
});

test("an untrusted host key fails on the hop that presented it", async () => {
  const error = await connectFailure(SshLink.open(throughBastion(), { verifyHostKey: async () => false }));
  expect([error.failure, error.hop.port]).toEqual(["hostKeyRejected", servers.bastion.port]);
  expect(error.message).toContain("is not trusted");
});

test("a verifier that throws fails the connection as a rejected host key", async () => {
  const error = await connectFailure(
    SshLink.open(throughBastion(), {
      verifyHostKey: async () => {
        throw new Error("store unavailable");
      },
    }),
  );
  expect(error.failure).toBe("hostKeyRejected");
  expect(error.message).toContain("host key check failed");
});

test("a refused key fails with the key it offered", async () => {
  const stranger = await generateEd25519Key({ comment: "stranger" });
  const auth = (): SshAuth => ({ kind: "SshKeyAuth", privateKeyPem: stranger.privateKeyPem, name: "wrong key" });
  const error = await connectFailure(SshLink.open(throughBastion(auth), { verifyHostKey: knownHostsVerifier([]) }));
  expect([error.failure, error.hop.port]).toEqual(["authFailed", servers.bastion.port]);
  expect(error.offer?.keys.map((key) => key.name)).toEqual(["wrong key"]);
  expect(error.message).toContain("did not accept 'wrong key' (ED25519 SHA256:");
});

test("a refused port is unreachable", async () => {
  const target = sshTarget({ target: sshHop({ host: "127.0.0.1", port: 1, user: servers.user, auth: keyAuth() }) });
  const error = await connectFailure(SshLink.open(target, { verifyHostKey: knownHostsVerifier([]) }));
  expect(error.failure).toBe("unreachable");
});

describe("OpenSSH config auth", () => {
  const configAuth = (configFile: string, extra: Partial<SshConfigAuth> = {}) => (): SshAuth => ({
    kind: "SshConfigAuth",
    config: { configFile, home: dir, environment: {} },
    ...extra,
  });

  test("offers the identity files ssh -G names for each hop", async () => {
    const link = await SshLink.open(throughBastion(configAuth(`${dir}/ssh_config`)), {
      verifyHostKey: knownHostsVerifier([]),
    });
    const process = await link.exec("echo through-config");
    await process.closeStdin();
    expect(await text(process.stdout)).toBe("through-config\n");
    await link.close();
  });

  test("an encrypted identity file is unlocked with the passphrase asked for it", async () => {
    const key = `${dir}/encrypted_ed25519`;
    await signal(`ssh-keygen -q -t ed25519 -N secret -C encrypted -f '${key}' && cat '${key}.pub' >> '${dir}/authorized_keys'`);
    await fs.writeFile(`${dir}/encrypted_config`, `Host *\n  IdentityFile ${key}\n  IdentitiesOnly yes\n`);
    const requests: KeyPassphraseRequest[] = [];
    const passphrase = async (request: KeyPassphraseRequest) => {
      requests.push(request);
      return request.wrong ? "secret" : "guess";
    };
    const target = sshTarget({
      target: sshHop({ ...servers.target, user: servers.user, auth: configAuth(`${dir}/encrypted_config`, { passphrase })() }),
    });
    const link = await SshLink.open(target, { verifyHostKey: knownHostsVerifier([]) });
    await link.close();
    expect(requests.map((request) => [request.path, request.wrong])).toEqual([
      [key, false],
      [key, true],
    ]);
    const publicKey = parseSshPublicKey(await fs.readFile(`${key}.pub`, "utf8"));
    expect(requests[0]!.publicKey && sshPublicKeyFingerprint(requests[0]!.publicKey)).toBe(
      sshPublicKeyFingerprint(publicKey),
    );
  });

  test("no identity file and no agent fails before dialing, saying where it looked", async () => {
    await fs.writeFile(`${dir}/missing_config`, `Host *\n  IdentityFile ${dir}/nothing_here\n  IdentitiesOnly yes\n`);
    const target = sshTarget({
      target: sshHop({ ...servers.target, user: servers.user, auth: configAuth(`${dir}/missing_config`)() }),
    });
    const error = await connectFailure(SshLink.open(target, { verifyHostKey: knownHostsVerifier([]) }));
    expect(error.failure).toBe("keyUnavailable");
    expect(error.offer?.missingFiles).toEqual([`${dir}/nothing_here`]);
    expect(error.message).toContain("no key to offer; SSH_AUTH_SOCK is not set; not found:");
  });
});

test("close ends the link", async () => {
  const link = await SshLink.open(throughBastion(), { verifyHostKey: knownHostsVerifier([]) });
  await link.close();
  await link.done;
  expect(link.exec("true")).rejects.toBeInstanceOf(HostLinkException);
});

test("done settles when the peer stops answering keepalives", async () => {
  const link = await SshLink.open(throughBastion(), {
    verifyHostKey: knownHostsVerifier([]),
    liveness: { intervalMs: 500, maxMissed: 2 },
  });
  // The bastion carries the whole link. Each of its connections is a monitor process under the listener and a
  // network child under that; frozen, they answer nothing.
  const sessions = `$(for p in $(pgrep -P "$(cat '${dir}/bastion/sshd.pid')"); do echo "$p"; pgrep -P "$p"; done)`;
  await signal(`kill -STOP ${sessions}`);
  try {
    await withTimeout(link.done, 10_000);
    expect(link.exec("true")).rejects.toBeInstanceOf(HostLinkException);
  } finally {
    await signal(`kill -KILL ${sessions}`);
  }
}, 30_000);

async function signal(command: string): Promise<void> {
  const child = Bun.spawn(["sh", "-c", command]);
  expect(await child.exited).toBe(0);
}
