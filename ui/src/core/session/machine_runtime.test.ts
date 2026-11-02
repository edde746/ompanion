import { expect, test } from "bun:test";
import { hostProbe, type HostProbe } from "../host/probe";
import { ompProblem, renderOverlay } from "./machine_runtime";

test("the run overlay nests dotted keys and always turns speech off", () => {
  expect(
    renderOverlay({
      "tools.approvalMode": "always-ask",
      "speech.enabled": "true",
      "a.b.c": "[1, 2]",
      "odd key": '"x"',
    }),
  ).toBe(
    "tools:\n" +
      "  approvalMode: always-ask\n" +
      "speech:\n" +
      "  enabled: false\n" +
      "a:\n" +
      "  b:\n" +
      "    c: [1, 2]\n" +
      '"odd key": "x"\n',
  );
  expect(renderOverlay({})).toBe("speech:\n  enabled: false\n");
  expect(() => renderOverlay({ tools: "x", "tools.approvalMode": "y" })).toThrow(RangeError);
  expect(() => renderOverlay({ "tools.approvalMode": "a\nb: c" })).toThrow(RangeError);
});

test("omp older than 18.3.1, a pre-release of it, none at all, or one with no Bun to run the scripts needs an install", () => {
  const probe = (
    options: { path?: string | null; version?: string; bun?: string | null } = {},
  ): HostProbe =>
    hostProbe({
      commandShell: "posix",
      os: "linux",
      kernel: "Linux",
      arch: "x64",
      home: "/home/me",
      agentDir: "/home/me/.omp/agent",
      ompPath: options.path === undefined ? "/usr/bin/omp" : (options.path ?? undefined),
      ompVersion: options.version,
      bunPath: options.bun === undefined ? "/usr/bin/omp" : (options.bun ?? undefined),
    });
  expect(ompProblem(probe({ version: "18.3.1" }))).toBeUndefined();
  expect(ompProblem(probe({ version: "18.10.0" }))).toBeUndefined();
  expect(ompProblem(probe({ version: "19.0.0-beta.1" }))).toBeUndefined();
  expect(ompProblem(probe({ version: "18.3.0" }))).toBe("omp 18.3.0 is older than 18.3.1");
  expect(ompProblem(probe({ version: "18.3.1-rc.2" }))).toBe("omp 18.3.1-rc.2 is older than 18.3.1");
  expect(ompProblem(probe({ path: null }))).toBe("omp is not installed");
  expect(ompProblem(probe())).toBe("omp at /usr/bin/omp did not report its version");
  expect(ompProblem(probe({ version: "18.3.1", bun: null }))).toBe(
    "omp at /usr/bin/omp is installed as a package and no bun was found to run it",
  );
});
