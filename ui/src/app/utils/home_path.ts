// lib/screens/sessions/machine_sessions.dart's `shortPath`: how the app writes a machine's paths.

/** `path` with the machine's home directory as `~`. */
export function shortPath(path: string, home: string | undefined): string {
  if (home === undefined || home === "") return path;
  if (path === home) return "~";
  for (const separator of ["/", "\\"]) {
    if (path.startsWith(`${home}${separator}`)) return `~${separator}${path.substring(home.length + 1)}`;
  }
  return path;
}
