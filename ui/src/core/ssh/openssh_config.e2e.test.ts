// The cases of packages/omp_core/test/ssh/openssh_config_test.dart that run this computer's ssh and read its files,
// both through the core.
import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import * as fs from "node:fs/promises";
import * as os from "node:os";
import * as path from "node:path";
import { localLink, useCore } from "../../test/core";
import { hasCommand } from "../../test/ssh_fixtures";
import { listSshConfigAliases, resolveSshAlias, type SshIdentities, sshIdentities } from "./openssh_config";

useCore();

let dir: string;

beforeEach(async () => {
  dir = await fs.mkdtemp(path.join(os.tmpdir(), "omp-ssh-"));
});

afterEach(async () => {
  await fs.rm(dir, { recursive: true, force: true });
});

describe.skipIf(!hasCommand("ssh"))("resolveSshAlias", () => {
  test("matches the real ssh -G, with -l and -p overrides for jump hops", async () => {
    const config = path.join(dir, "config");
    await fs.writeFile(
      config,
      `Host app
  HostName app.internal
  User deploy
  Port 2200
  IdentityFile ~/.ssh/id_app
  ProxyJump ops@bastion:2222,gw
Host bastion
  HostName bastion.example.com
  User nobody
`,
    );
    const app = await resolveSshAlias("app", { configFile: config });
    expect([app.hostname, app.user, app.port]).toEqual(["app.internal", "deploy", 2200]);
    expect(app.identityFiles).toEqual(["~/.ssh/id_app"]);
    expect(app.proxyJump.map((jump) => jump.host)).toEqual(["bastion", "gw"]);
    const jump = app.proxyJump[0]!;
    const bastion = await resolveSshAlias(jump.host, { user: jump.user, port: jump.port, configFile: config });
    expect([bastion.hostname, bastion.user, bastion.port]).toEqual(["bastion.example.com", "ops", 2222]);
  });

  test("refuses an alias that looks like an option", async () => {
    expect(resolveSshAlias("-oProxyCommand=touch /tmp/x")).rejects.toThrow("not a host name");
  });

  const identities = async (alias: string, user?: string): Promise<SshIdentities> =>
    sshIdentities(await resolveSshAlias(alias, { user, configFile: path.join(dir, "config") }), {
      home: dir,
      environment: { SSH_AUTH_SOCK: "/run/default.sock", APP_AGENT: "/run/app.sock" },
      localHostname: "laptop.local",
    });

  test("Host and Match blocks and Include files apply per host, in config order", async () => {
    await fs.mkdir(path.join(dir, "conf.d"));
    await fs.writeFile(path.join(dir, "conf.d/app.conf"), "Host app\n  HostName app.internal\n  IdentityAgent $APP_AGENT\n");
    await fs.writeFile(
      path.join(dir, "config"),
      `Include ${dir}/conf.d/*.conf
Host app
  IdentityFile "~/keys/app key"
  IdentitiesOnly yes
Match user deploy
  IdentityFile ~/.ssh/deploy_key
Host *
  IdentityFile ~/.ssh/id_default
`,
    );
    const app = await identities("app", "deploy");
    expect(app.agentSocket).toBe("/run/app.sock");
    expect(app.identitiesOnly).toBe(true);
    expect(app.files.map((file) => file.path)).toEqual([
      `${dir}/keys/app key`,
      `${dir}/.ssh/deploy_key`,
      `${dir}/.ssh/id_default`,
    ]);

    const other = await identities("other", "me");
    expect(other.agentSocket).toBe("/run/default.sock");
    expect(other.identitiesOnly).toBe(false);
    expect(other.files.map((file) => file.configured)).toEqual(["~/.ssh/id_default"]);
  });

  test("without an IdentityFile ssh's default keys are tried", async () => {
    await fs.writeFile(path.join(dir, "config"), "Host app\n  HostName app.internal\n");
    const paths = (await identities("app")).files.map((file) => file.path);
    for (const key of ["id_ed25519", "id_ecdsa", "id_rsa"]) expect(paths).toContain(`${dir}/.ssh/${key}`);
  });
});

describe("listSshConfigAliases", () => {
  beforeEach(async () => {
    await fs.mkdir(path.join(dir, ".ssh/conf.d"), { recursive: true });
  });

  const aliases = async () => {
    const link = localLink();
    try {
      return await listSshConfigAliases(await link.files(), { home: dir });
    } finally {
      await link.close();
    }
  };

  test("reads Host lines and Include globs, skipping patterns", async () => {
    await fs.writeFile(
      path.join(dir, ".ssh/config"),
      `# comment
Host alpha beta  # trailing comment
  HostName alpha.example.com
Host *.corp !gamma ? delta
Host=epsilon
Include conf.d/*.conf ~/.ssh/extra
Match host zeta
  User z
host "quoted name"
`,
    );
    await fs.writeFile(path.join(dir, ".ssh/conf.d/b.conf"), "Host from-b\n");
    await fs.writeFile(path.join(dir, ".ssh/conf.d/a.conf"), "Host from-a alpha\nInclude ~/.ssh/nested\n");
    await fs.writeFile(path.join(dir, ".ssh/conf.d/c.txt"), "Host ignored\n");
    await fs.writeFile(path.join(dir, ".ssh/conf.d/.hidden.conf"), "Host hidden\n");
    await fs.writeFile(path.join(dir, ".ssh/nested"), "Host nested\n");
    await fs.writeFile(path.join(dir, ".ssh/extra"), "Host extra\n");
    expect(await aliases()).toEqual([
      "alpha",
      "beta",
      "delta",
      "epsilon",
      "from-a",
      "nested",
      "from-b",
      "extra",
      "quoted name",
    ]);
  });

  test("an Include cycle stops at OpenSSH's depth limit", async () => {
    await fs.writeFile(path.join(dir, ".ssh/config"), "Host one\nInclude config\n");
    expect(await aliases()).toEqual(["one"]);
  });

  test("a missing config lists nothing", async () => {
    expect(await aliases()).toEqual([]);
  });
});
