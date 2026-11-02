// Port of credentialStatus and _date of lib/screens/config/accounts_page.dart.
import type { StoredCredential } from "../../config/accounts";
import { t } from "../../i18n/i18n";

/**
 * The line under a stored credential's label: what the label does not already say. omp labels an API key "API key #n"
 * and details it "stored API key #n"; an OAuth account's label is its email and its detail the other identity parts.
 */
export function credentialStatus(credential: StoredCredential): string | undefined {
  const parts: string[] = [];
  if (credential.oauth && credential.detail !== undefined) parts.push(credential.detail);
  if (credential.active) parts.push(t.config.accounts.active);
  if (credential.sticky) parts.push(t.config.accounts.sticky);
  if (credential.expires !== undefined) parts.push(t.config.accounts.expires({ date: date(credential.expires) }));
  return parts.length === 0 ? undefined : parts.join(" · ");
}

/** `yyyy-MM-dd HH:mm` in local time. */
function date(epochMs: number): string {
  const time = new Date(epochMs);
  const two = (value: number) => String(value).padStart(2, "0");
  const day = `${time.getFullYear()}-${two(time.getMonth() + 1)}-${two(time.getDate())}`;
  return `${day} ${two(time.getHours())}:${two(time.getMinutes())}`;
}
