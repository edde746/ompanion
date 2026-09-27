import { isRecord } from "./guards.ts";

// Google OAuth 2.0 for a service account: sign an RS256 JWT with the account's key and trade it at the account's
// token_uri for an access token (https://developers.google.com/identity/protocols/oauth2/service-account).

export type ServiceAccount = {
  projectId: string;
  clientEmail: string;
  tokenUri: string;
  privateKey: CryptoKey;
};

export const FCM_SCOPE = "https://www.googleapis.com/auth/firebase.messaging";

// Google's tokens live an hour. Refreshing 5 minutes early keeps a token from expiring on its way to FCM.
const REFRESH_EARLY_MS = 5 * 60 * 1000;
// Two requests (this exchange, then FCM) fit inside the companion's 10 s timeout.
export const UPSTREAM_TIMEOUT_MS = 4000;

/** Parses the service-account JSON downloaded from the Firebase console; throws when it is not one. */
export async function parseServiceAccount(text: string): Promise<ServiceAccount> {
  let json: unknown;
  try {
    json = JSON.parse(text);
  } catch (error) {
    throw new Error(`the service account is not JSON: ${String(error)}`);
  }
  if (!isRecord(json) || json.type !== "service_account") {
    throw new Error('the service account is not a JSON object with "type": "service_account"');
  }
  const field = (name: string): string => {
    const value = json[name];
    if (typeof value !== "string" || value === "") throw new Error(`the service account has no ${name}`);
    return value;
  };
  const pem = /-----BEGIN PRIVATE KEY-----([A-Za-z0-9+/=\s]+)-----END PRIVATE KEY-----/.exec(field("private_key"));
  if (!pem?.[1]) throw new Error("the service account's private_key is not a PKCS #8 PEM key");
  const privateKey = await crypto.subtle.importKey(
    "pkcs8",
    Buffer.from(pem[1].replace(/\s+/g, ""), "base64"),
    { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
    false,
    ["sign"],
  );
  return {
    projectId: field("project_id"),
    clientEmail: field("client_email"),
    tokenUri: field("token_uri"),
    privateKey,
  };
}

function base64url(data: string | ArrayBuffer): string {
  return Buffer.from(typeof data === "string" ? Buffer.from(data) : new Uint8Array(data)).toString("base64url");
}

async function signJwt(account: ServiceAccount, nowSeconds: number): Promise<string> {
  const header = base64url(JSON.stringify({ alg: "RS256", typ: "JWT" }));
  const claims = base64url(
    JSON.stringify({
      iss: account.clientEmail,
      scope: FCM_SCOPE,
      aud: account.tokenUri,
      iat: nowSeconds,
      exp: nowSeconds + 3600,
    }),
  );
  const input = `${header}.${claims}`;
  const signature = await crypto.subtle.sign("RSASSA-PKCS1-v1_5", account.privateKey, Buffer.from(input));
  return `${input}.${base64url(signature)}`;
}

/** The access token for FCM, fetched on first use and kept until 5 minutes before it expires. */
export class AccessTokens {
  #token: { value: string; expiresAt: number } | undefined;
  #pending: Promise<string> | undefined;

  constructor(private readonly account: ServiceAccount) {}

  get(): Promise<string> {
    if (this.#token && Date.now() < this.#token.expiresAt) return Promise.resolve(this.#token.value);
    // Concurrent sends while no token is cached share one exchange.
    this.#pending ??= this.#exchange().finally(() => {
      this.#pending = undefined;
    });
    return this.#pending;
  }

  /** FCM answered 401 to this token: it was revoked before its expiry, so the next send fetches a new one. */
  drop(value: string): void {
    if (this.#token?.value === value) this.#token = undefined;
  }

  async #exchange(): Promise<string> {
    const assertion = await signJwt(this.account, Math.floor(Date.now() / 1000));
    const response = await fetch(this.account.tokenUri, {
      method: "POST",
      headers: { "content-type": "application/x-www-form-urlencoded" },
      body: new URLSearchParams({ grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer", assertion }),
      signal: AbortSignal.timeout(UPSTREAM_TIMEOUT_MS),
    });
    const text = await response.text();
    if (!response.ok) throw new Error(`token exchange: HTTP ${response.status} ${text.slice(0, 200)}`);
    const json: unknown = JSON.parse(text);
    if (!isRecord(json) || typeof json.access_token !== "string" || typeof json.expires_in !== "number") {
      throw new Error("token exchange: the response has no access_token and expires_in");
    }
    this.#token = { value: json.access_token, expiresAt: Date.now() + json.expires_in * 1000 - REFRESH_EARLY_MS };
    return json.access_token;
  }
}
