// Port of packages/omp_core/lib/src/host/probe.dart.
import {
  FormatException,
  asJsonObject,
  enumByName,
  objects,
  optBool,
  optString,
  string,
  type JsonObject,
} from "../rpc/json_fields";
import type { HostLink } from "../transport/host_link";
import { script } from "../util/script";
import { splitLines } from "../util/text";
import {
  newMarker,
  psQuote,
  runCommand,
  runPosixScript,
  runPowerShell,
  scriptResultPayload,
  shQuote,
  type CommandShell,
} from "./scripts";

export type HostOs = "macos" | "linux" | "windows" | "other";

const commandShells: readonly CommandShell[] = ["posix", "cmd", "powershell"];
const hostOses: readonly HostOs[] = ["macos", "linux", "windows", "other"];

/** Facts about a machine, from one probe. Paths are host-native (`C:\Users\x` on Windows). */
export interface HostProbe {
  /** How SSH exec parses commands on this machine. */
  readonly commandShell: CommandShell;
  readonly os: HostOs;

  /** `uname -s`, or `Windows_NT`. */
  readonly kernel: string;

  /** `x64` or `arm64` (Rosetta-safe on macOS), otherwise the raw machine name. */
  readonly arch: string;

  /** `glibc` or `musl` on Linux, absent elsewhere. */
  readonly libc?: string;

  /** The login shell (`$SHELL`); on Windows the OpenSSH `DefaultShell`, absent meaning cmd.exe. */
  readonly shell?: string;
  readonly home: string;

  /** omp's agent directory for the default environment (`PI_CODING_AGENT_DIR`, `OMP_PROFILE` honoured). */
  readonly agentDir: string;

  /**
   * The temporary directory as omp reads it (`os.tmpdir()`): `$TMPDIR`, `$TMP`, `$TEMP` or `/tmp`; on Windows
   * `%TEMP%`, `%TMP%` or `%SystemRoot%\temp`. No trailing separator.
   */
  readonly tempDir?: string;

  /** The active omp profile from `OMP_PROFILE`/`PI_PROFILE`, if any. */
  readonly profile?: string;

  /**
   * Absolute path of the omp binary the app drives, absent when none was found. The probe looks on PATH and in the
   * install locations and takes the first omp at least [minimumOmpVersion], else the first one it found.
   */
  readonly ompPath?: string;

  /** `18.3.1` from `omp --version`. */
  readonly ompVersion?: string;

  /**
   * What runs the app's Bun scripts (the pump, the attach follower, the activity stats) with `BUN_BE_BUN=1` set:
   * [ompPath] itself when it is omp's standalone binary, which is a Bun executable; for omp installed as a package
   * (`bun install -g`: a script on POSIX, a shim `omp.exe` on Windows, both run by `bun`), the `bun` that runs it.
   * Absent when there is neither.
   */
  readonly bunPath?: string;

  /**
   * The `PATH` the account's login shell gives its own children, read with `$SHELL -l -i -c` (an interactive login
   * shell, what a terminal runs); absent when the probe could not read one ([loginProblem] says which way it failed),
   * which is always the case on Windows.
   */
  readonly loginPath?: string;

  /**
   * Why [loginPath] is absent on a POSIX machine: no login shell, one that answered with no `PATH`, or no temporary
   * file to take its answer.
   */
  readonly loginProblem?: string;

  readonly curl: boolean;
  readonly wget: boolean;

  /** Windows only. */
  readonly powershellVersion?: string;
  readonly localAppData?: string;
  readonly sshdVersion?: string;
}

/** Dart's `HostProbe(...)`: `curl` and `wget` default to false. */
export function hostProbe(
  fields: Omit<HostProbe, "curl" | "wget"> & { readonly curl?: boolean; readonly wget?: boolean },
): HostProbe {
  return { ...fields, curl: fields.curl ?? false, wget: fields.wget ?? false };
}

/** Parses the JSON that [hostProbeToJson] writes. */
export function hostProbeFromJson(value: unknown): HostProbe {
  const json = asJsonObject(value, "host probe");
  return hostProbe({
    commandShell: enumByName(commandShells, string(json, "commandShell")),
    os: enumByName(hostOses, string(json, "os")),
    kernel: string(json, "kernel"),
    arch: string(json, "arch"),
    home: string(json, "home"),
    agentDir: string(json, "agentDir"),
    tempDir: optString(json, "tempDir"),
    libc: optString(json, "libc"),
    shell: optString(json, "shell"),
    profile: optString(json, "profile"),
    ompPath: optString(json, "ompPath"),
    ompVersion: optString(json, "ompVersion"),
    bunPath: optString(json, "bunPath"),
    loginPath: optString(json, "loginPath"),
    loginProblem: optString(json, "loginProblem"),
    curl: optBool(json, "curl"),
    wget: optBool(json, "wget"),
    powershellVersion: optString(json, "powershellVersion"),
    localAppData: optString(json, "localAppData"),
    sshdVersion: optString(json, "sshdVersion"),
  });
}

export function hostProbeToJson(probe: HostProbe): JsonObject {
  return {
    commandShell: probe.commandShell,
    os: probe.os,
    kernel: probe.kernel,
    arch: probe.arch,
    home: probe.home,
    agentDir: probe.agentDir,
    tempDir: probe.tempDir ?? null,
    libc: probe.libc ?? null,
    shell: probe.shell ?? null,
    profile: probe.profile ?? null,
    ompPath: probe.ompPath ?? null,
    ompVersion: probe.ompVersion ?? null,
    bunPath: probe.bunPath ?? null,
    loginPath: probe.loginPath ?? null,
    loginProblem: probe.loginProblem ?? null,
    curl: probe.curl,
    wget: probe.wget,
    powershellVersion: probe.powershellVersion ?? null,
    localAppData: probe.localAppData ?? null,
    sshdVersion: probe.sshdVersion ?? null,
  };
}

export function hostProbeIsWindows(probe: HostProbe): boolean {
  return probe.os === "windows";
}

/**
 * Where omp moves when it starts in the home directory, in the order it tries them (`cli/startup-cwd.ts`): it takes
 * the first one that exists. A session in one of them has no project folder.
 */
export function hostProbeScratchDirs(probe: HostProbe): string[] {
  const temp = probe.tempDir === undefined ? [] : [probe.tempDir];
  return hostProbeIsWindows(probe)
    ? [`${probe.home}\\tmp`, ...temp]
    : [`${probe.home}/tmp`, "/tmp", "/var/tmp", ...temp];
}

/**
 * The shell statement that puts [HostProbe.loginPath] in front of a launch script's `PATH`, for a script that starts
 * omp directly; empty when the probe read none. The login PATH goes first and the script's own `PATH` (sshd's, or
 * launchd's on this computer) stays behind it, so the script keeps resolving the tools it uses itself.
 */
export function hostProbeLoginPathExport(probe: HostProbe): string {
  return probe.loginPath === undefined ? "" : `PATH=${shQuote(`${probe.loginPath}:`)}"$PATH"; export PATH`;
}

/** The omp release asset that runs here, e.g. `omp-linux-musl-arm64`; undefined when omp ships none. */
export function hostProbeReleaseAsset(probe: HostProbe): string | undefined {
  const arch = probe.arch;
  if (arch !== "x64" && arch !== "arm64") return undefined;
  switch (probe.os) {
    case "macos":
      return `omp-darwin-${arch}`;
    case "linux":
      return probe.libc === "musl" ? `omp-linux-musl-${arch}` : `omp-linux-${arch}`;
    case "windows":
      return `omp-windows-${arch}.exe`;
    case "other":
      return undefined;
  }
}

/**
 * Probes a machine. Without [commandShell] (first contact) a polyglot command decides how the machine's SSH exec
 * parses commands; a POSIX shell that turns out to run on Windows (MSYS, Cygwin) is followed by the Windows probe,
 * because omp there is the Windows build. With [searchSystemPaths] false omp is looked for only in the install
 * locations under the home directory, never on PATH or in system directories such as `/opt/homebrew/bin`, so a
 * machine with an isolated home never runs the user's own omp.
 */
export async function probeHost(
  link: HostLink,
  options: { commandShell?: CommandShell; searchSystemPaths?: boolean } = {},
): Promise<HostProbe> {
  const searchSystemPaths = options.searchSystemPaths ?? true;
  const shell = options.commandShell ?? parseShellProbe((await runCommand(link, shellProbeCommand)).stdout);
  if (shell !== "posix") return probeWindows(link, shell, searchSystemPaths);
  const marker = newMarker();
  const result = await runPosixScript(link, posixProbeScript(marker, { searchSystemPaths }));
  const probe = parsePosixProbe(scriptResultPayload(result, marker));
  return probe.os === "windows" ? probeWindows(link, "posix", searchSystemPaths) : probe;
}

async function probeWindows(link: HostLink, shell: CommandShell, searchSystemPaths: boolean): Promise<HostProbe> {
  const marker = newMarker();
  const result = await runPowerShell(link, shell, windowsProbeScript(marker, { searchSystemPaths }));
  return parseWindowsProbe(scriptResultPayload(result, marker), shell);
}

/**
 * Polyglot: POSIX shells print `%OS%` literally and expand `$env` to nothing, cmd.exe expands only `%OS%`, PowerShell
 * expands only `$env:OS`, and a POSIX shell on Windows (MSYS) also has `$OS` set. Dots separate the fields because
 * PowerShell parses them the same with or without the surrounding quotes.
 */
export const shellProbeCommand = 'echo "OMPANION_SHELL.%OS%.$env:OS.$OS."';

/**
 * Classifies the output of [shellProbeCommand]. Shells that print nothing usable (csh) still run `sh -s`, so the
 * fallback is `posix`.
 */
export function parseShellProbe(output: string): CommandShell {
  const tag = "OMPANION_SHELL.";
  for (const line of splitLines(output)) {
    const at = line.indexOf(tag);
    if (at < 0) continue;
    const fields = line.substring(at + tag.length).replaceAll('"', "").trim().split(".");
    if (fields[0] === "Windows_NT") return "cmd";
    if (fields[1] === "Windows_NT") return "powershell";
    return "posix";
  }
  return "posix";
}

/**
 * POSIX probe, printed as one JSON object between marker lines. `LC_ALL=C` keeps `tr` and `sed` from rejecting
 * non-UTF-8 bytes in paths. `omps` lists the omp on PATH and the first other one in the install locations,
 * `~/.local/bin` first (where both installers and `uploadOmp` put it), each with the first line of its `--version` and
 * its [HostProbe.bunPath]; [parsePosixProbe] picks one. The probe also asks the login shell for its `PATH`
 * ([HostProbe.loginPath]) and waits at most [loginWait] tenths of a second for each of its two attempts.
 */
export function posixProbeScript(
  marker: string,
  options: { searchSystemPaths?: boolean; loginWait?: number } = {},
): string {
  const sys = (options.searchSystemPaths ?? true) ? "1" : "";
  return `m=${shQuote(marker)}; sys=${sys}; lwait=${options.loginWait ?? 50}\n${posixProbeBody}`;
}

const posixProbeBody = script`LC_ALL=C; export LC_ALL
q() { v=$(printf '%s' "$1" | tr '\t\n\r' '   ' | tr -d '\000-\037' | sed 's/\\/\\\\/g; s/"/\\"/g'); printf '"%s"' "$v"; }
o() { [ -n "$2" ] || return 0; printf ',"%s":' "$1"; q "$2"; }
has() { command -v "$1" >/dev/null 2>&1; }
kernel=$(uname -s 2>/dev/null)
machine=$(uname -m 2>/dev/null)
arm64=
if [ "$kernel" = Darwin ]; then
  arm64=$(sysctl -in hw.optional.arm64 2>/dev/null || /usr/sbin/sysctl -in hw.optional.arm64 2>/dev/null)
fi
libc=
if [ "$kernel" = Linux ]; then
  if [ -f /etc/alpine-release ] || ls /lib/ld-musl-* >/dev/null 2>&1 || { has ldd && ldd --version 2>&1 | grep -qi musl; }; then
    libc=musl
  else
    libc=glibc
  fi
fi
cfg="$HOME/\${PI_CONFIG_DIR:-.omp}"
prof=\${OMP_PROFILE-\${PI_PROFILE-}}
if [ -n "$prof" ]; then agent="$cfg/profiles/$prof/agent"; else agent=\${PI_CODING_AGENT_DIR:-$cfg/agent}; fi
# omp's os.tmpdir(), the last place it moves to when started in the home directory.
tmp=\${TMPDIR:-\${TMP:-\${TEMP:-/tmp}}}
case $tmp in ?*/) tmp=\${tmp%/} ;; esac
# A terminal's shell is a login and interactive one, and that is where the user's PATH comes from: Homebrew's
# shellenv and path_helper in .zprofile, ~/.local/bin, version managers and Android in .zshrc/.bashrc. The exec
# channel this probe runs on is neither, so a program started from it sees sshd's default PATH, which is
# missing all of that. Ask the login shell for the PATH its own children get, in the account's home directory
# (the app may run omp with another HOME, e.g. an isolated one, which must not change the answer). \`printenv
# PATH\` is read instead of "$PATH" because fish joins its PATH list into the exported, colon-separated
# variable; nothing else of the shell's environment is printed, since an rc may export secrets. The answer
# arrives between markers in a mktemp file, so rc noise (motd, echoes, prompts, .zcompdump) cannot corrupt it
# and no one can plant the file; a shell that never answers is killed after lwait tenths of a second.
llogin=
lwhy=
luser=$(id -un 2>/dev/null)
lrow=
if has getent; then lrow=$(getent passwd "$luser" 2>/dev/null); fi
lhome=
if [ -n "$lrow" ]; then lhome=$(printf '%s' "$lrow" | cut -d: -f6); fi
if [ -z "$lhome" ] && has dscl; then lhome=$(dscl . -read "/Users/$luser" NFSHomeDirectory 2>/dev/null | cut -d' ' -f2-); fi
lshell=\${SHELL:-}
if [ -n "$lshell" ] && [ ! -x "$lshell" ]; then lshell=; fi
if [ -z "$lshell" ] && [ -n "$lrow" ]; then lshell=$(printf '%s' "$lrow" | cut -d: -f7); fi
if [ -z "$lshell" ] && has dscl; then lshell=$(dscl . -read "/Users/$luser" UserShell 2>/dev/null | cut -d' ' -f2-); fi
if [ -z "$lhome" ]; then lhome=$HOME; fi
case $lhome in /*) ;; *) lhome=$HOME ;; esac
# A POSIX shell on Windows: the Windows probe that follows replaces this one, and omp there keeps its PATH.
case $kernel in *MINGW* | *MSYS* | *CYGWIN*) lshell= ;; esac
if [ -z "$lshell" ] || [ ! -x "$lshell" ]; then
  lwhy='no login shell'
elif ! lout=$(mktemp "\${TMPDIR:-/tmp}/ompanion-login.XXXXXX" 2>/dev/null); then
  lwhy="cannot create a temporary file in \${TMPDIR:-/tmp}"
else
  lm=login-$m
  ltry() {
    : >"$lout"
    HOME="$lhome" "$lshell" "$@" "printf '\n%s\n' $lm; printenv PATH; printf '%s\n' $lm" </dev/null >"$lout" 2>/dev/null &
    lp=$!
    ln=0
    while [ "$(grep -c "$lm" "$lout" 2>/dev/null)" -lt 2 ] && kill -0 $lp 2>/dev/null && [ $ln -lt $lwait ]; do
      sleep 0.1 2>/dev/null || sleep 1
      ln=$((ln + 1))
    done
    kill $lp 2>/dev/null
    lk=0
    while kill -0 $lp 2>/dev/null && [ $lk -lt 10 ]; do
      sleep 0.1 2>/dev/null || sleep 1
      lk=$((lk + 1))
    done
    kill -9 $lp 2>/dev/null
    llogin=$(awk -v m="$lm" '$0 == m { if (n == 2) { print p; exit } n = 1; next } n == 1 { p = $0; n = 2; next } n == 2 { exit }' "$lout")
    if [ -z "$llogin" ]; then lwhy='the login shell reported no PATH'; else lwhy=; fi
  }
  ltry -l -i -c
  if [ -z "$llogin" ]; then ltry -l -c; fi
  rm -f "$lout"
fi
p=
if [ -n "$sys" ]; then
  p=$(command -v omp 2>/dev/null)
  case $p in /*) ;; *) p= ;; esac
  set -- "$HOME/.local/bin/omp" /opt/homebrew/bin/omp /usr/local/bin/omp "$HOME/.bun/bin/omp"
else
  set -- "$HOME/.local/bin/omp" "$HOME/.bun/bin/omp"
fi
c=
for x in "$@"; do
  if [ "$x" != "$p" ] && [ -f "$x" ] && [ -x "$x" ]; then c=$x; break; fi
done
ver() { "$1" --version </dev/null 2>/dev/null | head -n 1; }
# The Bun that runs the app's scripts beside omp $1: omp itself when it is omp's standalone binary, a Bun executable
# that prints Bun's version once BUN_BE_BUN is set; for omp installed as a package (a script run by bun), the bun
# a launch's omp finds, on the login shell's PATH and then on this one.
rt() {
  case $(BUN_BE_BUN=1 "$1" --version </dev/null 2>/dev/null | head -n 1) in
  [0-9]*) printf '%s' "$1" ;;
  *)
    b=$(if [ -n "$llogin" ]; then PATH="$llogin:$PATH"; fi; command -v bun 2>/dev/null)
    case $b in /*) printf '%s' "$b" ;; esac
    ;;
  esac
}
pv=; pr=; if [ -n "$p" ]; then pv=$(ver "$p"); pr=$(rt "$p"); fi
cv=; cr=; if [ -n "$c" ]; then cv=$(ver "$c"); cr=$(rt "$c"); fi
e() { printf '{"path":'; q "$1"; printf ',"version":'; q "$2"; if [ -n "$3" ]; then printf ',"bun":'; q "$3"; fi; printf '}'; }
curl=; if has curl; then curl=1; fi
wget=; if has wget; then wget=1; fi
printf '\n%s:begin\n{"v":"1"' "$m"
o kernel "$kernel"; o machine "$machine"; o arm64 "$arm64"; o libc "$libc"; o shell "$SHELL"; o home "$HOME"
o agentDir "$agent"; o tempDir "$tmp"; o profile "$prof"; o curl "$curl"; o wget "$wget"
o loginPath "$llogin"; o loginProblem "$lwhy"
printf ',"omps":['
if [ -n "$p" ]; then e "$p" "$pv" "$pr"; fi
if [ -n "$p" ] && [ -n "$c" ]; then printf ','; fi
if [ -n "$c" ]; then e "$c" "$cv" "$cr"; fi
printf ']}\n%s:end\n' "$m"
`;

/** Parses the payload of [posixProbeScript]. */
export function parsePosixProbe(payload: string): HostProbe {
  const json = asJsonObject(JSON.parse(payload), "probe");
  const kernel = optString(json, "kernel") ?? "";
  const upper = kernel.toUpperCase();
  const os: HostOs =
    kernel === "Darwin"
      ? "macos"
      : kernel === "Linux"
        ? "linux"
        : upper.includes("MINGW") || upper.includes("MSYS") || upper.includes("CYGWIN")
          ? "windows"
          : "other";
  const machine = optString(json, "machine") ?? "";
  const arch = os === "macos" ? (optString(json, "arm64") === "1" ? "arm64" : "x64") : normalizeArch(machine);
  const omp = pickOmp(objects(json, "omps"));
  return {
    commandShell: "posix",
    os,
    kernel,
    arch,
    home: required(json, "home"),
    agentDir: required(json, "agentDir"),
    tempDir: optString(json, "tempDir"),
    libc: optString(json, "libc"),
    shell: optString(json, "shell"),
    profile: optString(json, "profile"),
    ompPath: omp?.path,
    ompVersion: omp?.version,
    bunPath: omp?.bun,
    loginPath: optString(json, "loginPath"),
    loginProblem: optString(json, "loginProblem"),
    curl: optString(json, "curl") === "1",
    wget: optString(json, "wget") === "1",
  };
}

/**
 * Windows probe. Architecture follows omp's install.ps1: `PROCESSOR_ARCHITEW6432` wins under WOW64. `omps` lists omp
 * on PATH and the first other one in the install locations, as [posixProbeScript] does, each with its
 * [HostProbe.bunPath]: omp itself, unless it is bun's shim (an `omp.exe` beside an `omp.bunx`), which starts the
 * `bun.exe` in its own directory, else the one on PATH. `tempDir` is omp's `os.tmpdir()`, without a trailing `\`
 * unless it is a drive's root. Comments stay out of the script: it must fit on one cmd.exe line.
 */
export function windowsProbeScript(marker: string, options: { searchSystemPaths?: boolean } = {}): string {
  return `$m = ${psQuote(marker)}; $sys = $${options.searchSystemPaths ?? true}\n${windowsProbeBody}`;
}

const windowsProbeBody = script`$arch = $env:PROCESSOR_ARCHITEW6432
if (-not $arch) { $arch = $env:PROCESSOR_ARCHITECTURE }
$defaultShell = $null
try { $defaultShell = (Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\OpenSSH' -Name DefaultShell -ErrorAction Stop).DefaultShell } catch { $defaultShell = $null }
$cfgName = '.omp'
if ($env:PI_CONFIG_DIR) { $cfgName = $env:PI_CONFIG_DIR }
$cfg = Join-Path $env:USERPROFILE $cfgName
$prof = $env:PI_PROFILE
if (Test-Path Env:OMP_PROFILE) { $prof = $env:OMP_PROFILE }
if ($prof) { $agent = Join-Path $cfg "profiles\$prof\agent" }
elseif ($env:PI_CODING_AGENT_DIR) { $agent = $env:PI_CODING_AGENT_DIR }
else { $agent = Join-Path $cfg 'agent' }
$omp = $null
if ($sys) { $omp = @(Get-Command -Name 'omp.exe' -CommandType Application -ErrorAction Ignore)[0].Source }
$candidates = @()
if ($env:PI_INSTALL_DIR) { $candidates += Join-Path $env:PI_INSTALL_DIR 'omp.exe' }
if ($env:LOCALAPPDATA) { $candidates += Join-Path $env:LOCALAPPDATA 'omp\omp.exe' }
$candidates += Join-Path $env:USERPROFILE '.bun\bin\omp.exe'
$candidates += Join-Path $env:USERPROFILE '.local\bin\omp.exe'
$other = $null
foreach ($c in $candidates) { if ($c -ne $omp -and (Test-Path -LiteralPath $c -PathType Leaf)) { $other = $c; break } }
$omps = @(foreach ($c in @($omp, $other)) {
  if ($c) {
    try { $ver = & $c --version 2>$null | Select-Object -First 1 } catch { $ver = $null }
    $bun = if (Test-Path -LiteralPath ($c -replace 'exe$', 'bunx')) { @(Get-Command -Name ($c -replace 'omp\.exe$', 'bun.exe'), 'bun.exe' -CommandType Application -ErrorAction Ignore)[0].Source } else { $c }
    [pscustomobject]@{ path = $c; version = $ver; bun = $bun }
  }
})
$sshd = $null
foreach ($p in @((Join-Path $env:SystemRoot 'System32\OpenSSH\sshd.exe'), (Join-Path $env:ProgramFiles 'OpenSSH\sshd.exe'))) {
  if (Test-Path -LiteralPath $p -PathType Leaf) { $sshd = (Get-Item -LiteralPath $p).VersionInfo.ProductVersion; break }
}
$curl = if (Get-Command -Name 'curl.exe' -CommandType Application -ErrorAction Ignore) { '1' }
$t = $env:TEMP; if (!$t) { $t = $env:TMP }; if (!$t) { $t = "$env:SystemRoot\temp" }
$t = $t -replace '(?<=[^:])\\$'
$o = [ordered]@{
  v = '1'; kernel = 'Windows_NT'; machine = $arch; shell = $defaultShell; home = $env:USERPROFILE
  agentDir = $agent; tempDir = $t; profile = $prof; omps = $omps; curl = $curl
  powershell = $PSVersionTable.PSVersion.ToString(); localAppData = $env:LOCALAPPDATA; sshd = $sshd
}
$json = ConvertTo-OmpAscii (ConvertTo-Json -InputObject $o -Compress -Depth 4)
[Console]::Out.Write("\`n" + $m + ":begin\`n" + $json + "\`n" + $m + ":end\`n")
`;

/** Parses the payload of [windowsProbeScript]. */
export function parseWindowsProbe(payload: string, commandShell: CommandShell): HostProbe {
  const json = asJsonObject(JSON.parse(payload), "probe");
  const omp = pickOmp(objects(json, "omps"));
  return hostProbe({
    commandShell,
    os: "windows",
    kernel: optString(json, "kernel") ?? "Windows_NT",
    arch: normalizeArch(optString(json, "machine") ?? ""),
    home: required(json, "home"),
    agentDir: required(json, "agentDir"),
    tempDir: optString(json, "tempDir"),
    shell: optString(json, "shell"),
    profile: optString(json, "profile"),
    ompPath: omp?.path,
    ompVersion: omp?.version,
    bunPath: omp?.bun,
    curl: optString(json, "curl") === "1",
    powershellVersion: optString(json, "powershell"),
    localAppData: optString(json, "localAppData"),
    sshdVersion: optString(json, "sshd"),
  });
}

/** `x86_64`/`amd64` → `x64`, `aarch64`/`arm64` → `arm64`, anything else unchanged. */
export function normalizeArch(machine: string): string {
  switch (machine.toLowerCase()) {
    case "x86_64":
    case "amd64":
    case "x64":
      return "x64";
    case "aarch64":
    case "arm64":
      return "arm64";
    default:
      return machine;
  }
}

/** The version in `omp --version` output (`omp/18.3.1`), or undefined. */
export function parseOmpVersion(output: string | undefined): string | undefined {
  return output === undefined ? undefined : /\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?/.exec(output)?.[0];
}

/** The oldest omp the app drives. */
export const minimumOmpVersion = "18.3.1";

/** Orders `major.minor.patch[-pre]` versions; a pre-release sorts before its release. */
export function compareOmpVersions(a: string, b: string): number {
  const [coreA, preA] = parseVersion(a);
  const [coreB, preB] = parseVersion(b);
  for (let i = 0; i < 3; i++) {
    const order = Math.sign((coreA[i] ?? 0) - (coreB[i] ?? 0));
    if (order !== 0) return order;
  }
  if (preA === preB) return 0;
  if (preA === undefined) return 1;
  if (preB === undefined) return -1;
  return preA < preB ? -1 : preA > preB ? 1 : 0;
}

function parseVersion(version: string): [number[], string | undefined] {
  const dash = version.indexOf("-");
  const core = dash < 0 ? version : version.substring(0, dash);
  const parts = core.split(".");
  if (parts.length !== 3 || !parts.every((part) => /^\d+$/.test(part))) {
    throw new FormatException(`not a major.minor.patch version: ${version}`);
  }
  return [parts.map(Number), dash < 0 ? undefined : version.substring(dash + 1)];
}

interface FoundOmp {
  readonly path: string;
  readonly version?: string;
  readonly bun?: string;
}

/**
 * The omp the app drives out of those a probe found, in search order: the first one at least [minimumOmpVersion],
 * else the first one, whose problem the app then reports. So an older omp on PATH gives way to the one an install put
 * into the install directory.
 */
function pickOmp(found: JsonObject[]): FoundOmp | undefined {
  const omps: FoundOmp[] = found.map((omp) => ({
    path: string(omp, "path"),
    version: parseOmpVersion(optString(omp, "version")),
    bun: optString(omp, "bun"),
  }));
  for (const omp of omps) {
    if (omp.version !== undefined && compareOmpVersions(omp.version, minimumOmpVersion) >= 0) return omp;
  }
  return omps[0];
}

function required(json: JsonObject, key: string): string {
  const value = optString(json, key);
  if (value === undefined || value === "") throw new FormatException(`probe: "${key}" is empty`);
  return value;
}
