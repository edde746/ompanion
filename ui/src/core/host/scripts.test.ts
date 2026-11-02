// Port of the pure cases of packages/omp_core/test/host/scripts_test.dart; the rest are in scripts.e2e.test.ts.
import { expect, test } from "bun:test";
import { HostLinkException } from "../transport/host_link";
import {
  encodePowerShell,
  encodedPowerShellCommand,
  powershellCommand,
  scriptResultPayload,
  windowsCommandLineLimit,
} from "./scripts";

test("the payload is found between its markers, whatever the shell printed around it", () => {
  const result = {
    stdout: 'Last login: today\nOMPANION_1:begin\n{"a":1}\nOMPANION_1:end\nbye\n',
    stderr: "",
    exit: { code: 0 },
  };
  expect(scriptResultPayload(result, "OMPANION_1")).toBe('{"a":1}');
  expect(() => scriptResultPayload(result, "OMPANION_2")).toThrow(HostLinkException);
});

test("encodePowerShell is base64 of UTF-16LE, surrogate pairs included", () => {
  expect(encodePowerShell("a")).toBe("YQA=");
  const bytes = Array.from(atob(encodePowerShell("€🎉")), (c) => c.charCodeAt(0));
  expect(bytes).toEqual([0xac, 0x20, 0x3c, 0xd8, 0x89, 0xdf]);
});

test("an encoded command that would not fit on a cmd.exe line is refused", () => {
  let size = 0;
  while (encodedPowerShellCommand("cmd", "x".repeat(size + 1)) !== null) size++;
  expect(encodedPowerShellCommand("cmd", "x".repeat(size))?.length).toBeLessThanOrEqual(windowsCommandLineLimit);
  const over = powershellCommand("cmd", `-EncodedCommand ${encodePowerShell("x".repeat(size + 1))}`);
  expect(over.length).toBeGreaterThan(windowsCommandLineLimit);
});
