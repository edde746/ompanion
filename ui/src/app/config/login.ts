// Port of lib/config/login.dart.

/**
 * Loopback ports an OAuth flow sends the browser back to: the `redirect_uri` of [url], and [launchUrl] (omp's short
 * redirect, served by its callback server). Both listen on the machine running omp, so a remote machine needs the same
 * local port forwarded there before the browser opens.
 */
export function loopbackPorts(url: string, launchUrl: string | undefined): Set<number> {
  const ports = new Set<number>();
  for (const candidate of [parse(url)?.searchParams.get("redirect_uri") ?? undefined, launchUrl]) {
    const uri = candidate === undefined ? undefined : parse(candidate);
    // An explicit port only: URL drops a scheme's default one, as Dart's Uri.hasPort does.
    if (uri === undefined || uri.port === "") continue;
    if (["localhost", "127.0.0.1", "[::1]"].includes(uri.hostname)) ports.add(Number(uri.port));
  }
  return ports;
}

function parse(text: string): URL | undefined {
  try {
    return new URL(text);
  } catch (error) {
    if (error instanceof TypeError) return undefined;
    throw error;
  }
}
