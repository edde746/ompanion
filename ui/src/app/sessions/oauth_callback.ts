// Port of lib/sessions/oauth_callback.dart.

/**
 * The port of `url`'s OAuth `redirect_uri` when that is a loopback address with an explicit port, else undefined.
 * omp's `login` sends the browser back to the machine's loopback (anthropic 54545, openai-codex 1455, …); on an SSH
 * machine the app forwards the same local port there so this device's browser can finish the login (docs/PLAN.md D11).
 */
export function loopbackRedirectPort(url: string): number | undefined {
  const redirect = parse(url)?.searchParams.get("redirect_uri");
  const target = redirect === null || redirect === undefined ? undefined : parse(redirect);
  if (target === undefined || !["localhost", "127.0.0.1", "[::1]"].includes(target.hostname)) return undefined;
  return target.port === "" ? undefined : Number(target.port);
}

/** `URL.canParse` is newer than iOS 16's WebKit. */
function parse(url: string): URL | undefined {
  try {
    return new URL(url);
  } catch (error) {
    if (error instanceof TypeError) return undefined;
    throw error;
  }
}
