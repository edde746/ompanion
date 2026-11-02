// Port of "a stored credential line holds only what its label does not say" of test/config/login_test.dart.
import { expect, test } from "bun:test";
import { type StoredCredential, storedCredentialFromJson } from "../../config/accounts";
import { credentialStatus } from "./credential_status";

function stored(
  type: "api_key" | "oauth",
  fields: { detail?: string; active?: boolean; sticky?: boolean; expires?: number } = {},
): StoredCredential {
  return storedCredentialFromJson({
    credentialId: 1,
    type,
    label: type === "oauth" ? "a@example.com" : "API key #1",
    detail: fields.detail ?? null,
    active: fields.active ?? false,
    sticky: fields.sticky ?? false,
    pinnable: false,
    identity: fields.expires === undefined ? null : { expires: fields.expires },
  });
}

test("a stored credential line holds only what its label does not say", () => {
  expect(credentialStatus(stored("api_key", { detail: "stored API key #1" }))).toBeUndefined();
  expect(credentialStatus(stored("api_key", { detail: "stored API key #1", active: true }))).toBe("in use");
  const account = stored("oauth", { detail: "account acct-1 · oauth #1" });
  expect(credentialStatus(account)).toBe("account acct-1 · oauth #1");
  // The expiry in local time.
  const expires = new Date(2026, 0, 5, 9, 7).getTime();
  const pinned = stored("oauth", { detail: "account acct-1", active: true, sticky: true, expires });
  expect(credentialStatus(pinned)).toBe("account acct-1 · in use · pinned · expires 2026-01-05 09:07");
});
