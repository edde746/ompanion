import { expect, test } from "bun:test";
import { pushRegistration, pushRegistrationEncode } from "./push_registration";

test("a registration encodes to exactly the contract fields, kinds in a fixed order", () => {
  const registration = pushRegistration({
    deviceId: "00112233445566778899aabbccddeeff",
    machineId: "m1",
    machineName: "devbox",
    platform: "ios",
    fid: "fid-1",
    key: "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8=",
    kinds: new Set(["failed", "input"] as const),
  });

  expect(new TextDecoder().decode(pushRegistrationEncode(registration))).toBe(
    '{"v":1,"deviceId":"00112233445566778899aabbccddeeff","machineId":"m1","machineName":"devbox",' +
      '"platform":"ios","fid":"fid-1","key":"AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8=",' +
      '"kinds":["input","failed"],"relay":"https://push.ompanion.app/v1/send"}\n',
  );
});

test("a device id that is not 32 lowercase hex never names a file", () => {
  expect(() =>
    pushRegistration({
      deviceId: "../x",
      machineId: "m1",
      machineName: "devbox",
      platform: "android",
      fid: "f",
      key: "k",
      kinds: new Set(),
    }),
  ).toThrow(RangeError);
});
